# Testing — critique-push

How to verify this repo in ~5 minutes. **Everything here is dry-run:**
no network call, no GitHub Issue is created, no token is needed.
All results below were actually run on 2026-11-25 ~03:41–03:45 UTC
(10:41–10:45 WIB) on this machine (`gh` installed but **not** logged in,
`python3` present, `jsonschema` installed). Re-run them; if a result
differs, the repo changed — trust the fresh run, not this file.

One contract underlies every check: `critique-schema.json` is the single
authoritative record shape. The bridge (`bridge/push.py`), the dedicated
adapter (`adapters/dedicated/capture.sh`), and the ephemeral adapter
(`adapters/ephemeral/flush-now.sh`) all emit and validate that exact
shape (`additionalProperties: false` — a field outside the schema is a
bug, not something to silently allow). The bridge-compat fields
(`tool`/`body`/`date`/`user_words`/`evidence`) and the queue lifecycle
fields (`agent_id`/`labels`/`created_at`/`attempts`/`next_retry_at`,
status `queued`/`failed-held`) are declared in the schema itself.

## 0. Sanity — tree + git

```bash
cd ~/workspace/critique-push-skill
find . -path ./.git -prune -o -type f -print | sort
git log --oneline -3
git status --short
git remote -v        # must print nothing — local repo only, no remote
```

Expected: 21 files (see README.md repo map); no remote. `registry/`
exists now (`README.md` + `tools.yaml`, placeholders only — no real
repos mapped). There is no separate `tests/` directory by design:
tests live with the code they test (`bridge/test-push-dryrun.sh`, this
file) — SPEC.md's file table says so. `drafts/` and `receipts/` exist
as empty directories under the repo root.

## 1. Secrets grep — must return nothing

```bash
grep -rniE 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|(password|passwd|secret|api[_-]?key|access[_-]?token|private[_-]?key)\s*[:=]\s*["'"'"'][^"'"'"']{8,}|BEGIN (RSA |OPENSSH |EC |PGP )?PRIVATE KEY' --exclude-dir=.git .
echo "grep exit: $?"   # want 1 = no matches
```

Result 2026-11-25: **exit 1, no matches.** Token/PAT words that do appear
in the tree are only code references (`GH_TOKEN` / `CRITIQUE_PUSH_TOKEN`
read from the environment, "never written to disk" comments, and the
placeholders in `bridge/config.example.yaml` and `registry/tools.yaml`) —
no values.

## 2. Bridge dry-run — the shared engine

### 2a. The shipped test — PASSES

```bash
bash bridge/test-push-dryrun.sh; echo "exit: $?"
```

Result 2026-11-25: **exit 0.** The test's example critique is now fully
schema-conformant (all `critique-schema.json` required fields **plus**
the bridge's minimal contract: `tool`, `title`, `body`, `date` as
`YYYY-MM-DD`, `user_words`, `evidence`). The script asserts exit 0, a
valid dry-run receipt on stdout, the title `[bug] Search results ignore
the date filter I set` (used as-is — the bridge no longer prepends
`[<tool>]`), the user's verbatim words in the body, and that the body
comes from the repo-root `templates/critique-template.md`
(`{single-brace}` placeholders, no placeholder left unfilled, repro
steps rendered as a numbered list). Fixed 2026-11-25 — it previously
failed with `missing required field 'schema_version'` (exit 2).

### 2b. Bridge dry-run with a schema-conformant critique — PASSES

```bash
python3 bridge/push.py --critique /tmp/cp-conformant.json --repo example-owner/example-repo
echo "exit: $?"   # want 0
```

The critique must carry **both** field sets in one object: the schema
fields **plus** the bridge's minimal contract (`tool`, `title`,
`body`, `date` as `YYYY-MM-DD`, optional `user_words` / `evidence`).
Result 2026-11-25: **exit 0**, receipt JSON on stdout with
`"dry_run": true`, `"issue_url": null`, `"issue_number": null`, and the
rendered title/body on stderr, starting with the `[dry-run] dedup search
(not run): gh issue list …` preview. Nothing leaves the machine. The
body is rendered from `templates/critique-template.md` (the same file
§2a proves), not the built-in template.

## 3. Dedicated adapter dry-run

### 3a. Install (isolated home — does not touch your real `~/.critique-push`)

```bash
CRITIQUE_PUSH_HOME=/tmp/cp-home-test bash adapters/dedicated/install.sh
echo "exit: $?"   # want 0
ls -R /tmp/cp-home-test   # queue/ receipts/ log/ config
```

Result 2026-11-25: **exit 0.** Prints `created: …/config`,
`auth method: none`, the `gh auth login` hint, and
`queue: /tmp/cp-home-test/queue`. Install succeeds without auth by design.
The config's default bridge path is now `bridge/push.py`.

### 3b. Capture dry-run — PASSES

```bash
CRITIQUE_PUSH_HOME=/tmp/cp-home-test bash adapters/dedicated/capture.sh --dry-run \
  --repo example-owner/example-repo --title "CLI hangs on large repos" \
  --summary "Running the agent on a repo with 50k files hangs for minutes with no output." \
  --expected "Show progress or finish in seconds."
echo "exit: $?"   # want 0
```

