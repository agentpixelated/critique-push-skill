#!/usr/bin/env bash
# critique-push — dedicated-computer adapter: capture + flush
#   capture.sh --repo owner/repo --title T --summary S [--expected E] [--actual A]
#              [--impact I] [--category C] [--steps S] [--tool-version V]
#              [--labels a,b] [--from-json file]
#   capture.sh --flush [--dry-run]   — push everything queued, oldest first
#   capture.sh --dry-run ...         — print the issue body, file nothing
# Stdlib only (bash + python3). No network call except the push itself.
# Never writes a token to disk; auth is gh CLI or CRITIQUE_PUSH_TOKEN env.
#
# Record shape: every queue file IS a critique-schema.json record
# (the single contract — see critique-schema.json), plus the bridge's
# compat fields (tool/body/date/user_words/evidence) and the queue
# lifecycle fields (agent_id/labels/created_at/attempts/next_retry_at).
# Nothing outside the schema is ever written. Validation is full
# jsonschema validation when the `jsonschema` module is installed,
# else a stdlib check of the same required fields.
# The only GitHub call is the shared bridge:
#   python3 bridge/push.py --critique <json> --repo <owner/repo> [--labels a,b] [--live]
# (dry-run by default; --live to really file). The `gh issue create`
# fallback below runs only if the bridge file is absent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASE="${CRITIQUE_PUSH_HOME:-$HOME/.critique-push}"
QUEUE_DIR="$BASE/queue"
RECEIPTS_LOG="$BASE/receipts/receipts.log"
CONFIG="$BASE/config"

# --- config (defaults; never contains secrets) ---
AGENT_ID="$(hostname -s)"
TOOL="unknown"
DEFAULT_REPO=""
BRIDGE="$SKILL_ROOT/bridge/push.py"
[[ -f "$CONFIG" ]] && source "$CONFIG"
AGENT_ID="${CRITIQUE_PUSH_AGENT_ID:-$AGENT_ID}"
TOOL="${CRITIQUE_PUSH_TOOL:-$TOOL}"
DEFAULT_REPO="${CRITIQUE_PUSH_DEFAULT_REPO:-$DEFAULT_REPO}"
BRIDGE="${CRITIQUE_PUSH_BRIDGE:-$BRIDGE}"

DRY_RUN=0
MODE="capture"
REPO="$DEFAULT_REPO"; TITLE=""; SUMMARY=""; EXPECTED=""; ACTUAL=""; IMPACT=""
CATEGORY="other"; STEPS=""; TOOL_VERSION=""; LABELS=""
FROM_JSON=""

usage() {
  sed -n '2,9p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --expected) EXPECTED="$2"; shift 2 ;;
    --actual) ACTUAL="$2"; shift 2 ;;
    --impact) IMPACT="$2"; shift 2 ;;
    --category) CATEGORY="$2"; shift 2 ;;
    --steps) STEPS="$2"; shift 2 ;;
    --tool-version) TOOL_VERSION="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    --from-json) FROM_JSON="$2"; shift 2 ;;
    --flush) MODE="flush"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_wib() { TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M WIB'; }

# Validate a critique JSON file against critique-schema.json.
# Full jsonschema validation when the module is installed; otherwise a
# stdlib check of the schema's required fields + the bridge contract
# (tool/body/date). Either way a bad record is rejected before queuing.
validate_json() {
  local file="$1" schema="$SKILL_ROOT/critique-schema.json"
  python3 - "$file" "$schema" <<'PYEOF'
import json, re, sys
path, schema_path = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
    schema = json.load(open(schema_path))
except Exception as e:
    print(f"invalid JSON: {e}", file=sys.stderr); sys.exit(2)
try:
    import jsonschema
    jsonschema.validate(data, schema)
except ImportError:
    # stdlib fallback: same required fields + bridge contract
    missing = [f for f in schema.get("required", [])
               if not data.get(f) and data.get(f) != 0]
    missing += [f for f in ("tool", "body", "date")
                if not isinstance(data.get(f), str) or not data[f].strip()]
    if missing:
        print(f"missing required field(s): {', '.join(sorted(set(missing)))}",
              file=sys.stderr); sys.exit(2)
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", data["date"]):
        print(f"field 'date' must be YYYY-MM-DD, got: {data['date']!r}",
              file=sys.stderr); sys.exit(2)
PYEOF
}

# Render the GitHub issue body from a critique JSON file, exactly as the
# bridge would file it: run push.py --dry-run and print its stderr
# (the rendered title/body + dedup preview). Exit code is push.py's.
render_body() {
  python3 "$BRIDGE" --critique "$1" \
    --repo "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['target_repo'])" "$1")" \
    --dry-run
}

