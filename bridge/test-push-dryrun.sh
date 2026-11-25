#!/usr/bin/env bash
# Dry-run test for bridge/push.py.
# Validates + renders a labelled example critique, asserts exit 0 and that
# the rendered title/body are present. Never touches the network or GitHub.
#
# The example critique is fully schema-conformant: it carries BOTH field
# sets in one object — the critique-schema.json required fields AND the
# bridge's minimal contract (tool/title/body/date). That is the single
# contract every emitter must produce (see critique-schema.json).
set -euo pipefail

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

CRITIQUE="$TMPDIR_WORK/example-critique.json"
cat > "$CRITIQUE" <<'EOF'
{
  "schema_version": "0.1.0",
  "id": "crit-test-dryrun-001",
  "tool_name": "example-tool",
  "tool": "example-tool",
  "tool_version": null,
  "tool_commit": null,
  "category": "bug",
  "title": "[bug] Search results ignore the date filter I set",
  "what_happened": "I set the date filter to last week but it still shows last month's stuff, that's broken",
  "body": "I set the date filter to last week but it still shows last month's stuff, that's broken",
  "user_words": "I set the date filter to last week but it still shows last month's stuff, that's broken",
  "expected": "Only results from last week.",
  "actual": "Results still show items from last month.",
  "impact": "I cannot trust the search results.",
  "environment": {"os": "unknown", "runtime": "cli", "model": null, "notes": null},
  "repro_steps": ["Set the date filter to last week", "Run a search"],
  "date_wib": "2026-11-25 10:30 WIB",
  "date": "2026-11-25",
  "target_repo": "example-owner/example-repo",
  "dedup_key": "example-tool+search-results-ignore-date-filter",
  "status": "pending",
  "severity": null,
  "evidence": "Agent observed: filter parameter present in request; response contained items dated 2026-10-20."
}
EOF

echo "== dry-run push =="
set +e
python3 "$BRIDGE_DIR/push.py" --critique "$CRITIQUE" \
  --repo example-owner/example-repo --dry-run \
  > "$TMPDIR_WORK/stdout.txt" 2> "$TMPDIR_WORK/stderr.txt"
STATUS=$?
set -e
OUTPUT="$(cat "$TMPDIR_WORK/stdout.txt")"
echo "$OUTPUT"
echo "--- stderr (rendered issue preview) ---"
cat "$TMPDIR_WORK/stderr.txt"

fail() { echo "FAIL: $1" >&2; exit 1; }

[ "$STATUS" -eq 0 ] || fail "push.py exited $STATUS, expected 0"

# Receipt assertions (stdout JSON)
echo "$OUTPUT" | python3 -c "
import json, sys
r = json.load(sys.stdin)
assert r['dry_run'] is True, 'dry_run flag'
assert r['issue_url'] is None, 'issue_url must be null in dry-run'
assert r['issue_number'] is None, 'issue_number must be null in dry-run'
assert r['repo'] == 'example-owner/example-repo', 'repo echo'
assert r['critique_id'] == 'crit-test-dryrun-001', 'critique_id echo'
assert r['pushed_at'], 'pushed_at present'
" || fail "receipt JSON assertions failed"

# Title/body assertions (stderr preview).
# Title is used as-is: SPEC's [<category>] prefix, no [<tool>] prepended.
grep -qF "[bug] Search results ignore the date filter I set" \
  "$TMPDIR_WORK/stderr.txt" || fail "rendered title missing"
grep -qF "[example-tool] [bug]" \
  "$TMPDIR_WORK/stderr.txt" && fail "double-bracket title: bridge prepended [tool]"
grep -qF "I set the date filter to last week but it still shows last month's stuff" \
  "$TMPDIR_WORK/stderr.txt" || fail "user's verbatim words missing from body"
grep -qF "Agent-added evidence" \
  "$TMPDIR_WORK/stderr.txt" || fail "agent-evidence label missing from body"
grep -qF "dedup search (not run)" \
  "$TMPDIR_WORK/stderr.txt" || fail "dedup hook preview missing"

# Template assertions: the body must come from templates/critique-template.md
# (repo root, {single-brace} placeholders), not the built-in template —
# no placeholder may survive substitution, and the template's sections
# (Expected / Actual / Steps to reproduce / Impact / Environment) must render.
grep -qF "## Expected" "$TMPDIR_WORK/stderr.txt" || fail "template section 'Expected' missing"
grep -qF "## Actual" "$TMPDIR_WORK/stderr.txt" || fail "template section 'Actual' missing"
grep -qF "## Steps to reproduce" "$TMPDIR_WORK/stderr.txt" || fail "template section 'Steps to reproduce' missing"
grep -qF "1. Set the date filter to last week" "$TMPDIR_WORK/stderr.txt" || fail "repro steps not rendered as numbered list"
grep -qF "Only results from last week." "$TMPDIR_WORK/stderr.txt" || fail "expected text missing from body"
grep -qF "crit-test-dryrun-001" "$TMPDIR_WORK/stderr.txt" || fail "critique id footer missing"
if grep -qE '\{[a-z_]+\}' "$TMPDIR_WORK/stderr.txt"; then
  fail "unfilled {placeholder} left in rendered body"
fi

echo "PASS: dry-run test — exit 0, title/body present, receipt valid, repo template rendered"