Result 2026-11-25: **exit 0.** `capture.sh` builds a full
`critique-schema.json` record (schema fields + bridge compat fields +
queue lifecycle fields), validates it — full `jsonschema` validation on
this machine — and renders it through `bridge/push.py --dry-run`, so the
printed body is exactly what would be filed, from
`templates/critique-template.md`. Nothing is queued on a dry run.
Fixed 2026-11-25 — it previously exited 2 because the adapter's own
record shape (`repo`/`summary`/`tool`/`agent_id`/…) was rejected by the
schema's `additionalProperties: false`. The fix aligned the emitter to
the schema (the schema was only extended with explicitly declared
bridge-compat and queue-lifecycle fields, not loosened).

### 3c. Capture + flush dry-run with a queued file — PASSES

```bash
# queue one critique for real (writes one JSON file, no network):
CRITIQUE_PUSH_HOME=/tmp/cp-home-test bash adapters/dedicated/capture.sh \
  --repo example-owner/example-repo --title "CLI hangs on large repos" \
  --summary "Running the agent on a repo with 50k files hangs for minutes with no output." \
  --expected "Show progress or finish in seconds." --category bug
# then:
CRITIQUE_PUSH_HOME=/tmp/cp-home-test bash adapters/dedicated/capture.sh --flush --dry-run
echo "exit: $?"   # want 0
```

Result 2026-11-25: **exit 0** for both. The queued file validates
against `critique-schema.json` under `jsonschema` (checked directly).
Flush dry-run prints `=== would file: … ===` plus the bridge-rendered
body (verbatim quote, `## Expected`, `## Steps to reproduce`,
`## Environment`, footer `critique id … · category bug`), then
`1 critique(s) would be filed. Nothing was pushed.` The queue file is
untouched. The flush calls the bridge as
`python3 bridge/push.py --critique <file> --repo <owner/repo> --dry-run`
(live would add `--live`); the old `bridge/push.sh --title/--body-file`
call is gone.

## 4. Ephemeral adapter dry-run — PASSES

```bash
rm -rf /tmp/cp-eph-test && mkdir -p /tmp/cp-eph-test/drafts
ln -s ~/workspace/critique-push-skill/bridge /tmp/cp-eph-test/bridge
# write a draft per adapters/ephemeral/draft-fallback.md
# (tool, version, severity, title, body = user's exact words,
#  context, reporter, created_at, source: muse-ephemeral)
CRITIQUE_PUSH_ROOT=/tmp/cp-eph-test \
  bash adapters/ephemeral/flush-now.sh --draft /tmp/cp-eph-test/drafts/20261125T103000-example.json \
  --repo example-owner/example-repo
echo "exit: $?"   # want 0
cat /tmp/cp-eph-test/receipts/*.receipt.json
# and:
CRITIQUE_PUSH_ROOT=/tmp/cp-eph-test \
  bash adapters/ephemeral/flush-now.sh --retry-drafts --repo example-owner/example-repo
echo "exit: $?"   # want 0
```

Result 2026-11-25: **exit 0** for both. Prints `=== DRY RUN — nothing
pushed ===`, `Draft translates cleanly to the shared schema
(critique-schema.json v0.1.0).`, the `gh issue create …` command that
would run without a bridge, then the bridge dry-run rendering from
`templates/critique-template.md` (receipt JSON on stdout, rendered
title/body on stderr); writes a receipt with `"status": "dry-run"`,
`"issue_url": null`, `"issue_number": null`. `flush-now.sh` translates
the draft to the shared schema **before** any push attempt, and the
dry-run now also runs that translation through `push.py --dry-run`, so
a draft the bridge would reject fails the dry-run with a `failed`
receipt instead of a `dry-run` one. `--retry-drafts` dry-run replays
the same path for every pending draft.

A real `failed` receipt existed in the repo during the earlier build
(`receipts/20261125T103045-test-critique.receipt.json`, status `failed`,
error `critique missing required field(s): tool, body, date`) — a live
`--live` attempt made before `translate_draft` existed; another agent
removed the file before delivery, so the error text is preserved here
as the record. The matching draft had stayed in `drafts/` because a
draft is deleted only after a `pushed` receipt.

## 5. What "done" means for this repo

- [x] §1 secrets grep: exit 1, no matches.
- [x] §2a `test-push-dryrun.sh`: exit 0, repo template rendered.
- [x] §2b bridge dry-run with a schema-conformant critique: exit 0,
      receipt `dry_run: true`.
- [x] §3a install: exit 0, `queue/ receipts/ log/ config` created.
- [x] §3b capture dry-run: exit 0, bridge-rendered body, nothing queued.
- [x] §3c capture + flush dry-run: exit 0, `Nothing was pushed.`
- [x] §4 ephemeral dry-run + `--retry-drafts` dry-run: exit 0, `dry-run`
      receipt written.

All seven are green as of 2026-11-25 (fix-up pass).

## What is NOT verified (do not claim it)

- **No live push has ever run.** `gh` is not logged in on this machine,
  no Issue exists on GitHub from this skill, no receipt with a real
  `issue_url` exists. The first live push needs `gh auth login` (or
  `GH_TOKEN`/`CRITIQUE_PUSH_TOKEN`) **and** a real target repo, run by a
  human — it is deliberately not part of this checklist.
- **Live dedup not verified.** The dedup search is only previewed in
  dry-run (`[dry-run] dedup search (not run)`). The 7-day same-symptom
  → comment-instead-of-new-Issue rule has never executed.
- **Cron flush not verified.** The hourly cron line in INSTALL.md was
  never installed or observed running.
- **Registry not verified — it holds placeholders only.** `target_repo`
  resolution is manual (`--repo`) until the user approves real mappings.
- **The dedicated adapter's live flush path not verified.** Its dry-run
  calls the bridge (`push.py --critique … --repo …`), but `--live` has
  never run — no auth, no real repo.