# Push one critique file via the shared bridge. Prints the issue URL on
# stdout on success (parsed from the bridge's receipt JSON).
# INTERFACE (the only GitHub logic): the bridge is the only GitHub logic.
#   python3 "$BRIDGE" --critique <file> --repo <owner/repo> [--labels a,b] --live
# If the bridge file is absent, fall back to `gh issue create` (same
# receipt rules). Do not add GitHub API logic here.
push_one() {
  local file="$1"
  local repo title labels
  repo=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['target_repo'])" "$file")
  title=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['title'])" "$file")
  labels=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('labels',''))" "$file")
  if [[ -f "$BRIDGE" ]]; then
    local args=(--critique "$file" --repo "$repo" --live)
    [[ -n "$labels" ]] && args+=(--labels "$labels")
    local out
    if ! out=$(python3 "$BRIDGE" "${args[@]}" 2>"$BASE/log/flush.err"); then
      cat "$BASE/log/flush.err" >&2
      return 1
    fi
    python3 -c "import json,sys; print(json.load(sys.stdin)['issue_url'])" <<<"$out"
  else
    # Bridge absent — `gh` fallback. Body rendered from the shared template
    # by push.py's render path is unavailable, so render the template here
    # with the same {single-brace} substitution (kept in sync with
    # bridge/push.py render()).
    local body; body="$(mktemp)"
    python3 - "$file" "$SKILL_ROOT/templates/critique-template.md" "$body" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
tmpl = open(sys.argv[2]).read()
steps = d.get("repro_steps") or []
repro = "\n".join(f"{i+1}. {s}" for i, s in enumerate(steps)) or \
    "_Not observed — no repro steps were run or described._"
tool_line = d["tool_name"] + (f" {d['tool_version']}" if d.get("tool_version") else "")
mapping = {"what_happened": d["what_happened"], "expected": d["expected"],
           "actual": d["actual"], "impact": d["impact"], "repro_steps": repro,
           "tool_line": tool_line,
           "environment_os": d["environment"]["os"],
           "environment_runtime": str(d["environment"].get("runtime") or "unknown"),
           "date_wib": d["date_wib"],
           "evidence": d.get("evidence") or "None recorded by the agent.",
           "id": d.get("id", ""), "category": d["category"]}
for k, v in mapping.items():
    tmpl = tmpl.replace("{" + k + "}", str(v))
open(sys.argv[3], "w").write(tmpl)
PYEOF
    local args=(issue create --repo "$repo" --title "$title" --body-file "$body")
    [[ -n "$labels" ]] && args+=(--label "$labels")
    local url
    if [[ -n "${CRITIQUE_PUSH_TOKEN:-}" ]]; then
      url=$(GH_TOKEN="$CRITIQUE_PUSH_TOKEN" gh "${args[@]}" 2>"$BASE/log/flush.err") || { rm -f "$body"; return 1; }
    else
      url=$(gh "${args[@]}" 2>"$BASE/log/flush.err") || { rm -f "$body"; return 1; }
    fi
    rm -f "$body"
    echo "$url"
  fi
}

