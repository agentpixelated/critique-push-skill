# Install — critique-push

## Prerequisites

- `bash`, `python3` (stdlib only — no pip packages needed anywhere).
- `gh` (GitHub CLI) for the push path. Check: `command -v gh python3`.
  On this machine both are installed (`/usr/bin/gh`, `/usr/bin/python3`).
- A checkout of this repo. The adapters assume the repo root is
  `~/workspace/critique-push-skill/` unless you override it:
  - dedicated: `CRITIQUE_PUSH_HOME` overrides `~/.critique-push`
    (queue/config location); `CRITIQUE_PUSH_BRIDGE` overrides the bridge
    path in `~/.critique-push/config`.
  - ephemeral: `CRITIQUE_PUSH_ROOT` overrides the repo root
    (`flush-now.sh` derives `drafts/`, `receipts/`, `bridge/` from it).

No daemon, no service, no background process is installed by either
adapter. The dedicated adapter optionally uses a cron line you add
yourself (below); the ephemeral adapter **forbids** cron.

## Dedicated computer (Hermes / Codex / omp / Claude Code / any CLI agent)

One command, idempotent — safe to re-run:

```bash
bash adapters/dedicated/install.sh
```

Verified 2026-11-25 (with `CRITIQUE_PUSH_HOME=/tmp/cp-home-test`): exit 0.
It creates:

- `~/.critique-push/queue/` — one JSON file per critique
- `~/.critique-push/receipts/` — `receipts.log`, one line per push
- `~/.critique-push/log/` — flush logs
- `~/.critique-push/config` (shell-sourced, created only if absent —
  never overwrites an existing config)

Config keys (defaults written by `install.sh`):

```bash
CRITIQUE_PUSH_AGENT_ID="hermes"      # change per machine/agent
CRITIQUE_PUSH_TOOL="hermes"          # hermes | codex | omp | claude-code | ...
CRITIQUE_PUSH_DEFAULT_REPO=""        # e.g. owner/repo, or pass --repo each time
CRITIQUE_PUSH_BRIDGE="$HOME/workspace/critique-push-skill/bridge/push.py"
```

The bridge is `bridge/push.py`, called as
`python3 bridge/push.py --critique <json> --repo <owner/repo> [--live]`
(dry-run by default). If that file is absent, `capture.sh --flush` falls
back to `gh issue create` with the same receipt and retry rules.

### Optional: hourly flush cron (dedicated only)

```cron
0 * * * * bash $HOME/workspace/critique-push-skill/adapters/dedicated/capture.sh --flush >> $HOME/.critique-push/log/flush.log 2>&1
```

Harmless when the queue is empty (`queue empty — nothing to flush.`).
One cron owner per machine — two flushers racing can double-file.

## Ephemeral computer (Muse)

There is nothing to install. The repo itself must live under the persisted
home (`~/workspace/critique-push-skill/`), because the VM root does not
survive — `drafts/` and `receipts/` live under the repo root for exactly
that reason. First use creates them (or set `CRITIQUE_PUSH_ROOT`).

Capture and flush happen **in the same turn** as the critique — see
`adapters/ephemeral/muse-capture.md` for the runbook. At the start of a
new session, retry leftovers:

```bash
cd adapters/ephemeral
./flush-now.sh --retry-drafts          # dry-run first
./flush-now.sh --retry-drafts --live   # really push
```

## Auth setup

The push uses **the user's own** GitHub credentials. Never a shared or
agent-owned token, never a token in a file.

**Preferred — `gh` CLI (both adapters):**

```bash
gh auth login
gh auth status   # must succeed before any live push
```

**Alternative — env token (dedicated adapter):**

```bash
export CRITIQUE_PUSH_TOKEN="..."   # from your secret store / password manager, per session
```

`capture.sh` reads it as `CRITIQUE_PUSH_TOKEN` and passes it to `gh` as
`GH_TOKEN` for that one call. The bridge (`bridge/push.py`) reads
`GH_TOKEN` / `GITHUB_TOKEN` from the environment only — never as a CLI
argument, never logged, never written to disk. A token is **never** written
into `~/.critique-push/config`, a queue file, a draft, or a receipt.

The bridge also accepts a `config.yaml` copied from
`bridge/config.example.yaml` — placeholders only (`repo: "OWNER/REPO"`,
`dry_run: true`). **Never put a token in it.**

If no auth exists, install still succeeds and capture still queues —
flush just fails loudly and everything stays queued. Verified 2026-11-25:
`install.sh` with no auth printed `auth method: none` + the
`gh auth login` hint and exited 0; `gh auth status` on this machine says
`You are not logged into any GitHub hosts.`

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `bridge/test-push-dryrun.sh` → `FAIL: push.py exited 2, expected 0` / `missing required field 'schema_version'` | Fixed 2026-11-25: the test's example critique is now fully schema-conformant (see TESTING.md §2a). If you see this again, a critique is missing a schema-required field — read the named field, don't edit the expectation. |
| `capture.sh --dry-run` → `critique rejected — nothing queued.` + a `jsonschema` `ValidationError` about `additionalProperties` | Fixed 2026-11-25: the adapter's queue record is now a `critique-schema.json` record (see TESTING.md §3b). If you see this again, the record carries a field the schema does not declare — declare it in the schema or drop it; do not loosen `additionalProperties`. |
| `capture.sh --flush` → `no auth: run 'gh auth login' or export CRITIQUE_PUSH_TOKEN` | No `gh` login and no `CRITIQUE_PUSH_TOKEN`, and the bridge file is absent. Fix auth (above); critiques stay queued, nothing is lost. |
| `flush-now.sh --live` → `no bridge at …/push.py and 'gh' not found` | The bridge file is absent and `gh` is not on PATH. Make sure `gh` is installed or the bridge exists. |
| `flush-now.sh` → `FAILED translation: target repo unknown or invalid` | No `--repo owner/repo` (and no `CRITIQUE_PUSH_REPO`). The registry holds placeholders only — pass `--repo` explicitly. |
| Issue body renders without the repo template (built-in template used instead) | `push.py` renders `templates/critique-template.md` at the repo root; it falls back to its built-in template only if that file is absent. Check the file exists at the repo root. |
| Title comes out as `[example-tool] [bug] …` (double bracket) | Fixed 2026-11-25: `push.py` no longer prepends `[<tool>]`; it uses the title as-is when it already carries SPEC's `[<category>]` prefix. |
| A critique about a tool with no known repo | `registry/` holds placeholders only. Save locally as `pending-unmapped` and tell the user — never guess a repo, never push to a wrong repo (SPEC.md). |
