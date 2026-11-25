# Dedicated-computer adapter

For agentic AIs that run on a **persistent computer**: Hermes (Debian box),
Codex CLI, omp (Oh My Pi on the laptop), Claude Code, and any other CLI
agent on a machine that survives reboots. The queue lives on disk, so a
critique captured today can be flushed tomorrow, after a reboot, by a cron
job, or by hand.

## Files

| File | Purpose |
| --- | --- |
| `install.sh` | One-command, idempotent setup |
| `capture.sh` | Capture a critique to the queue; `--flush` pushes queued critiques; `--dry-run` prints without filing |
| `queue.md` | Queue format + retry rules (this doc's queue section) |

## Install

```bash
bash adapters/dedicated/install.sh
```

Idempotent — safe to re-run. It:

1. Creates `~/.critique-push/queue/` (one JSON file per critique),
   `~/.critique-push/receipts/`, and `~/.critique-push/log/`.
2. Creates `~/.critique-push/config` (shell-sourced) with defaults if it
   does not exist; never overwrites an existing config.
3. Detects auth, in this order, and records only *which* method is
   available (never the secret itself):
   - `gh` CLI logged in (`gh auth status` succeeds) → `AUTH_METHOD=gh`
   - else `CRITIQUE_PUSH_TOKEN` set in the environment → `AUTH_METHOD=env-token`
   - else neither → install still succeeds, flush will fail loudly and
     keep everything queued; the user is told to run `gh auth login` or
     export `CRITIQUE_PUSH_TOKEN` from their secret store.
4. Prints the detected auth method and the queue location.

**Tokens:** a token is read from the environment (`CRITIQUE_PUSH_TOKEN`)
or from the `gh` CLI's own credential store at push time. It is **never
written to disk in plaintext** — not in config, not in queue files, not in
logs. If you use a PAT, put it in your shell secret store / password
manager and export it per-session, or prefer `gh auth login`.

Config keys (`~/.critique-push/config`):

```bash
CRITIQUE_PUSH_AGENT_ID="hermes"      # this agent's id — change per machine
CRITIQUE_PUSH_TOOL="hermes"          # tool name: hermes | codex | omp | claude-code | ...
CRITIQUE_PUSH_DEFAULT_REPO=""        # e.g. owner/repo — set per tool, or pass --repo each time
CRITIQUE_PUSH_BRIDGE="$HOME/workspace/critique-push-skill/bridge/push.py"
```

## Capture

The agent turns a user critique from chat into a structured queue file.
`capture.sh` takes the fields as flags (or `--from-json <file>`), validates
them, and writes `~/.critique-push/queue/<id>.json`.

```bash
bash adapters/dedicated/capture.sh \
  --repo owner/repo \
  --title "CLI hangs on large repos" \
  --summary "Running the agent on a repo with 50k files hangs for minutes with no output." \
  --expected "Show progress or finish in seconds." \
  --steps "1. Open a large repo\n2. Ask for a summary\n3. Wait" \
  --tool-version "codex 0.41.0" \
  --labels "bug"
```

Dry-run — prints the issue body, files nothing, touches no remote:

```bash
bash adapters/dedicated/capture.sh --dry-run --repo owner/repo --title "..." --summary "..."
```

### Critique fields (the one `critique-schema.json` shape)

Every queue file **is** a `critique-schema.json` record — the single
contract shared by the bridge, this adapter, and the ephemeral adapter.
The CLI flags below map onto it; `capture.sh` fills the rest.

| Field | Required | Notes |
| --- | --- | --- |
| `schema_version` | auto | `"0.1.0"` |
| `id` | auto | `cp-<UTC timestamp>-<random 4 hex>`; unique per critique |
| `tool_name` / `tool` | auto | Tool name from config (`CRITIQUE_PUSH_TOOL`); both fields, same value |
| `tool_version` | no | `--tool-version`; `null` when not observable, never guessed |
| `category` | `--category` | `bug` \| `ux-friction` \| `wrong-output` \| `missing-feature` \| `confusing-copy` \| `other` (default `other`) |
| `title` | yes | Short, in the user's words; `capture.sh` prefixes `[<category>]` per SPEC if missing |
| `what_happened` / `body` / `user_words` | yes | `--summary`: what happened, in the user's words (verbatim); all three fields, same text |
| `expected` | yes | `--expected`: what the user expected instead |
| `actual` | `--actual` | What actually happened; defaults to `--summary` when not given |
| `impact` | `--impact` | One line; defaults to an explicit "(not recorded …)" marker — never a guessed impact |
| `repro_steps` | no | `--steps`, one step per line (numbering stripped; the template numbers them) |
| `environment` | auto | OS from the machine, `runtime: "dedicated-box"` |
| `date_wib` / `date` | auto | Capture time in Asia/Jakarta (`YYYY-MM-DD HH:mm WIB`) and its `YYYY-MM-DD` date |
| `target_repo` | yes | `--repo`, `owner/repo` of the tool being criticised |
| `dedup_key` | auto | `tool_name + normalized symptom` |
| `status` | auto | `queued` → `pushed` / `failed-held` |
| `evidence` | auto | `"None recorded by the agent."` unless the agent observed evidence |
| `agent_id` | auto | From config (`CRITIQUE_PUSH_AGENT_ID`) |
| `labels` | no | `--labels`, comma-separated, e.g. `bug,ux` |
| `created_at` | auto | UTC ISO 8601 |
| `attempts` / `next_retry_at` | auto | Flush attempts so far (0 at capture); next retry time or `null` |
| `receipt` | auto | `null` until pushed, then `{issue_url, issue_number, pushed_at_wib}` |

Validation: `capture.sh` validates against `critique-schema.json` with
`python3 -m jsonschema` when available, else a stdlib check of the same
required fields + the bridge contract. Invalid input is rejected before
anything is queued, with the missing/invalid field named.

## Queue + flush

Queue format and retry rules live in `queue.md`. In short:

```bash
bash adapters/dedicated/capture.sh --flush            # push everything queued
bash adapters/dedicated/capture.sh --flush --dry-run  # show what would be filed
```

Flush order: oldest `created_at` first. Each critique gets at most 3
attempts with backoff (5 min, 30 min, 2 h); after the 3rd failure it stays
queued with `status: failed-held` and the user is told. Nothing is ever
deleted silently — a pushed critique keeps its file with the receipt, a
held one keeps its file until it succeeds or the user deletes it by hand.

Suggested cron (runs the flush hourly; harmless when the queue is empty):

```cron
0 * * * * bash $HOME/workspace/critique-push-skill/adapters/dedicated/capture.sh --flush >> $HOME/.critique-push/log/flush.log 2>&1
```

Or a shell hook after each agent session — whichever the host agent
supports; the cron is the default because it needs no host integration.

## Push (bridge first, `gh` fallback)

`capture.sh --flush` pushes through the shared bridge:

```bash
python3 "$CRITIQUE_PUSH_BRIDGE" --critique <queue-file.json> \
    --repo <owner/repo> [--labels <labels>] --live
```

The bridge prints a receipt JSON on stdout; `capture.sh` parses the
`issue_url` out of it. **Do not reimplement GitHub API logic here.** If
the bridge file is not present, `capture.sh` falls back to:

```bash
gh issue create --repo <owner/repo> --title <title> --body-file <body.md> --label <labels>
```

with the body rendered from the same `templates/critique-template.md`.
The fallback still honours the same receipt and retry rules.

## Receipt

On a successful push, `capture.sh`:

1. Writes the schema's `receipt` object (`issue_url`, `issue_number`,
   `pushed_at_wib`) and `status: pushed` back into the queue file.
2. Appends one line to `~/.critique-push/receipts/receipts.log`:
   `<pushed_at> <id> <repo>#<number> <issue_url>`.
3. Prints exactly one line to the user:
   `Filed: https://github.com/<owner>/<repo>/issues/<number>`

On failure it prints `Held: <id> (<reason>) — <n> queued, will retry` and
leaves the file queued.

## Multi-agent note

Hermes, omp, Codex, Claude Code, and any other agent share this queue
format and this bridge. Each signs with **its own** `agent_id` + `tool`
from its own `~/.critique-push/config`. Two rules hold for every agent:

- The issue author is the **user**; the agent is the bridge. The footer
  reads: `Filed via critique-push by <agent_id> (<tool>) on behalf of the
  user.` Never sign with the user's name, never write "I" as the agent.
- Never impersonate the user as author, and never file a critique another
  agent captured as if it were yours — the `agent_id` on the file is the
  agent that captured it; the flushing agent does not rewrite it.
