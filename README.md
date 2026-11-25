# critique-push

**Version:** 0.1.0 · **Date:** 2026-11-25 · **Status:** draft — dry-run verified, live push not yet verified

Turn a user's complaint about an agentic-AI tool into a GitHub Issue on that
tool's own repo — written in the user's own words, with their agent acting
only as the bridge. The user never opens GitHub, never writes Markdown, never
learns the repo layout. They complain in normal conversation; the agent
captures it, validates it, redacts private data, and files it.

## The one rule

**Nothing is pushed without the user saying so.** The agent may offer to
push; it never pushes on its own initiative. One critique = one Issue.
No receipt = not done.

## Who it is for

- **Users of agentic-AI tools** (Codex CLI, Claude Code, omp, Hermes, Muse,
  and others) who hit a bug, confusing behaviour, a missing feature, or a
  wrong result and want the tool's maintainers to hear about it — in their
  own voice.
- **Agent builders** who want their agent to file those critiques without
  reimplementing GitHub logic in every adapter.

## How it works

```
user complains in chat
  → capture (keep the verbatim quote)
  → validate (critique-schema.json + redaction)
  → queue / flush
  → push via bridge/ (one shared GitHub engine)
  → receipt (Issue URL saved locally, one line told to the user)
```

## The two runtimes

| | Dedicated computer | Ephemeral computer |
| --- | --- | --- |
| Who | Hermes (Debian box), Codex CLI, omp, Claude Code, any CLI agent on a machine that survives reboots | Muse (sandbox VM that may vanish after the session) |
| Adapter | `adapters/dedicated/` — `install.sh`, `capture.sh`, `queue.md` | `adapters/ephemeral/` — `muse-capture.md`, `flush-now.sh`, `draft-fallback.md` |
| Queue | Durable on-disk queue at `~/.critique-push/queue/`, flushed by cron/hook or by hand | No daemon, no cron — the `drafts/` directory *is* the queue; capture and flush happen **in the same turn** |
| If the push fails | Stays queued, retried with backoff (5 min → 30 min → 2 h, max 3 attempts), then `failed-held` | Draft stays in `drafts/` + one line to the user; retry next session with `flush-now.sh --retry-drafts --live` |

Both adapters call the same engine: `bridge/push.py` (stdlib-only Python,
dry-run by default, `--live` + the user's own `gh` auth or `GH_TOKEN` /
`GITHUB_TOKEN` env token to really file).

## Quickstart

**Dedicated computer** (persistent machine):

```bash
bash adapters/dedicated/install.sh
bash adapters/dedicated/capture.sh --dry-run --repo owner/repo \
  --title "CLI hangs on large repos" \
  --summary "Running the agent on a repo with 50k files hangs for minutes." \
  --expected "Show progress or finish in seconds."
bash adapters/dedicated/capture.sh --flush   # push everything queued
```

**Ephemeral computer** (Muse, same turn as the critique):

```bash
cd adapters/ephemeral
./flush-now.sh --draft ../../drafts/<file>.json          # dry-run (default)
./flush-now.sh --draft ../../drafts/<file>.json --live   # really push
./flush-now.sh --retry-drafts --live                     # next session: retry leftovers
```

See [`INSTALL.md`](INSTALL.md) for prerequisites, auth setup
(`gh auth login` or `CRITIQUE_PUSH_TOKEN`), and troubleshooting, and
[`TESTING.md`](TESTING.md) for the 5-minute dry-run checklist — all
seven dry-run checks pass.

## Repo map

| Path | What it is |
| --- | --- |
| [`SPEC.md`](SPEC.md) | The contract: what counts as a critique, trigger rules, user-POV voice rules, required fields, privacy/redaction, dedup (7 days, same symptom), runtime-mode contract |
| [`SKILL.md`](SKILL.md) | The skill text agents follow (when to use / not use, workflow, authorship rule) |
| [`critique-schema.json`](critique-schema.json) | JSON Schema v0.1.0 for a critique record (`additionalProperties: false`) |
| [`templates/critique-template.md`](templates/critique-template.md) | Issue-body template (verbatim user quote first, agent evidence labelled) |
| [`bridge/`](bridge/README.md) | Shared push engine: `push.py`, `config.example.yaml`, `test-push-dryrun.sh` |
| [`adapters/dedicated/`](adapters/dedicated/README.md) | Persistent-computer adapter |
| [`adapters/ephemeral/`](adapters/ephemeral/README.md) | Ephemeral-computer adapter |
| `registry/` | Tool→repo mapping — placeholders only so far (`OWNER/REPO`); pass `--repo` explicitly until the user approves real mappings (see `registry/README.md`) |
| `drafts/` / `receipts/` | Ephemeral adapter runtime dirs (created on first use; empty at present — a test draft + `failed` receipt from development were removed during the build; the receipt's error text is preserved in TESTING.md §4) |

## Authorship — the hard rule

The Issue author is the **user**. The body is in their voice ("I tried…",
"I expected…"), their exact words quoted verbatim at the top. The agent
adds only observed facts under a labelled "Agent-added evidence" section,
never invents repro steps, severity, or a version number, and never signs
with the user's name. Footer: `Filed via critique-push by <agent-id>
(<tool>) on behalf of the user.`

## Privacy

Redaction runs **before** any network call, on the local copy, and the user
sees the redacted body before confirming. Tokens, keys, passwords, emails,
real names, absolute home paths, internal URLs, and private screenshots are
stripped. No token is ever written to disk in plaintext — auth is the user's
own `gh` login or a token from the environment / secret store only.
Verified 2026-11-25: a grep for token/PAT/private-key patterns across the
repo returned no matches (see [`TESTING.md`](TESTING.md)).

## Status / known gaps (honest list, 2026-11-25)

All seven dry-run checks in [`TESTING.md`](TESTING.md) pass: bridge
dry-run test, bridge dry-run with a schema-conformant critique,
dedicated install, dedicated capture dry-run, dedicated flush dry-run,
ephemeral flush dry-run, ephemeral retry-drafts dry-run. The bridge
renders `templates/critique-template.md` (`{single-brace}` placeholders)
end to end, and all three emitters (bridge test example, dedicated
`capture.sh`, ephemeral `flush-now.sh` translation) produce the one
`critique-schema.json` shape. What is still **not** verified:

- No live push, live dedup, or cron flush has been verified (all checks
  are dry-run; `gh` on this machine is not logged in).
- `registry/` holds placeholders only, so `target_repo` cannot currently
  be resolved automatically — critiques must be given `--repo`
  explicitly.
- The dedicated adapter's live flush path (bridge `--live`) has never
  been exercised live — only its dry-run, which calls the bridge.

These are the remaining steps before the first real push, not reasons to
use the skill live yet. Full detail in [`TESTING.md`](TESTING.md).
