# critique-push — Spec

**Version:** 0.1.0 · **Date:** 2026-11-25 · **Status:** draft for user review

## What this skill is

A skill that lets a user of any agentic-AI tool send a critique of that tool
straight to the tool's GitHub repo — as a GitHub Issue, written in the user's
own voice, bridged by their agent. The user complains (or praises-then-points-
out-a-flaw) in normal conversation; the agent captures it, validates it,
redacts private data, and pushes it to GitHub. The user never has to open
GitHub, write Markdown, or know the repo layout.

## Decisions (locked)

1. **One Issue per critique.** No batching, no digest issues. One critique =
   one Issue. Keeps threads actionable and lets maintainers close one thing
   at a time.
2. **Never silent.** Nothing is pushed without the user saying so (see
   Trigger rules). The agent may *offer* to push; it never pushes on its
   own initiative.
3. **User POV, agent evidence.** The Issue body is the user's words first;
   the agent contributes only observed facts (repro, logs, versions). The
   agent never invents repro steps, severity, or a version number.
4. **Privacy before push.** Redaction is mandatory and happens before any
   network call to GitHub. Anything sensitive the user has not explicitly
   approved stays out.
5. **Local-first queue.** Every critique is saved locally (validated JSON +
   rendered Markdown) before any push is attempted. A failed push is a
   queued item with a receipt status of `pending`, never a lost critique.
6. **Dedup by symptom, not by wording.** Same tool + same symptom within
   7 days = comment on the existing Issue, not a new Issue.
7. **Two runtime modes, one contract.** Dedicated/persistent agents and
   ephemeral agents run the same pipeline (`capture → validate → queue/flush
   → push → receipt`); only the queue storage and the push timing differ.
   See "Runtime modes".

## What counts as a critique (auto-pushable)

A critique is a concrete, actionable observation about a tool the user
actually used. Any of these qualifies:

| Type | Example |
| --- | --- |
| Bug | "It crashed when I pasted a 2 MB log." |
| UX friction | "I couldn't find where to cancel the run — the button is hidden." |
| Wrong output | "It said the file was saved, but nothing was written." |
| Missing feature | "There's no way to export the transcript." |
| Confusing copy | "The error says 'invalid state' but doesn't say what to fix." |

A critique must have at least: **what happened** and **what the user
expected instead**. If either is missing, the agent asks one short question
before drafting — it does not guess.

## What does NOT auto-push

These need **explicit user confirmation** (a clear "yes, send it anyway")
before anything leaves the machine — and the agent must say why it is
asking:

- **Praise only** ("this tool is great") — no actionable content; offer to
  post it as a Discussion/reaction instead, or skip it.
- **Vague venting** ("this sucks", "I'm frustrated") — no symptom, no
  expected behaviour. Ask what specifically went wrong first.
- **Private data** — any critique that cannot be told without names,
  emails, tokens, keys, internal URLs, or private file contents.
- **Security incident** — suspected breach, leaked credential, account
  hijack. Never auto-filed as a public Issue. Route to the tool's private
  security contact / `SECURITY.md` flow, and tell the user to rotate the
  credential first.
- **Anything about a third party** — a critique that is really about
  another person's account, data, or behaviour, not the tool itself.

If the user confirms after the warning, the item proceeds — but the
sensitive part is still redacted (see Privacy).

## Trigger rules

Push happens only on one of these two triggers. Anything else is "not a
push yet — offer, don't act".

1. **Explicit:** the user says "push this to GitHub", "file this",
   "report this", "send this to the repo", or equivalent, referring to a
   specific critique.
2. **Clear critique + send intent:** the user states a concrete critique
   AND says send/report it in the same turn or an immediately following
   turn ("yeah, send that", "report it please").

**Never push on:** a bare complaint with no send intent; a critique the
user only mentioned in passing; an ambiguous "maybe I should report this";
anything the agent inferred but the user did not confirm. When in doubt,
draft the Issue locally and ask: "Ready to push this to GitHub?" — one
question, showing the title and the redacted body.

## User-POV voice rules

- **First person, user's voice.** The Issue reads as the user speaking:
  "I ran X and got Y" — not "the agent observed" or "the user reports".
- **Quote the user's exact words** for the core complaint (the "what
  happened" / "expected" pair). Put the verbatim quote in a blockquote at
  the top of the body.
