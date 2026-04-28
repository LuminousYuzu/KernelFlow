#!/usr/bin/env bash
# =============================================================================
# KernelFlow — One-shot bootstrap for the GPU PC (Windows WSL2 / Linux)
#
# Run this ONCE from the repo root after cloning onto the GPU PC:
#   bash scripts/setup.sh
#
# What it does:
#   1. Checks prerequisites
#   2. Starts minikube with GPU passthrough
#   3. Installs the NVIDIA Device Plugin into minikube
#   4. Creates a Jenkins service account + RBAC in the cluster
#   5. Builds the KernelFlow build image and loads it into minikube
#   6. Builds the Jenkins controller image
#   7. Copies minikube kube/cert files into jenkins/ (Docker-friendly paths)
#   8. Writes jenkins/.env with all secrets Jenkins needs
#   9. Creates /opt/kernelflow/registry for the wheel registry
#  10. Starts Jenkins via docker compose
#
# After this script finishes, run scripts/register_webhook.sh to wire up GitHub.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Color helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[setup]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

# =============================================================================
# Step 0 — Check prerequisites
# =============================================================================
info "Checking prerequisites..."

for cmd in docker minikube kubectl gh; do
    command -v "$cmd" &>/dev/null || error "Required tool not found: $cmd"
done

docker info &>/dev/null || error "Docker daemon is not running. Start Docker Desktop first."
info "All prerequisites satisfied."

# =============================================================================
# Step 1 — Detect LAN IP of this machine
# =============================================================================
PC_LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -z "$PC_LAN_IP" ]] && PC_LAN_IP=$(ip route get 1 | awk '{print $NF; exit}')
[[ -z "$PC_LAN_IP" ]] && error "Could not auto-detect LAN IP. Set PC_LAN_IP manually."
info "GPU PC LAN IP: ${PC_LAN_IP}"

# =============================================================================
# Step 2 — Start minikube with GPU support
# =============================================================================
info "Starting minikube..."
if minikube status &>/dev/null; then
    warn "minikube is already running — skipping start."
else
    minikube start \
        --driver=docker \
        --gpus=all \
        --cpus=6 \
        --memory=12g \
        --disk-size=40g \
        --kubernetes-version=stable
    info "minikube started."
fi

# Extract API server URL from kubeconfig
MINIKUBE_API_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
info "minikube API URL: ${MINIKUBE_API_URL}"

# =============================================================================
# Step 3 — Install NVIDIA Device Plugin
# =============================================================================
info "Installing NVIDIA Device Plugin..."
kubectl apply -f \
    https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml \
    || warn "Device plugin already installed or no GPU found — continuing."

# =============================================================================
# Step 4 — Create Jenkins service account + RBAC
# =============================================================================
info "Creating Jenkins service account in minikube..."

kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins-agent-role
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/exec", "pods/log", "secrets", "persistentvolumeclaims"]
    verbs: ["create", "delete", "get", "list", "patch", "update", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins-agent-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jenkins-agent-role
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: default
---
apiVersion: v1
kind: Secret
metadata:
  name: jenkins-sa-token
  namespace: default
  annotations:
    kubernetes.io/service-account.name: jenkins
type: kubernetes.io/service-account-token
EOF

# Wait for the token to be populated
info "Waiting for service account token..."
for i in {1..20}; do
    TOKEN=$(kubectl get secret jenkins-sa-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [[ -n "$TOKEN" ]] && break
    sleep 2
done
[[ -z "$TOKEN" ]] && error "Service account token was not populated after 40s."
info "Service account token extracted."

# =============================================================================
# Step 5 — Build KernelFlow CUDA build image and load into minikube
# =============================================================================
info "Building KernelFlow build image (kernelflow-build:latest)..."
docker build -t kernelflow-build:latest .
info "Loading kernelflow-build into minikube..."
minikube image load kernelflow-build:latest
info "Build image loaded."

# =============================================================================
# Step 6 — Build Jenkins controller image
# =============================================================================
info "Building Jenkins controller image (kernelflow-jenkins:latest)..."
docker build -f jenkins/Dockerfile.jenkins -t kernelflow-jenkins:latest .
info "Jenkins image built."

# =============================================================================
# Step 7 — Copy minikube kube/cert files into jenkins/ for Docker volume mount
# =============================================================================
info "Copying minikube credentials into jenkins/kube/ and jenkins/minikube-certs/..."
mkdir -p jenkins/kube jenkins/minikube-certs

# Replace absolute paths in kubeconfig with container-relative paths
kubectl config view --minify --flatten > jenkins/kube/config.raw
sed \
    -e "s|${HOME}/.minikube|/root/.minikube|g" \
    -e "s|$(wslpath -w "${HOME}" 2>/dev/null || echo "${HOME}")|/root|g" \
    jenkins/kube/config.raw > jenkins/kube/config
rm jenkins/kube/config.raw

# Copy minikube TLS certs
MINIKUBE_HOME="${HOME}/.minikube"
cp -r "${MINIKUBE_HOME}/ca.crt"       jenkins/minikube-certs/  2>/dev/null || true
cp -r "${MINIKUBE_HOME}/profiles"     jenkins/minikube-certs/  2>/dev/null || true
cp -r "${MINIKUBE_HOME}/certs"        jenkins/minikube-certs/  2>/dev/null || true
info "Credentials copied."

# =============================================================================
# Step 8 — Prompt for secrets and write .env
# =============================================================================
info "Collecting secrets for jenkins/.env ..."

ENV_FILE="jenkins/.env"

if [[ -f "$ENV_FILE" ]]; then
    warn ".env already exists — skipping secret prompts. Delete it to re-enter."
else
    read -rsp "Jenkins admin password: "    JENKINS_ADMIN_PASSWORD; echo
    read -rsp "GitHub personal access token (repo + admin:repo_hook scopes): " GITHUB_TOKEN; echo
    read -rsp "wandb API key (or press Enter to skip): " WANDB_API_KEY; echo

    cat > "$ENV_FILE" <<EOF
# Auto-generated by scripts/setup.sh — DO NOT COMMIT
PC_LAN_IP=${PC_LAN_IP}
MINIKUBE_API_URL=${MINIKUBE_API_URL}
MINIKUBE_SA_TOKEN=${TOKEN}
JENKINS_ADMIN_PASSWORD=${JENKINS_ADMIN_PASSWORD}
GITHUB_TOKEN=${GITHUB_TOKEN}
WANDB_API_KEY=${WANDB_API_KEY:-}
EOF
    chmod 600 "$ENV_FILE"
    info ".env written to jenkins/.env"
fi

# =============================================================================
# Step 9 — Create local wheel registry directory
# =============================================================================
info "Creating wheel registry at /opt/kernelflow/registry ..."
sudo mkdir -p /opt/kernelflow/registry
sudo chmod 777 /opt/kernelflow/registry

# =============================================================================
# Step 10 — Start Jenkins
# =============================================================================
info "Starting Jenkins..."
docker compose -f jenkins/docker-compose.yml --env-file jenkins/.env up -d

echo ""
echo -e "${GREEN}========================================================${NC}"
echo -e "${GREEN} Jenkins is starting up.${NC}"
echo -e "${GREEN} Web UI:    http://${PC_LAN_IP}:8080${NC}"
echo -e "${GREEN} User:      admin${NC}"
echo -e "${GREEN} Password:  (what you entered above)${NC}"
echo -e ""
echo -e " Wait ~90 seconds for Jenkins to boot, then:"
echo -e "   1. Open http://${PC_LAN_IP}:8080 in your browser"
echo -e "   2. Verify the 'kernelflow' multibranch pipeline appears"
echo -e "   3. Run:  bash scripts/register_webhook.sh"
echo -e "${GREEN}========================================================${NC}"