# Record a receipt into the queue file + receipts log, print one line.
# The receipt lives in the schema's `receipt` object (issue_url,
# issue_number, pushed_at_wib) — no top-level issue_* fields.
record_receipt() {
  local file="$1" url="$2"
  local number pushed_at
  number="$(basename "$url" | grep -oE '[0-9]+$' || true)"
  pushed_at="$(now_wib)"
  python3 - "$file" "$url" "$number" "$pushed_at" <<'PYEOF'
import json, sys
path, url, number, pushed_at = sys.argv[1:5]
d = json.load(open(path))
d["status"] = "pushed"
d["receipt"] = {"issue_url": url,
                "issue_number": int(number) if number.isdigit() else None,
                "pushed_at_wib": pushed_at}
d["next_retry_at"] = None
json.dump(d, open(path, "w"), indent=2)
PYEOF
  mkdir -p "$(dirname "$RECEIPTS_LOG")"
  local id repo
  id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$file")
  repo=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['target_repo'])" "$file")
  echo "$pushed_at $id $repo#$number $url" >> "$RECEIPTS_LOG"
  echo "Filed: $url"
}

# Mark a failed attempt: attempts+1, backoff, status failed-held after 3.
# Backoff minutes: 5, 30, 120. Never deletes the file.
mark_failed() {
  local file="$1" reason="$2"
  python3 - "$file" <<'PYEOF'
import json, sys
from datetime import datetime, timedelta, timezone
path = sys.argv[1]
d = json.load(open(path))
d["attempts"] = d.get("attempts", 0) + 1
backoff = [5, 30, 120][min(d["attempts"] - 1, 2)]
if d["attempts"] >= 3:
    d["status"] = "failed-held"
    d["next_retry_at"] = None
else:
    d["status"] = "queued"
    d["next_retry_at"] = (datetime.now(timezone.utc) + timedelta(minutes=backoff)).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump(d, open(path, "w"), indent=2)
print(d["attempts"], d["status"])
PYEOF
  local id
  id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$file")
  echo "Held: $id ($reason) — will retry, nothing dropped." >&2
}

# ---------------- flush ----------------
if [[ "$MODE" == "flush" ]]; then
  mkdir -p "$QUEUE_DIR" "$BASE/log"
  shopt -s nullglob
  # Oldest created_at first; skip already-pushed files.
  mapfile -t files < <(python3 - "$QUEUE_DIR" <<'PYEOF'
import glob, json, sys
rows = []
for f in glob.glob(sys.argv[1] + "/*.json"):
    try:
        d = json.load(open(f))
        if d.get("status") != "pushed":
            rows.append((d.get("created_at", ""), f))
    except Exception:
        pass
for _, f in sorted(rows):
    print(f)
PYEOF
)
  if [[ ${#files[@]} -eq 0 ]]; then echo "queue empty — nothing to flush."; exit 0; fi
  if [[ $DRY_RUN -eq 1 ]]; then
    for f in "${files[@]}"; do
      echo "=== would file: $f ==="
      render_body "$f"
      echo
    done
    echo "${#files[@]} critique(s) would be filed. Nothing was pushed."
    exit 0
  fi
  # Auth pre-check: fail loudly before touching anything.
  if ! { command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; } \
     && [[ -z "${CRITIQUE_PUSH_TOKEN:-}" ]] && [[ ! -f "$BRIDGE" ]]; then
    echo "no auth: run 'gh auth login' or export CRITIQUE_PUSH_TOKEN — ${#files[@]} critique(s) stay queued." >&2
    exit 1
  fi
  for f in "${files[@]}"; do
    if url=$(push_one "$f" 2>"$BASE/log/flush.err"); then
      record_receipt "$f" "$url"
    else
      reason="$(tail -n 1 "$BASE/log/flush.err" 2>/dev/null || echo "push failed")"
      mark_failed "$f" "$reason"
    fi
  done
  exit 0
fi

# ---------------- capture ----------------
if [[ -n "$FROM_JSON" ]]; then
  [[ -f "$FROM_JSON" ]] || { echo "no such file: $FROM_JSON" >&2; exit 1; }
  tmp="$FROM_JSON"
else
  [[ -n "$REPO" ]] || { echo "missing --repo (or set CRITIQUE_PUSH_DEFAULT_REPO)" >&2; exit 1; }
  [[ -n "$TITLE" ]] || { echo "missing --title" >&2; exit 1; }
  [[ -n "$SUMMARY" ]] || { echo "missing --summary" >&2; exit 1; }
  [[ -n "$EXPECTED" ]] || { echo "missing --expected" >&2; exit 1; }
  # --actual defaults to the summary (what happened); --impact defaults to
  # an explicit "not recorded" marker — never a guessed impact.
  ACTUAL="${ACTUAL:-$SUMMARY}"
  IMPACT="${IMPACT:-(not recorded — user did not state an impact)}"
  # Title carries SPEC's [<category>] prefix; add it if the caller did not.
  case "$TITLE" in "["*) ;; *) TITLE="[$CATEGORY] $TITLE" ;; esac
  case "$CATEGORY" in bug|ux-friction|wrong-output|missing-feature|confusing-copy|other) ;;
    *) echo "invalid --category: $CATEGORY" >&2; exit 1 ;; esac
  id="cp-$(date -u +%Y%m%dT%H%M%S)-$(od -An -tx1 -N2 /dev/urandom | tr -d ' \n')"
  tmp="$(mktemp)"
  DATE_WIB="$(now_wib)"
  python3 - "$tmp" "$id" "$REPO" "$TITLE" "$SUMMARY" "$EXPECTED" "$ACTUAL" \
    "$IMPACT" "$CATEGORY" "$STEPS" "$TOOL" "$TOOL_VERSION" "$AGENT_ID" \
    "$LABELS" "$(now_utc)" "$DATE_WIB" <<'PYEOF'
