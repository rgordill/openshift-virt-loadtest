#!/usr/bin/env bash
# Enable aggregated cluster roles on the ArgoCD instance and apply the
# operator-permissions ClusterRole so the Application Controller can manage
# all CRDs this repo deploys.
#
# Usage:
#   ./argocd/main/apply-prerequisites.sh

set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"
ARGOCD_NAME="${ARGOCD_NAME:-openshift-gitops}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTERROLE_FILE="${SCRIPT_DIR}/argocd-application-controller-operator-permissions-clusterrole.yaml"

if [[ ! -f "$CLUSTERROLE_FILE" ]]; then
  echo "Error: ClusterRole manifest not found: $CLUSTERROLE_FILE" >&2
  exit 1
fi

echo "Argo CD instance: namespace=$ARGOCD_NAMESPACE, name=$ARGOCD_NAME"
echo ""

echo "Enabling aggregated cluster roles on ArgoCD/$ARGOCD_NAME..."
kubectl patch argocd -n "$ARGOCD_NAMESPACE" "$ARGOCD_NAME" \
  --type=merge \
  -p '{"spec":{"aggregatedClusterRoles":true}}'
echo "Done."
echo ""

if [[ "$ARGOCD_NAMESPACE" == "openshift-gitops" && "$ARGOCD_NAME" == "openshift-gitops" ]]; then
  kubectl apply -f "$CLUSTERROLE_FILE"
else
  echo "Applying ClusterRole with labels for $ARGOCD_NAMESPACE/$ARGOCD_NAME..."
  sed -e "s/app.kubernetes.io\/managed-by: openshift-gitops/app.kubernetes.io\/managed-by: $ARGOCD_NAMESPACE/" \
      -e "s/app.kubernetes.io\/name: openshift-gitops/app.kubernetes.io\/name: $ARGOCD_NAME/" \
      "$CLUSTERROLE_FILE" | kubectl apply -f -
fi

echo ""
echo "Prerequisites applied. You can now create the app-of-apps Application."
