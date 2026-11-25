#!/usr/bin/env bash
# flush-now.sh — ephemeral-computer flush for critique-push-skill (Muse adapter)
#
# Pushes one critique draft (or all pending drafts) to GitHub as an issue.
#   - Dry-run by DEFAULT: prints the exact `gh issue create` command and the
#     issue body, writes a dry-run receipt, pushes NOTHING.
#   - --live performs the real push: via ../bridge/push.py if present
#     (draft translated to the shared critique-schema.json first), else `gh`.
#   - A receipt JSON is written to receipts/ BEFORE success is reported.
#     No receipt with a real issue URL/number == NOT pushed. Never claim
#     otherwise.
#   - On failure the draft is (kept) saved under drafts/ and a `failed`
#     receipt records the real error.
#
# Stdlib only: bash + python3 (json module). No tokens, no secrets, no
# network except what `gh` / the bridge does with the user's own auth.
#
# Usage:
#   ./flush-now.sh --draft ../../drafts/20261125T103000-example.json [--live]
#   ./flush-now.sh --retry-drafts [--live]
#   ./flush-now.sh --draft <file> --repo owner/repo --live
#
# Env:
#   CRITIQUE_PUSH_ROOT  repo root (default: two levels up from this script)
#   CRITIQUE_PUSH_REPO  target repo "owner/repo" (default: from bridge config
#                        if present, else required for --live)

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${CRITIQUE_PUSH_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
DRAFTS_DIR="$ROOT/drafts"
RECEIPTS_DIR="$ROOT/receipts"
BRIDGE_DIR="$ROOT/bridge"
mkdir -p "$DRAFTS_DIR" "$RECEIPTS_DIR"

LIVE=0
DRAFT=""
RETRY=0
REPO="${CRITIQUE_PUSH_REPO:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --live) LIVE=1; shift ;;
    --draft) DRAFT="$2"; shift 2 ;;
    --retry-drafts) RETRY=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "flush-now.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- JSON helpers (python3 stdlib only) -------------------------------------
json_get() { # json_get <file> <key> -> value or empty
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' "$1" "$2" 2>/dev/null
}

validate_draft() { # validate_draft <file> -> prints error or nothing; exit code
  python3 - "$1" <<'PYEOF'
import json, sys
required = ["tool", "title", "body", "reporter", "created_at"]
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"invalid JSON: {e}"); sys.exit(1)
missing = [k for k in required if not str(d.get(k, "")).strip()]
if missing:
    print(f"missing/empty required fields: {', '.join(missing)}"); sys.exit(1)
if len(d["title"]) > 120:
    print("title longer than 120 chars (shared schema max)"); sys.exit(1)
PYEOF
}

# Translate the small ephemeral capture draft into the shared schema
# (critique-schema.json v0.1.0) the bridge validates against. The capture
# draft stays small on purpose — the agent writes it in-turn — and this
# step derives every schema-required field from it. Severity is NOT passed
# through: the shared schema says severity is only set when the user stated
# it, never agent-assigned; the capture draft's severity is agent triage
# only and stays in the draft file.
translate_draft() { # translate_draft <draft> <repo> <out-file>
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, re, sys
from datetime import datetime, timezone, timedelta
d = json.load(open(sys.argv[1]))
repo = sys.argv[2]
out = sys.argv[3]
if not re.match(r"^[^/\s]+/[^/\s]+$", repo or ""):
    print(f"target repo unknown or invalid: {repo!r} (need owner/repo)"); sys.exit(1)
created = d.get("created_at", "")
try:
    dt = datetime.fromisoformat(created.replace("Z", "+00:00"))
except ValueError:
    print(f"created_at is not ISO-8601: {created!r}"); sys.exit(1)
wib = dt.astimezone(timezone(timedelta(hours=7)))
slug = re.sub(r"[^a-z0-9]+", "-", d["title"].lower()).strip("-")[:60]
category = d.get("category", "other")
if category not in ("bug", "ux-friction", "wrong-output", "missing-feature",
                    "confusing-copy", "other"):
    category = "other"
context = (d.get("context") or "").strip()
translated = {
    "schema_version": "0.1.0",
    "id": "crit-" + dt.strftime("%Y%m%d") + "-" + slug[:20],
    "tool_name": d["tool"],
    "tool_version": d.get("version") or None,
    "category": category,
    "title": d["title"],
    "what_happened": d["body"],
    "expected": d.get("expected") or "(not recorded — see what_happened)",
    "actual": d.get("actual") or context or "(not recorded — see what_happened)",
    "impact": d.get("impact") or "(not recorded)",
    "severity": None,
    "environment": {"os": d.get("os") or "unknown",
                    "runtime": "ephemeral-sandbox",
                    "model": None, "notes": None},
    "repro_steps": d.get("repro_steps") or [],
    "date_wib": wib.strftime("%Y-%m-%d %H:%M WIB"),
    "target_repo": repo,
    "dedup_key": d["tool"] + "+" + slug,
    "status": "pending",
    "notes": f"reporter: {d.get('reporter','unknown')} via muse-ephemeral; captured {created}",
    "receipt": None,
    # Bridge's own minimal contract (push.py, hand-rolled validation): it
    # ALWAYS requires tool/title/body/date (date = YYYY-MM-DD) on top of
    # the schema-required fields above, and render() reads tool/body plus
    # optional user_words/evidence. Keep both field sets in one object.
    "tool": d["tool"],
    "body": d["body"],
    "date": wib.strftime("%Y-%m-%d"),
    "user_words": d["body"],
    "evidence": context or "None recorded by the agent.",
}
json.dump(translated, open(out, "w"), indent=2)
PYEOF
}

