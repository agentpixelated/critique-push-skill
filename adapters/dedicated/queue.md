# Queue format + retry rules (dedicated adapter)

## Location

`~/.critique-push/queue/` — one JSON file per critique, named `<id>.json`.
The directory lives on a persistent disk, so the queue survives reboots,
agent restarts, and laptop sleep. (`CRITIQUE_PUSH_HOME` overrides `~/.critique-push`
for testing; never point it at a shared or synced folder that other agents
write to without coordination.)

## File format

One JSON object per file — a `critique-schema.json` record (the single
contract), plus the queue lifecycle fields. Fields (see `README.md` for
the full table):

```json
{
  "schema_version": "0.1.0",
  "id": "cp-20261125T103000-a1b2",
  "tool_name": "codex",
  "tool": "codex",
  "tool_version": "0.41.0",
  "tool_commit": null,
  "category": "bug",
  "title": "[bug] CLI hangs on large repos",
  "what_happened": "What happened, in the user's words.",
  "body": "What happened, in the user's words.",
  "user_words": "What happened, in the user's words.",
  "expected": "What the user expected instead.",
  "actual": "What actually happened.",
  "impact": "One line on impact.",
  "environment": {"os": "Linux", "runtime": "dedicated-box", "model": null, "notes": null},
  "repro_steps": ["Open a large repo", "Ask for a summary"],
  "date_wib": "2026-11-25 10:30 WIB",
  "date": "2026-11-25",
  "target_repo": "owner/repo",
  "dedup_key": "codex+cli-hangs-on-large-repos",
  "status": "queued",
  "severity": null,
  "evidence": "None recorded by the agent.",
  "receipt": null,
  "agent_id": "hermes",
  "labels": "bug",
  "created_at": "2026-11-25T10:30:00Z",
  "attempts": 0,
  "next_retry_at": null
}
```

- `status`: `queued` | `pushed` | `failed-held`.
- `attempts`: number of flush attempts so far. Starts at 0.
- `next_retry_at`: UTC ISO 8601 when the next attempt is due, or `null`
  when no retry is scheduled (freshly queued, pushed, or held).
- `receipt`: `null` until pushed, then `{issue_url, issue_number,
  pushed_at_wib}` — the only place the Issue URL/number live.
- No secrets ever appear in a queue file. A file containing a token is a
  bug — delete the token, not the critique.

## Lifecycle

```
capture  →  queued  →  flush attempt  →  pushed (receipt saved)
                              ↓ fail
                          queued (retry scheduled)
                              ↓ fail, attempts = 3
                          failed-held (stays queued, user told)
```

## Flush

- Command: `capture.sh --flush` (cron, hook, or manual).
- Order: oldest `created_at` first. Already-`pushed` files are skipped,
  never re-filed.
- `--flush --dry-run` prints each would-be issue body and files nothing.
- An empty queue is a successful no-op (`queue empty — nothing to flush.`).

## Retry rules

- Max **3 attempts** per critique (attempts counted in the file).
- Backoff between attempts: **5 min → 30 min → 2 h** (from the failed
  attempt; stored in `next_retry_at`). A flush run skips files whose
  `next_retry_at` is still in the future.
- After the 3rd failed attempt: `status` becomes `failed-held`,
  `next_retry_at` is cleared, and the run prints
  `Held: <id> (<reason>) — will retry, nothing dropped.` The user must be
  told in chat that a critique is held and why (auth failure, network,
  repo not found, rate limit, …).
- A held critique is retried only by an explicit manual flush
  (`capture.sh --flush` retries held files too) or by the user asking for
  it — never silently retried forever, never deleted.
- **Never drop a critique silently.** The only way a queue file leaves the
  directory is: it was pushed (file kept, with receipt), or the user
  deletes it by hand. There is no auto-expiry, no auto-delete, no
  "clean-up old failures".

## Concurrency

Two agents on one machine share one queue directory (Hermes + omp on the
same laptop, for example). Safety rules:

- Files are written with `cp` to a final name — one file per critique, no
  shared index file to corrupt.
- Each agent flushes only files it can read; the `agent_id` on a file is
  the capturing agent and is never rewritten by the flushing agent.
- If two flushes run at once, the second may fail to push a file the first
  already pushed; the receipt write is idempotent (`status: pushed` +
  same URL), so a duplicate push is surfaced by the duplicate issue, not
  by queue corruption. Prefer a single cron owner per machine to avoid
  this.
