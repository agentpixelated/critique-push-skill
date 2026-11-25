# critique-push — bridge

The one push engine both adapters call, so a critique filed from a
dedicated computer and one filed from an ephemeral computer are rendered,
deduped, and filed identically. Neither adapter talks to GitHub directly —
both shell out to `bridge/push.py`.

```
dedicated adapter (Hermes / Codex / omp / Claude Code / any CLI agent)
        \
         +--> bridge/push.py --critique <json> --repo <owner/repo>
        /        |  dry-run by default; --live + token to actually file
ephemeral adapter (Muse)
```

## Files

| File | Purpose |
| --- | --- |
| `push.py` | The engine. Stdlib only, no dependencies. |
| `config.example.yaml` | Copy to `config.yaml`, fill in your repo. Placeholders only — no real values. |
| `test-push-dryrun.sh` | Dry-run test: validates + renders a labelled example critique, asserts exit 0 and title/body present. |
| `../templates/critique-template.md` | (Owned by the schema/template agent.) `push.py` renders the issue body from it — `{single-brace}` placeholders, substituted in `render()`; if the file is absent it uses its built-in template. |

## Usage

```bash
# Dry run (default) — validates, renders, prints the dedup search it
# WOULD run and the exact issue it WOULD file. Nothing leaves the machine.
python3 bridge/push.py --critique critique.json --repo owner/repo

# Live — requires the flag AND a token from the environment,
# or an already-authenticated `gh` CLI.
GH_TOKEN=... python3 bridge/push.py --critique critique.json \
    --repo owner/repo --live --labels critique,ux
```

Output on success is a receipt on stdout:

```json
{
  "issue_url": "https://github.com/owner/repo/issues/42",
  "issue_number": 42,
  "repo": "owner/repo",
  "pushed_at": "2026-11-25T03:30:00Z",
  "critique_id": "crit-2026-11-25-001",
  "dry_run": false
}
```

In dry-run, `issue_url` and `issue_number` are `null` and `dry_run` is `true`.

## Rules the bridge enforces

- **Dry-run is the default.** A real push needs explicit `--live`.
- **Tokens never travel as CLI arguments.** `GH_TOKEN` / `GITHUB_TOKEN`
  from the environment only, or `gh auth`. The token is never logged and
  never written to disk by this bridge.
- **User POV first.** The issue body leads with the user's own words
  (verbatim); anything the agent added is under a clearly labelled
  "Agent-added evidence" section. No reproduction steps are invented —
  if the user didn't describe them, they aren't in the issue.
- **Dedup before create.** Existing issues are searched by title keywords
  (`gh issue list --search`). A match aborts the push with exit 3 and
  lists the candidates instead of silently filing a duplicate.
- **No silent success.** Any failure exits non-zero with a clear stderr
  message. Exit codes: `0` pushed (or dry-run OK), `1` push failed,
  `2` bad input / missing auth, `3` possible duplicate found.
- **Create path:** `gh issue create` subprocess first; fallback is the
  GitHub REST API via `urllib` (stdlib) with the env token.

## Validation

Critiques are validated against `../critique-schema.json`, which is the
single contract and must exist: its `required` list, its
`additionalProperties: false`, and its field formats are all enforced,
plus the bridge's own minimal contract (`tool`, `title`, `body`, `date`
as `YYYY-MM-DD`; `tool` must equal `tool_name`, `body` must equal
`what_happened`, `date` must be the date part of `date_wib`). The title
is used as-is when it already carries SPEC's `[<category>]` prefix,
otherwise the category is prepended — the bridge never prepends
`[<tool>]`. The body is rendered from
`../templates/critique-template.md` (`{single-brace}` placeholders),
else the built-in template in `push.py`.

## Test

```bash
bash bridge/test-push-dryrun.sh
```

Runs the dry-run path on a labelled example critique and asserts exit 0
plus title/body present. It never touches the network or GitHub.