issue_body() { # issue_body <draft> -> rendered markdown issue body on stdout
  python3 - "$1" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
print("## User critique (verbatim)")
print()
print(d["body"])
print()
print("## Context (agent summary)")
print()
print(d.get("context", "(none)"))
print()
print("---")
print(f"- Tool: {d.get('tool','unknown')} {d.get('version','unknown')}")
print(f"- Severity: {d.get('severity','medium')}")
print(f"- Reporter: {d.get('reporter','unknown')} via {d.get('source','muse-ephemeral')}")
print(f"- Captured: {d.get('created_at','unknown')}")
PYEOF
}

write_receipt() { # write_receipt <draft-stem> <status> <issue_url> <issue_number> <error> <command>
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PYEOF'
import json, sys, datetime
stem, status, url, num, err, cmd = sys.argv[1:7]
receipt = {
    "draft": stem + ".json",
    "status": status,                      # pushed | dry-run | failed
    "issue_url": url or None,
    "issue_number": int(num) if num.isdigit() else None,
    "error": err or None,
    "command": cmd or None,
    "flushed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "flushed_by": "muse-ephemeral/flush-now.sh",
}
import os
out = os.path.join(os.environ["RECEIPTS_DIR"], stem + ".receipt.json")
with open(out, "w") as f:
    json.dump(receipt, f, indent=2)
print(out)
PYEOF
}

