#!/usr/bin/env bash
# Fetch secrets from Bitwarden vault and push to server via SCP.
# Runs locally (not on the server). Master password never leaves this machine.
#
# Usage: bash scripts/sync-secrets.sh
#   Or: BW_SESSION=... bash scripts/sync-secrets.sh  (skip interactive login)
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/claude-code-agent-key.pem}"
REMOTE_HOST="${DEPLOY_HOST:-ubuntu@54.66.167.208}"
REMOTE_AGENT_DIR="/home/ubuntu/agent"
REMOTE_CLAUDE_DIR="/home/ubuntu/.claude-agent"

# Bitwarden item IDs (from claude-agent-lightsail folder)
BW_ENV_SECRETS_ID="f8630333-d0ef-4ac5-87f3-b3ff002f9c78"
BW_GMAIL_ID="01df4168-e6e8-4859-ac06-b3ff002fa4cf"
BW_FACEBOOK_ID="c7f8b911-64fe-4303-897d-b3ff002fad11"
BW_GOOGLE_SA_ID="b93df202-8224-4347-b1a2-b3ff002fb546"
BW_GOOGLE_CREDS_ID="03419c60-6360-4cfd-94de-b3ff002fbd25"

# Authenticate / unlock Bitwarden (skip if BW_SESSION already set)
if [ -z "${BW_SESSION:-}" ]; then
  if ! bw login --check &>/dev/null; then
    echo "Logging in to Bitwarden..."
    export BW_SESSION=$(bw login --raw)
  else
    echo "Unlocking Bitwarden vault..."
    export BW_SESSION=$(bw unlock --raw)
  fi
fi
bw sync

# Verify vault is actually unlocked by fetching a known item
if ! bw get notes "$BW_ENV_SECRETS_ID" &>/dev/null; then
  echo "ERROR: Cannot read from vault. Is it unlocked?" >&2
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Helper: fetch from vault by ID and SCP to server with chmod 600
push_secret() {
  local item_id="$1" remote_path="$2" label="$3"
  local tmpfile="$TMPDIR/$(basename "$remote_path")"
  local content
  content=$(bw get notes "$item_id")
  if [ -z "$content" ]; then
    echo "  WARN: '$label' is empty in vault, skipping"
    return
  fi
  printf '%s\n' "$content" > "$tmpfile"
  scp -i "$SSH_KEY" "$tmpfile" "$REMOTE_HOST:$remote_path"
  ssh -i "$SSH_KEY" "$REMOTE_HOST" "chmod 600 '$remote_path'"
  echo "  -> $label -> $remote_path"
}

echo "Syncing secrets to $REMOTE_HOST..."

# 1. Env secrets: merge into existing .env on server
echo "  Fetching env-secrets from vault..."
ENV_SECRETS=$(bw get notes "$BW_ENV_SECRETS_ID")
if [ -z "$ENV_SECRETS" ]; then
  echo "  WARN: env-secrets is empty in vault, skipping .env merge"
else
  # Build sed expression to remove existing secret key lines
  SED_EXPR=""
  while IFS='=' read -r key _rest; do
    [ -z "$key" ] && continue
    SED_EXPR="${SED_EXPR}/^${key}=/d;"
  done <<< "$ENV_SECRETS"

  # On server: strip old secret lines from .env
  if [ -n "$SED_EXPR" ]; then
    ssh -i "$SSH_KEY" "$REMOTE_HOST" "sed -i '${SED_EXPR}' $REMOTE_AGENT_DIR/.env"
  fi

  # Append fresh secrets via stdin
  echo "$ENV_SECRETS" | ssh -i "$SSH_KEY" "$REMOTE_HOST" "cat >> $REMOTE_AGENT_DIR/.env && chmod 600 $REMOTE_AGENT_DIR/.env"
  echo "  -> env-secrets -> $REMOTE_AGENT_DIR/.env (merged)"
fi

# 2. JSON credential files: full replacement
push_secret "$BW_GMAIL_ID"       "$REMOTE_AGENT_DIR/gmail_app_password.json"          "gmail"
push_secret "$BW_FACEBOOK_ID"    "$REMOTE_CLAUDE_DIR/facebook-page-token.json"        "facebook"
push_secret "$BW_GOOGLE_SA_ID"   "$REMOTE_CLAUDE_DIR/google-service-account.json"     "google-service-account"
push_secret "$BW_GOOGLE_CREDS_ID" "$REMOTE_CLAUDE_DIR/google-credentials.json"        "google-credentials"

bw lock
echo ""
echo "Done. Vault locked."
