#!/usr/bin/env bash
# critique-push — dedicated-computer adapter: install
# One-command, idempotent setup. Creates ~/.critique-push/ (queue + config),
# detects gh CLI vs env-token auth. Never writes a token to disk.
set -euo pipefail

BASE="${CRITIQUE_PUSH_HOME:-$HOME/.critique-push}"
CONFIG="$BASE/config"

mkdir -p "$BASE/queue" "$BASE/receipts" "$BASE/log"

if [[ ! -f "$CONFIG" ]]; then
  cat > "$CONFIG" <<EOF
# critique-push config — sourced by capture.sh. No secrets in this file.
# Token auth comes from the environment (CRITIQUE_PUSH_TOKEN) or gh CLI only.
CRITIQUE_PUSH_AGENT_ID="${CRITIQUE_PUSH_AGENT_ID:-$(hostname -s)}"
CRITIQUE_PUSH_TOOL="${CRITIQUE_PUSH_TOOL:-unknown}"
CRITIQUE_PUSH_DEFAULT_REPO="${CRITIQUE_PUSH_DEFAULT_REPO:-}"
CRITIQUE_PUSH_BRIDGE="$HOME/workspace/critique-push-skill/bridge/push.py"
EOF
  echo "created: $CONFIG"
else
  echo "kept existing config: $CONFIG"
fi

# Auth detection — records only WHICH method is available, never the secret.
AUTH_METHOD="none"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  AUTH_METHOD="gh"
elif [[ -n "${CRITIQUE_PUSH_TOKEN:-}" ]]; then
  AUTH_METHOD="env-token"
fi

# Remember the method (not the token) for capture.sh to report.
if grep -q '^CRITIQUE_PUSH_AUTH_METHOD=' "$CONFIG" 2>/dev/null; then
  sed -i "s/^CRITIQUE_PUSH_AUTH_METHOD=.*/CRITIQUE_PUSH_AUTH_METHOD=\"$AUTH_METHOD\"/" "$CONFIG"
else
  echo "CRITIQUE_PUSH_AUTH_METHOD=\"$AUTH_METHOD\"" >> "$CONFIG"
fi

echo "auth method: $AUTH_METHOD"
if [[ "$AUTH_METHOD" == "none" ]]; then
  echo "no auth found: run 'gh auth login', or export CRITIQUE_PUSH_TOKEN from your secret store."
  echo "install still succeeded — critiques will queue and flush will fail loudly until auth exists."
fi
echo "queue: $BASE/queue"
echo "critique-push dedicated adapter installed."