# --- flush one draft ---------------------------------------------------------
flush_one() { # flush_one <draft-file>
  local draft="$1"
  local stem; stem="$(basename "$draft" .json)"
  local tool title body
  tool="$(json_get "$draft" tool)"
  title="$(json_get "$draft" title)"

  local err
  err="$(validate_draft "$draft" 2>&1)" || {
    RECEIPTS_DIR="$RECEIPTS_DIR" write_receipt "$stem" "failed" "" "" "$err" "" >/dev/null
    echo "FAILED validation: $err — draft kept at $draft"
    return 1
  }

  local body_file; body_file="$(mktemp)"
  issue_body "$draft" > "$body_file"

  # The exact command that would run (also the dry-run output).
  local repo="${REPO:-}"
  local cmd="gh issue create --repo \"${repo:-owner/repo}\" --title \"$title\" --label \"user-critique\" --body-file \"$body_file\""

  # Translate to the shared schema now, in BOTH modes, so a draft that the
  # bridge would reject is caught before any live attempt is claimed.
  local translated; translated="$(mktemp --suffix=.json)"
  local terr
  terr="$(translate_draft "$draft" "${repo:-owner/repo}" "$translated" 2>&1)" || {
    RECEIPTS_DIR="$RECEIPTS_DIR" write_receipt "$stem" "failed" "" "" "cannot translate to shared schema: $terr" "" >/dev/null
    echo "FAILED translation: $terr — draft kept at $draft"
    rm -f "$body_file" "$translated"
    return 1
  }

  if [ "$LIVE" -eq 0 ]; then
    echo "=== DRY RUN — nothing pushed ==="
    echo "Draft translates cleanly to the shared schema (critique-schema.json v0.1.0)."
    echo "Live push would use the bridge if present, else this command:"
    echo "  $cmd"
    if [ -f "$BRIDGE_DIR/push.py" ]; then
      # Render + validate exactly as the live push would, via the bridge:
      # push.py prints the receipt JSON on stdout and the rendered
      # title/body (from templates/critique-template.md) on stderr.
      # A bridge failure here is a real failure, not a dry-run receipt.
      echo "--- bridge dry-run (templates/critique-template.md rendered) ---"
      if ! python3 "$BRIDGE_DIR/push.py" --critique "$translated" --repo "${repo:-owner/repo}" --dry-run; then
        RECEIPTS_DIR="$RECEIPTS_DIR" write_receipt "$stem" "failed" "" "" "bridge dry-run rejected the translated critique (see output above)" "$cmd" >/dev/null
        echo "FAILED: bridge rejected the translated critique — draft kept at $draft"
        rm -f "$body_file" "$translated"
        return 1
      fi
      echo "--- end bridge dry-run ---"
    else
      echo "--- issue body (bridge absent; local render) ---"
      cat "$body_file"
      echo "--- end issue body ---"
    fi
    RECEIPTS_DIR="$RECEIPTS_DIR" write_receipt "$stem" "dry-run" "" "" "" "$cmd" >/dev/null
    echo "Receipt (dry-run, NOT pushed): $RECEIPTS_DIR/$stem.receipt.json"
    rm -f "$body_file" "$translated"
    return 0
  fi

  # --- live push ---
  local issue_url="" issue_num="" push_err=""
  if [ -x "$BRIDGE_DIR/push.py" ]; then
    # Shared bridge owns the real push when present. It prints a receipt
    # JSON {issue_url, issue_number, ...} on stdout.
    if push_out="$(python3 "$BRIDGE_DIR/push.py" --critique "$translated" --repo "$repo" --live 2>&1)"; then
      issue_url="$(printf '%s' "$push_out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("issue_url") or "")' 2>/dev/null)"
      issue_num="$(printf '%s' "$push_out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("issue_number") or "")' 2>/dev/null)"
      [ -z "$issue_url" ] && push_err="bridge exited 0 but printed no issue_url: $push_out"
    else
      push_err="$push_out"
    fi
  elif command -v gh >/dev/null 2>&1; then
    if push_out="$(gh issue create --repo "$repo" --title "$title" \
        --label "user-critique" --body-file "$body_file" 2>&1)"; then
      issue_url="$push_out"
      issue_num="$(printf '%s' "$issue_url" | grep -oE '[0-9]+$')"
    else
      push_err="$push_out"
    fi
  else
    push_err="no bridge at $BRIDGE_DIR/push.py and 'gh' not found on PATH"
  fi
  rm -f "$body_file" "$translated"

  if [ -n "$issue_url" ]; then
    RECEIPTS_DIR="$RECEIPTS_DIR" write_receipt "$stem" "pushed" "$issue_url" "$issue_num" "" "$cmd" >/dev/null
    echo "Pushed: $issue_url"
    echo "Receipt: $RECEIPTS_DIR/$stem.receipt.json"
    # Delivered: only now may the draft leave the queue.
    rm -f "$draft"
    return 0
  fi

  # Failure: draft stays in drafts/, receipt records the real error.
  RECEIPTS_DIR="$RECEIPTS_DIR" write_receipt "$stem" "failed" "" "" "${push_err:-push failed with no output}" "$cmd" >/dev/null
  echo "Draft saved at $draft — not yet pushed (${push_err:-push failed}). Run ./flush-now.sh --retry-drafts --live next session to push it."
  return 1
}

# --- main --------------------------------------------------------------------
if [ "$RETRY" -eq 1 ]; then
  shopt -s nullglob
  drafts=("$DRAFTS_DIR"/*.json)
  if [ "${#drafts[@]}" -eq 0 ]; then
    echo "No pending critique drafts."
    exit 0
  fi
  echo "Retrying ${#drafts[@]} pending draft(s) ($([ "$LIVE" -eq 1 ] && echo live || echo dry-run)):"
  rc=0
  for d in "${drafts[@]}"; do
    echo "--- $d"
    flush_one "$d" || rc=1
  done
  exit "$rc"
fi

if [ -z "$DRAFT" ]; then
  echo "flush-now.sh: need --draft <file.json> or --retry-drafts" >&2
  exit 2
fi
if [ ! -f "$DRAFT" ]; then
  echo "flush-now.sh: draft not found: $DRAFT" >&2
  exit 2
fi
flush_one "$DRAFT"
