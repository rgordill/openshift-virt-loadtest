#!/usr/bin/env bash
# Bootstrap the root app-of-apps Application using kustomize.
# Override REPO_URL and TARGET_REVISION for forks:
#
#   REPO_URL=https://github.com/myorg/openshift-virt-loadtest.git \
#     TARGET_REVISION=my-branch \
#     ./argocd/main/bootstrap-app-of-apps.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/rgordill/openshift-virt-loadtest.git}"
TARGET_REVISION="${TARGET_REVISION:-HEAD}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUSTOMIZE_DIR="${SCRIPT_DIR}/app-of-apps"

echo "============================================"
echo " Bootstrap App-of-Apps"
echo "============================================"
echo "REPO_URL: ${REPO_URL}"
echo "TARGET_REVISION: ${TARGET_REVISION}"
echo ""

# Update kustomize configMapGenerator literals with the overrides
cd "$KUSTOMIZE_DIR"

# Use kustomize edit to update the configmap literals
kustomize edit remove configmap bootstrap-params 2>/dev/null || true
kustomize edit add configmap bootstrap-params \
  --disableNameSuffixHash \
  --from-literal="REPO_URL=${REPO_URL}" \
  --from-literal="TARGET_REVISION=${TARGET_REVISION}"

echo "Applying app-of-apps..."
kubectl apply -k "$KUSTOMIZE_DIR"

echo ""
echo "App-of-apps applied. Waiting for sync..."
echo "Check with: kubectl get application openshift-virt-loadtest-app -n openshift-gitops"
