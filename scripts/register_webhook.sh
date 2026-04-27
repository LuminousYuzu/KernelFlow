#!/usr/bin/env bash
# =============================================================================
# KernelFlow — Register GitHub webhook to trigger Jenkins on every push
#
# Run this AFTER Jenkins is up and the pipeline job exists:
#   bash scripts/register_webhook.sh
#
# Requires:
#   - gh CLI authenticated (gh auth login)
#   - jenkins/.env exists (created by scripts/setup.sh)
#   - Jenkins reachable at http://<PC_LAN_IP>:8080
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[webhook]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

ENV_FILE="jenkins/.env"
[[ -f "$ENV_FILE" ]] || error "jenkins/.env not found. Run scripts/setup.sh first."

# Load the .env
set -a; source "$ENV_FILE"; set +a

GITHUB_REPO="LuminousYuzu/KernelFlow"
JENKINS_URL="http://${PC_LAN_IP}:8080"
WEBHOOK_URL="${JENKINS_URL}/github-webhook/"

# ---------------------------------------------------------------------------
# Verify Jenkins is reachable
# ---------------------------------------------------------------------------
info "Checking Jenkins at ${JENKINS_URL} ..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${JENKINS_URL}/login" || echo "000")
[[ "$HTTP_CODE" == "200" ]] || error "Jenkins not reachable (HTTP ${HTTP_CODE}). Is it running?"
info "Jenkins is up."

# ---------------------------------------------------------------------------
# Check if webhook already exists
# ---------------------------------------------------------------------------
info "Checking existing webhooks on ${GITHUB_REPO} ..."
EXISTING=$(gh api "repos/${GITHUB_REPO}/hooks" --jq \
    "[.[] | select(.config.url == \"${WEBHOOK_URL}\")] | length")

if [[ "$EXISTING" -gt 0 ]]; then
    warn "Webhook already registered at ${WEBHOOK_URL} — nothing to do."
    exit 0
fi

# ---------------------------------------------------------------------------
# Generate a webhook secret for payload verification
# (Jenkins GitHub plugin validates this if configured; it's optional but good)
# ---------------------------------------------------------------------------
WEBHOOK_SECRET=$(openssl rand -hex 20)
info "Generated webhook secret (save this — you'll need it once): ${WEBHOOK_SECRET}"

# ---------------------------------------------------------------------------
# Register the webhook via gh CLI
# ---------------------------------------------------------------------------
info "Registering webhook → ${WEBHOOK_URL}"

gh api "repos/${GITHUB_REPO}/hooks" \
    --method POST \
    --field "name=web" \
    --field "active=true" \
    --field "events[]=push" \
    --field "events[]=pull_request" \
    --field "config[url]=${WEBHOOK_URL}" \
    --field "config[content_type]=json" \
    --field "config[secret]=${WEBHOOK_SECRET}" \
    --field "config[insecure_ssl]=0"

# ---------------------------------------------------------------------------
# Store the secret in .env so Jenkins can be configured to verify it
# ---------------------------------------------------------------------------
if ! grep -q "GITHUB_WEBHOOK_SECRET" "$ENV_FILE"; then
    echo "GITHUB_WEBHOOK_SECRET=${WEBHOOK_SECRET}" >> "$ENV_FILE"
    info "Webhook secret appended to jenkins/.env"
fi

# ---------------------------------------------------------------------------
# Trigger an initial scan so Jenkins discovers branches immediately
# ---------------------------------------------------------------------------
info "Triggering initial branch scan on Jenkins..."
curl -s -X POST \
    -u "admin:${JENKINS_ADMIN_PASSWORD}" \
    "${JENKINS_URL}/job/kernelflow/build" \
    || warn "Could not trigger scan (may need to do it manually via Blue Ocean UI)."

echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN} Webhook registered successfully.${NC}"
echo -e " URL:    ${WEBHOOK_URL}"
echo -e " Events: push, pull_request"
echo -e ""
echo -e " Next push to GitHub will trigger a Jenkins build."
echo -e " Monitor progress at: ${JENKINS_URL}/blue/pipelines"
echo -e "${GREEN}================================================${NC}"
