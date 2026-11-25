# Ephemeral-computer adapter — Muse

For agentic AIs that run on a computer that **does not survive**: the VM is
replaced often, processes do not survive, there is no daemon, no cron you can
trust, and no background job that outlives the turn. The only thing that
persists is the home directory (`~/workspace`).

## The one rule

**Capture and flush in the same turn as the critique.** If the turn ends
before the critique is pushed or drafted to a persisted path, the critique is
lost. There is no "later" on this machine — later is a different VM.

## Constraints inherited from the user's own skills

Read first, before changing this adapter:

- `~/workspace/custom-skills/local_silent_background_handover/SKILL.md`
  (note: underscores in the real path, not hyphens)
  - Run without narrating progress. Send nothing while the work runs unless
    the user's input is needed or the result is ready.
  - Hand over **one compact message**, only what changed. No per-item
    messages, no re-listing the plan.
  - Applied here: the flush is silent; the user hears exactly one line —
    pushed (with issue URL) or drafted (with path + what still needs pushing).
- `~/workspace/custom-skills/local_verify_before_claiming_done/SKILL.md`
  - Treat a builder/subagent/tool claim of "done" as unverified until you
    have checked the artifact yourself.
  - Confirm delivery actually reached the user before saying delivered.
  - Say what you did **not** check in the same message.
  - Applied here, as the **receipt-first rule**: a critique is not "pushed"
    until a receipt file exists under `receipts/` containing the real issue
    URL/number (or a real error). The agent reads the receipt back and
    reports only what the receipt says. No receipt → say "not yet pushed",
    never "pushed".

## Files in this directory

| File | Purpose |
| --- | --- |
| `muse-capture.md` | Runbook: the exact steps the Muse agent follows, in-turn, from hearing a critique to reporting the outcome. |
| `flush-now.sh` | The flush script. Validates a draft, pushes it (via the shared bridge if present, else `gh issue create`), writes the receipt **before** success is reported. Dry-run by default. |
| `draft-fallback.md` | What happens when the push fails or the VM is about to die: the complete draft format, where it lives, the one-line message to the user, and recovery. |

## Paths (all under the persisted home — never `/tmp`, never the VM root)

- Repo root: `~/workspace/critique-push-skill/`
- Drafts (undelivered): `~/workspace/critique-push-skill/drafts/`
- Receipts (proof of push or of failure): `~/workspace/critique-push-skill/receipts/`
- Bridge (owned by another agent): `~/workspace/critique-push-skill/bridge/`

If the repo lives somewhere else, set `CRITIQUE_PUSH_ROOT` to that root;
`flush-now.sh` derives drafts/receipts/bridge from it.

## How a push works (short version)

1. User criticises a tool, in their own words, in chat.
2. Agent writes a draft JSON (all fields, user's exact words — see
   `draft-fallback.md` for the schema) to `drafts/` **in the same turn**.
3. Agent runs `./flush-now.sh --draft <file>` (dry-run by default) or
   `./flush-now.sh --draft <file> --live` to really push. The script
   translates the small capture draft to the shared schema
   (`critique-schema.json` v0.1.0) and pushes via `../bridge/push.py` if
   present, otherwise via `gh issue create`, and writes a receipt JSON to
   `receipts/` **before** the agent reports anything.
4. Agent reads the receipt and reports one line from it. No receipt, no
   "pushed".

## Differences vs the dedicated-computer adapter

| | Dedicated computer (Hermes-style) | Ephemeral computer (Muse) |
| --- | --- | --- |
| Process lifetime | Long-lived; daemon/queue survives | Dies with the VM; nothing survives the turn |
| Capture | May queue and flush later | **In-turn only** — same turn as the critique |
| Retry window | Long; daemon retries for hours/days | None in-turn; retry happens on a **later session** via `--retry-drafts` |
| Queue | Persistent queue daemon | No daemon; the `drafts/` directory *is* the queue |
| Flush trigger | Scheduler / watcher | Explicit `./flush-now.sh` call, or `--retry-drafts` at session start |
| Proof of push | Daemon log / receipt | Receipt file, written **before** reporting success |
| Failure mode | Retry in background | Save complete draft to persisted path + one-line message to user |
| Cron dependency | Allowed | **Forbidden** — no cron, no background job the user must trust to survive |
| Cost of a lost turn | Delayed push | **Lost critique** — hence draft-first, flush-immediately |

## What this adapter deliberately does NOT do

- No daemon, no systemd unit, no cron job, no `nohup` background process.
- No network call that the turn does not wait for.
- No claim of "pushed" based on a command's exit code alone — the receipt
  file (with issue URL/number, or the real error) is the proof, and the
  agent must read it back.
- No paraphrasing of the user's words in the draft: the `body` field holds
  their exact words; the agent's summary, if any, is a separate field.
- No secrets: no PAT/token is ever stored in this repo, in a draft, or in a
  receipt. `gh` uses the user's own existing auth; if `gh` is not
  authenticated, the push fails cleanly and the draft path is used instead.

## Session-start recovery

On a new session (new VM, same `~/workspace`), run:

```sh
./flush-now.sh --retry-drafts          # dry-run: shows what would be pushed
./flush-now.sh --retry-drafts --live   # actually push every pending draft
```

Each retried draft gets its own receipt; a draft is deleted from `drafts/`
only after a receipt with a real issue URL exists.
