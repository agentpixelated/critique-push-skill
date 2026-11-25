# Draft fallback — when the push fails or the VM is about to die

On an ephemeral computer there is no daemon to retry for you and no second
chance inside the same turn. The fallback is therefore not a retry loop —
it is a **complete, persisted draft** plus a one-line message, and recovery
happens on a later session.

## When the fallback triggers

- `flush-now.sh --live` exits non-zero (bridge missing, `gh` not
  authenticated, network error, GitHub error, validation failure).
- The receipt says `status: "failed"` (read the receipt — it holds the real
  error).
- No receipt file exists at all (flush never finished).
- The VM/session is about to end and the flush has not completed.

In all four cases: **do not claim "pushed"**. Do not retry in a loop. Save
(or keep) the draft and tell the user one line.

## Draft format (the complete record)

Location: `~/workspace/critique-push-skill/drafts/` (or
`$CRITIQUE_PUSH_ROOT/drafts/`). Persisted — this directory survives VM
replacement because it lives under `~/workspace`.

Filename: `<UTC-timestamp>-<slug>.json`, e.g.
`20261125T103045-aider-ignores-gitignore.json`. Timestamp format:
`YYYYMMDDTHHMMSS` (UTC). Slug: 2–5 lowercase words from the title.

```json
{
  "tool": "aider",
  "version": "0.86.1",
  "severity": "medium",
  "title": "aider rewrites files listed in .gitignore",
  "body": "<USER'S EXACT WORDS — verbatim, unparaphrased, complete>",
  "context": "<agent summary: what happened, steps to reproduce, what was expected>",
  "reporter": "agentpixelated",
  "created_at": "2026-11-25T10:30:45Z",
  "source": "muse-ephemeral",
  "attempts": [
    { "at": "2026-11-25T10:31:02Z", "result": "failed", "error": "gh: failed to log in" }
  ]
}
```

Field rules:

| Field | Rule |
| --- | --- |
| `tool` | Required. The tool being criticised, as the user named it. |
| `version` | Tool version if known, else `"unknown"`. Never guess. |
| `severity` | `low` \| `medium` \| `high`. Agent triage, kept in the draft only — **never** sent to the bridge/shared schema (severity there is set only when the user stated it). |
| `title` | Required, ≤ 120 chars (shared-schema max). Agent-written, factual, no hype. |
| `body` | Required. **User's exact words, verbatim and complete.** No paraphrase, no softening, no trimming of the complaint. If the critique spans several messages, concatenate them in order, separated by a blank line. |
| `context` | Agent summary only: observed behaviour, steps to reproduce, expected behaviour. Facts, not opinions about the user. |
| `reporter` | Required. User handle/name. |
| `created_at` | Required. UTC ISO-8601 of when the user said it. |
| `source` | `"muse-ephemeral"` (this adapter). |
| `attempts` | Append one entry per failed flush attempt (timestamp, result, error text). Never delete earlier attempts — the history is the audit trail. |

Validation (`flush-now.sh` enforces it): `tool`, `title`, `body`,
`reporter`, `created_at` must be non-empty; `title` ≤ 120 chars. At flush
time the draft is also translated to the shared schema
(`critique-schema.json` v0.1.0, deriving `tool_name`, `what_happened`,
`date_wib`, `dedup_key`, `target_repo`); a draft that cannot translate gets
a `failed` receipt and stays on disk — fix the field, do not delete the
user's words. A live push with no known target repo (`--repo owner/repo`
unset and no registry entry) fails the same clean way: draft kept, nothing
claimed.

## The one-line message to the user

When the push fails, say exactly one line, with the draft path, the reason,
and what still needs pushing:

```text
Draft saved at <draft path> — not yet pushed (<reason>). Run ./flush-now.sh --retry-drafts --live next session to push it.
```

Example:

```text
Draft saved at ~/workspace/critique-push-skill/drafts/20261125T103045-aider-ignores-gitignore.json — not yet pushed (gh: not authenticated). Run ./flush-now.sh --retry-drafts --live next session to push it.
```

Do not add a second message explaining, apologising, or re-summarising.
One line. (Silent-background-handover: one compact message, only what
changed.)

## Recovery — `--retry-drafts`

On the next session (new VM, same `~/workspace`), run from
`adapters/ephemeral/`:

```sh
./flush-now.sh --retry-drafts            # dry-run: shows what would be pushed
./flush-now.sh --retry-drafts --live     # actually push every pending draft
```

Behaviour per draft:

- Validates, then pushes via the bridge if present, else `gh issue create`.
- Success → receipt `status: "pushed"` with issue URL/number, **then**
  the draft file is deleted. Deletion happens only after the receipt
  exists — a draft is never deleted on the strength of an exit code alone.
- Failure → receipt `status: "failed"` with the real error, draft stays,
  a new entry is appended to its `attempts` history.
- Nothing pending → prints `No pending critique drafts.` and exits 0.

## What never happens

- The user's words are never lost to "I'll push it later" — the draft is
  written **before** the first push attempt, in the same turn.
- A draft is never deleted without a `pushed` receipt.
- A failure is never reported as a push, and a draft is never reported as
  a push. Drafted ≠ pushed, and the user is told which one it is.
- No secret is ever written into a draft or a receipt.