- **Agent adds only evidence:** repro steps the agent actually ran,
  observed output, version/commit, timestamps, environment. Label this
  section "Agent-added evidence" so maintainers can tell it apart.
- **Never invent:** no guessed repro steps, no assigned severity, no
  version number the agent did not observe, no "steps to reproduce" the
  user never described. Unknown fields stay `unknown` / omitted — never
  filled with a plausible guess.
- **No agent self-reference in the Issue.** The Issue never says "my AI
  assistant" or names the agent. It is the user's report.
- **Language:** the user's language. If the user wrote in Indonesian, the
  Issue is in Indonesian (with an English one-line summary if the repo's
  maintainers work in English — only if the user agrees).

## Required fields

Every critique record (see `critique-schema.json`) carries:

| Field | Required? | Notes |
| --- | --- | --- |
| `tool_name` | yes | e.g. `codex`, `claude-code`, `omp`, `hermes` |
| `tool_version` / `tool_commit` | if known | `unknown` if not observable; never guessed |
| `category` | yes | `bug` \| `ux-friction` \| `wrong-output` \| `missing-feature` \| `confusing-copy` \| `other` |
| `title` | yes | short, symptom-first (see Title format) |
| `what_happened` | yes | user's exact words (verbatim quote) |
| `expected` | yes | what the user expected instead |
| `actual` | yes | what actually happened |
| `repro_steps` | if known | only steps actually run/observed; `[]` if none |
| `impact` | yes | one line, user's words where possible (blocked work? annoyance? data loss?) |
| `environment` | yes | OS, shell/CLI vs chat, model if relevant; `unknown` fields allowed |
| `date_wib` | yes | `YYYY-MM-DD HH:mm WIB` (Asia/Jakarta) |
| `severity` | no | only if the user stated it; never agent-assigned |
| `attachments` | no | screenshots/logs only after redaction + user approval |
| `target_repo` | yes | `owner/repo`; resolved by the registry (Subagent 4), never guessed |
| `dedup_key` | yes | `tool_name + normalized symptom`, computed at validate time |

The record also carries the bridge's compat fields (`tool`, `body`,
`date` as `YYYY-MM-DD`, `user_words`, `evidence`) and, on a dedicated
machine, the queue lifecycle fields (`agent_id`, `labels`, `created_at`,
`attempts`, `next_retry_at`) — all declared in `critique-schema.json`,
which is the single authoritative contract for the record shape. The
bridge, the dedicated adapter, and the ephemeral adapter all emit and
validate this exact shape; `additionalProperties` stays `false`.

## Privacy / redaction

Redaction runs **before** the push, on the local copy, and the user sees
the redacted body before confirming. Strip or replace:

- Real names, emails, phone numbers, usernames/handles (unless the user's
  public GitHub handle, with consent).
- API keys, tokens, passwords, session cookies, PATs, OTP codes.
- Absolute file paths outside the tool's repo (replace with
  `<redacted-path>`); home-directory paths (`/home/<user>/…`,
  `C:\Users\<user>\…`).
- Internal URLs, private IPs, hostnames of the user's own machines.
- Screenshots containing any of the above, private chats, or other
  people's data — crop or drop, never push as-is.
- Anything the user marked private in the conversation.

**Rule:** if removing the sensitive part would gut the critique, stop and
ask the user how to proceed (rephrase? skip? private report?) — do not
push a gutted Issue silently. If the user explicitly approves including a
sensitive item, record that approval (`consent_includes_sensitive: true`
+ what was included) in the local record.

## GitHub target decision

- **Default:** one Issue per critique in the tool's own repo
  (`target_repo` from the registry).
- **Title format:** `[<category>] <symptom in ≤ 10 words>` —
  e.g. `[bug] CLI crashes on paste of large log`.
- **Labels:** `critique` + the category label (`bug`, `ux`,
  `wrong-output`, `feature-request`, `docs/copy`) when the repo has them;
  never create new labels. If the repo has no matching labels, push with
  `critique` only (or none, if even that is absent).
- **Body:** rendered from `templates/critique-template.md` (verbatim user
  quote first, then expected/actual, repro, environment, agent-added
  evidence clearly separated).
- **Dedup rule:** same `tool_name` + same normalized symptom within **7
  days** → do **not** open a new Issue; post a comment on the existing
  Issue ("Same issue reported again on <date>: <user's one-line quote>")
  and record the comment URL as the receipt. The 7-day window is per
  symptom, not per user.