import json, re, sys
(_, path, cid, repo, title, summary, expected, actual, impact, category,
 steps, tool, tver, agent, labels, created, date_wib) = sys.argv
slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:60]
# One step per line; strip any numbering/bullets the caller already added
# ("1. ", "2) ", "- ") — render() numbers the list itself.
raw_steps = [re.sub(r"^\s*(\d+[.)]|[-*])\s*", "", s)
             for s in steps.splitlines() if s.strip()]
d = {
  "schema_version": "0.1.0",
  "id": cid,
  "tool_name": tool,
  "tool": tool,
  "tool_version": tver or None,
  "tool_commit": None,
  "category": category,
  "title": title,
  "what_happened": summary,
  "body": summary,
  "user_words": summary,
  "expected": expected,
  "actual": actual,
  "impact": impact,
  "environment": {"os": __import__("platform").system() or "unknown",
                  "runtime": "dedicated-box", "model": None, "notes": None},
  "repro_steps": raw_steps,
  "date_wib": date_wib,
  "date": date_wib[:10],
  "target_repo": repo,
  "dedup_key": tool + "+" + slug,
  "status": "queued",
  "severity": None,
  "evidence": "None recorded by the agent.",
  "receipt": None,
  "agent_id": agent,
  "labels": labels,
  "created_at": created,
  "attempts": 0,
  "next_retry_at": None,
}
json.dump(d, open(path, "w"), indent=2)
PYEOF
fi

if ! validate_json "$tmp"; then
  [[ -z "$FROM_JSON" ]] && rm -f "$tmp"
  echo "critique rejected — nothing queued." >&2
  exit 2
fi

if [[ $DRY_RUN -eq 1 ]]; then
  render_body "$tmp"
  [[ -z "$FROM_JSON" ]] && rm -f "$tmp"
  echo "--- dry-run: nothing queued, nothing filed."
  exit 0
fi

mkdir -p "$QUEUE_DIR"
id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['id'])" "$tmp")
dest="$QUEUE_DIR/$id.json"
cp "$tmp" "$dest"
[[ -z "$FROM_JSON" ]] && rm -f "$tmp"
echo "Queued: $dest"
echo "Flush with: bash $SCRIPT_DIR/capture.sh --flush"
