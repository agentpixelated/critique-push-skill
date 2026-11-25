# Muse capture runbook — ephemeral computer

Follow these steps **in the same turn** the user gives a critique. Do not
defer any step to a later turn, a background job, or a cron — this VM may not
exist by then. Stay silent while working (silent-background-handover);
the user hears one line at the end.

## 0. Is this a critique to push?

Push when the user, in their own words, says a tool behaved wrongly, is
missing something, misled them, or should work differently — and they are
talking about the tool, not asking you to fix their own setup. When in
doubt, ask once: "Push this as a critique to the tool's repo?" A "yes"
(or an obvious critique with no ambiguity) proceeds. A "no" stops here —
no draft, no flush, nothing saved.

## 1. Write the draft first (before any network call)

Create `drafts/<UTC-timestamp>-<slug>.json` under the repo root
(`~/workspace/critique-push-skill/drafts/`, or `$CRITIQUE_PUSH_ROOT/drafts/`).
Schema — see `draft-fallback.md` for the full spec:

```json
{
  "tool": "<tool name, e.g. aider>",
  "version": "<tool version if known, else \"unknown\">",
  "severity": "low|medium|high",
  "title": "<short title, agent-written, <= 120 chars (shared schema max)>",
  "body": "<USER'S EXACT WORDS — verbatim, unparaphrased>",
  "context": "<one-paragraph agent summary: what happened, steps to reproduce>",
  "reporter": "<user handle or name>",
  "created_at": "<UTC ISO-8601>",
  "source": "muse-ephemeral"
}
```

Rules:

- `body` is verbatim. Never paraphrase, soften, or "improve" the user's
  words there. Your summary goes in `context` only.
- `title` and `context` are yours; keep them factual and short. Title max
  120 chars — the shared schema (`critique-schema.json`) enforces it.
- `severity` is agent triage for the draft only. It is **not** sent to the
  bridge: the shared schema sets severity only when the user stated it,
  never agent-assigned. `flush-now.sh` translates the draft to the shared
  schema (deriving `tool_name`, `what_happened` = verbatim `body`,
  `date_wib`, `dedup_key`, `target_repo`) before calling `bridge/push.py`;
  a draft that cannot translate fails with a `failed` receipt and stays
  in `drafts/`.
- If you do not know the tool version, write `"unknown"` — never guess.
- The draft file is the queue. If everything after this fails, the draft is
  what survives, so write it completely before doing anything else.

## 2. Flush immediately, in the same turn

```sh
cd ~/workspace/critique-push-skill/adapters/ephemeral
./flush-now.sh --draft ../../drafts/<file>.json --live
```

- Default (no `--live`) is a **dry run**: prints the exact `gh issue create`
  command and issue body, writes a `dry-run` receipt, pushes nothing.
  Use dry-run when you are testing or when the user has not approved a live
  push.
- `--live` performs the real push: via `../bridge/` if it exists, otherwise
  via `gh issue create` with the user's existing `gh` auth.
- Never run the flush in the background (`&`, `nohup`, detached session).
  The turn waits for it. A backgrounded flush on this machine is a lost
  flush.

## 3. Read the receipt — then, and only then, report

The script writes a receipt to `receipts/<same-stem>.receipt.json` **before**
it exits. Open it and read it. The receipt is the only source of truth:

- `status: "pushed"` + `issue_url` / `issue_number` → report:
  `Pushed: <issue_url>`
- `status: "dry-run"` → report:
  `Dry run only — not pushed. Draft saved at <draft path>.`
- `status: "failed"` + `error` → the script has already saved the draft;
  report one line (see step 4).
- **No receipt file at all** → the flush did not complete. Say so:
  `Not yet pushed — flush did not finish, draft saved at <draft path>.`
  Never say "pushed" in this case. (verify-before-claiming-done: no receipt,
  no done-claim.)

Name what you did not check in the same message when anything is unchecked
(e.g. "did not verify the issue renders on GitHub — link only").

## 4. If the push fails or the VM is about to die

Do not retry in a loop and do not wait for a daemon. The draft file from
step 1 is already complete and persisted. Tell the user exactly one line:

```text
Draft saved at <draft path> — not yet pushed (<reason>). Run ./flush-now.sh --retry-drafts --live next session to push it.
```

Then stop. See `draft-fallback.md` for the full fallback spec.

## 5. Next session: retry undelivered drafts

At the start of a new session (new VM, same `~/workspace`), before other
work, run:

```sh
./flush-now.sh --retry-drafts            # dry-run first: see what would go out
./flush-now.sh --retry-drafts --live     # push them for real
```

A draft leaves `drafts/` only after its receipt says `pushed` with a real
issue URL. Report one compact line per pushed draft, or one line total if
nothing was pending ("No pending critique drafts.").

## Checklist (per critique)

- [ ] Draft JSON written completely, `body` verbatim, before any push attempt
- [ ] `flush-now.sh` run in the foreground, in the same turn
- [ ] Receipt file opened and read
- [ ] User told exactly one line, grounded in the receipt
- [ ] If failed: draft path + reason + retry command given; no "pushed" claimed