- **No repo / no mapping:** if `target_repo` cannot be resolved, save the
  critique locally as `pending-unmapped` and tell the user — never guess a
  repo, never push to a wrong repo.
- **Auth:** the push uses the user's own GitHub credentials (their PAT /
  `gh` auth), never a shared or agent-owned token. No credential is ever
  written into the repo, the Issue, or the local record.

## Runtime modes (spec-level contract)

Both modes implement the same five-stage pipeline. Only storage and
timing differ.

```
capture → validate → queue/flush → push → receipt
```

| Stage | Contract (both modes) |
| --- | --- |
| capture | Turn the user's words into a draft critique record; keep the verbatim quote. |
| validate | Check against `critique-schema.json`; classify; run redaction; resolve `target_repo`; compute `dedup_key`. Failures stop here with a message to the user. |
| queue/flush | Persist the validated record locally before any network call. |
| push | Create the Issue (or dedup comment) via the GitHub API / `gh`. One attempt per record per run; on failure, keep status `pending` and report. |
| receipt | Save the Issue URL + number (or comment URL) into the local record; tell the user the link. No receipt = not done. |

### Mode A — Dedicated / persistent computer

(Hermes-style box, or a CLI agent like Codex / omp / Claude Code running
on the user's own machine.)

- Queue is a durable on-disk directory (e.g. `~/.critique-push/queue/`)
  with one JSON file per critique + rendered `.md`.
- A background job (cron / agent heartbeat) flushes `pending` items on a
  schedule; the user may also flush on demand ("push my pending
  critiques").
- Receipts are written back into the same record; a local index lists
  every critique and its Issue URL.

### Mode B — Ephemeral computer

(Muse-style sandbox: the machine may vanish after the session.)

- Queue lives in the session workspace; **flush happens in the same
  session, immediately after user confirmation** — there is no "later".
- If the push cannot complete before the session ends, the agent must
  hand the user the rendered Markdown + the target repo so they (or a
  later session) can file it manually. Never claim it was pushed.
- Receipt is reported in-chat in the same turn; if the session ends
  without a receipt, the record is marked `unflushed` and the user is
  told so explicitly.

## Worked example (invented example — not a real report)

> User (in chat, 2026-11-25 10:15 WIB): "I ran `codex --version` after
> updating and it just hangs, no output at all. I expected it to print
> the version and exit. This is blocking me from checking which version
> I'm on."

Rendered Issue (after redaction + validation):

- **Repo:** `openai/codex` *(example target — resolved by registry)*
- **Title:** `[bug] CLI hangs on --version after update, no output`
- **Body:** (see `templates/critique-template.md`, filled in)
  - Verbatim quote: the user's sentence above.
  - Expected: prints version and exits. Actual: hangs, no output.
  - Repro: `codex --version` (observed once by the agent; no other steps
    claimed).
  - Environment: `codex` version unknown (not observable — the command
    hangs), Linux, CLI.
  - Impact: "blocking me from checking which version I'm on" (user's
    words).
  - Severity: not set (user didn't state one).

## What this spec does NOT decide (open for the user)

- The exact GitHub auth setup per tool (PAT scopes, `gh` vs API token) —
  owned by the adapter subagents; user to confirm one method.
- Which repos are in the registry and who maintains the mapping —
  Subagent 4's registry; user to approve the initial repo list.
- Whether praise-only items get a Discussion post or are dropped —
  default is drop unless the user says otherwise.
- The 7-day dedup window is a starting value; user may change it.
- Queue directory path and flush schedule for Mode A — defaults proposed
  by Subagent 2, user to confirm.

## Files in this repo

| File | Owner |
| --- | --- |
| `SPEC.md` (this file) | Subagent 1 — spec |
| `critique-schema.json` | Subagent 1 — spec |
| `templates/critique-template.md` | Subagent 1 — spec |
| `SKILL.md` | Subagent 2 — skill text |
| `adapters/` | Subagent 3 — runtime adapters |
| `registry/` | Subagent 4 — tool→repo registry (placeholders only; see `registry/README.md`) |
| `bridge/test-push-dryrun.sh` + `TESTING.md` | Subagent 5 — tests + repo wiring (tests live with the code they test; there is no separate `tests/` directory) |
