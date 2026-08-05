#!/usr/bin/env bash
# Install OpenShift GitOps operator and pin Argo CD pods to infra nodes.
# Requires: oc/kubectl, KUBECONFIG
# Run AFTER setup/infra/install.sh has completed successfully.
# Idempotent: safe to re-run. Infra placement is applied BEFORE waiting for Available
# (required when worker MachineSets were removed and only tainted infra nodes remain).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "============================================"
echo " OpenShift GitOps Installation"
echo "============================================"

# --- Pre-flight: verify infra nodes exist ---
INFRA_COUNT=$(oc get nodes -l node-role.kubernetes.io/infra --no-headers 2>/dev/null | grep -c " Ready" || true)
if [[ "$INFRA_COUNT" -eq 0 ]]; then
  echo "ERROR: No Ready infra nodes found. Run setup/infra/install.sh first."
  exit 1
fi
echo "Found ${INFRA_COUNT} Ready infra node(s)."

# --- Pre-flight: verify redhat-operators CatalogSource ---
echo "Checking redhat-operators CatalogSource..."
CS_STATE=$(oc get catalogsource redhat-operators -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "missing")
if [[ "$CS_STATE" != "READY" ]]; then
  echo "WARNING: redhat-operators CatalogSource state is '${CS_STATE}', proceeding anyway..."
fi

# --- Apply manifests (Subscription already includes infra nodeSelector/tolerations) ---
echo ""
echo "Applying GitOps operator manifests..."
oc apply -f "$SCRIPT_DIR/namespace.yaml"
oc apply -f "$SCRIPT_DIR/operatorgroup.yaml"
oc apply -f "$SCRIPT_DIR/subscription.yaml"

# --- Wait for CSV ---
echo ""
echo "Waiting for GitOps operator CSV to succeed..."
TIMEOUT=300
INTERVAL=10
ELAPSED=0

while true; do
  CSV=$(oc get csv -n openshift-gitops-operator --no-headers 2>/dev/null | grep -i gitops | head -1 || true)
  CSV_NAME=$(echo "$CSV" | awk '{print $1}')
  CSV_PHASE=$(echo "$CSV" | awk '{print $NF}')

  if [[ -n "$CSV_NAME" ]]; then
    echo "  CSV: ${CSV_NAME} — Phase: ${CSV_PHASE} (elapsed: ${ELAPSED}s)"
    if [[ "$CSV_PHASE" == "Succeeded" ]]; then
      echo "GitOps operator CSV succeeded."
      break
    fi
  else
    echo "  CSV not yet created (elapsed: ${ELAPSED}s)"
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timed out waiting for GitOps CSV after ${TIMEOUT}s."
    oc get csv -n openshift-gitops-operator 2>/dev/null || true
    oc get pods -n openshift-gitops-operator -o wide 2>/dev/null || true
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# --- Pin Argo CD to infra AS SOON as GitopsService exists (before Available wait) ---
echo ""
echo "Waiting for GitopsService/cluster CR..."
ELAPSED=0
while true; do
  if oc get gitopsservice cluster &>/dev/null; then
    echo "GitopsService/cluster found."
    break
  fi
  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timed out waiting for GitopsService/cluster after ${TIMEOUT}s."
    exit 1
  fi
  echo "  GitopsService not yet created (elapsed: ${ELAPSED}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo "Configuring GitopsService runOnInfra + tolerations (before Argo CD Available)..."
oc patch gitopsservice cluster --type=merge -p '{
  "spec": {
    "runOnInfra": true,
    "tolerations": [
      {
        "effect": "NoSchedule",
        "key": "node-role.kubernetes.io/infra",
        "value": "reserved"
      }
    ]
  }
}'

# Ensure Subscription config still pins the operator (idempotent with applied YAML)
echo "Ensuring GitOps operator Subscription pins to infra..."
oc patch subscription openshift-gitops-operator -n openshift-gitops-operator --type=merge -p '{
  "spec": {
    "config": {
      "nodeSelector": {
        "node-role.kubernetes.io/infra": ""
      },
      "tolerations": [
        {
          "effect": "NoSchedule",
          "key": "node-role.kubernetes.io/infra",
          "value": "reserved"
        }
      ]
    }
  }
}'

# Deployments roll when the operator updates their pod template. The application
# controller is a StatefulSet: pods created before runOnInfra/tolerations land
# keep the old revision and stay Pending (untolerated infra taint) until deleted.
echo ""
echo "Waiting for application-controller StatefulSet template to include infra placement..."
ELAPSED=0
STS_WAIT=180
while true; do
  if ! oc get sts openshift-gitops-application-controller -n openshift-gitops &>/dev/null; then
    echo "  StatefulSet not yet created (elapsed: ${ELAPSED}s)"
  else
    STS_NS=$(oc get sts openshift-gitops-application-controller -n openshift-gitops \
      -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || true)
    STS_TOL=$(oc get sts openshift-gitops-application-controller -n openshift-gitops \
      -o jsonpath='{range .spec.template.spec.tolerations[*]}{.key}={.value}:{.effect}{"\n"}{end}' 2>/dev/null || true)
    if [[ "$STS_NS" == *"node-role.kubernetes.io/infra"* ]] \
      && grep -qx 'node-role.kubernetes.io/infra=reserved:NoSchedule' <<<"$STS_TOL"; then
      echo "StatefulSet template has infra nodeSelector + toleration."
      break
    fi
    echo "  StatefulSet template not yet updated (elapsed: ${ELAPSED}s)"
  fi
  if [[ "$ELAPSED" -ge "$STS_WAIT" ]]; then
    echo "WARNING: Timed out waiting for StatefulSet infra template; will still force-recreate pods."
    break
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

if oc get sts openshift-gitops-application-controller -n openshift-gitops &>/dev/null; then
  echo "Deleting application-controller pods so StatefulSet recreates them with infra placement..."
  oc delete pods -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-application-controller --wait=false
fi

# --- Wait for openshift-gitops namespace and ArgoCD instance ---
echo ""
echo "Waiting for Argo CD instance to become Available on infra..."
ELAPSED=0
ARGO_TIMEOUT=600

while true; do
  ARGOCD_READY=$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.status.phase}' 2>/dev/null || echo "pending")
  PENDING=$(oc get pods -n openshift-gitops --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" {c++} END {print c+0}')
  echo "  ArgoCD status: ${ARGOCD_READY}; non-Running pods: ${PENDING} (elapsed: ${ELAPSED}s)"

  if [[ "$ARGOCD_READY" == "Available" ]]; then
    echo "ArgoCD instance is Available."
    break
  fi

  if [[ "$ELAPSED" -ge "$ARGO_TIMEOUT" ]]; then
    echo "ERROR: Timed out waiting for ArgoCD instance after ${ARGO_TIMEOUT}s."
    oc get argocd openshift-gitops -n openshift-gitops -o yaml 2>/dev/null | tail -40 || true
    oc get pods -n openshift-gitops -o wide 2>/dev/null || true
    oc get pods -n openshift-gitops-operator -o wide 2>/dev/null || true
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# --- Verify GitOps pods on infra nodes ---
echo ""
echo "Verifying GitOps pod placement on infra..."
INFRA_NODES=$(oc get nodes -l node-role.kubernetes.io/infra --no-headers -o custom-columns=NAME:.metadata.name | tr '\n' '|' | sed 's/|$//')
VERIFY_TIMEOUT=300
ELAPSED=0
ERRORS=1

while [[ "$ERRORS" -gt 0 ]]; do
  ERRORS=0
  for ns in openshift-gitops openshift-gitops-operator; do
    echo "=== ${ns} ==="
    PODS=$(oc get pods -n "$ns" -o json | python3 -c "
import json,sys,re
data = json.load(sys.stdin)
infra_re = re.compile(r'^(' + sys.argv[1] + r')$')
errors = 0
for pod in data.get('items', []):
    phase = pod.get('status', {}).get('phase', '')
    if phase in ('Succeeded', 'Failed'):
        continue
    name = pod['metadata']['name']
    node = pod.get('spec', {}).get('nodeName', '')
    if phase != 'Running' or not infra_re.match(node or ''):
        print(f'  WAIT: {name} phase={phase} node={node or \"<none>\"}')
        errors += 1
    else:
        print(f'  OK: {name} -> {node}')
print(errors, file=sys.stderr)
" "$INFRA_NODES" 2>"${TMPDIR:-/tmp}/ovl-gitops-err.$$") || true
    echo "$PODS"
    NS_ERR=$(cat "${TMPDIR:-/tmp}/ovl-gitops-err.$$" 2>/dev/null || echo 0)
    rm -f "${TMPDIR:-/tmp}/ovl-gitops-err.$$"
    ERRORS=$((ERRORS + NS_ERR))
  done

  if [[ "$ERRORS" -eq 0 ]]; then
    break
  fi
  if [[ "$ELAPSED" -ge "$VERIFY_TIMEOUT" ]]; then
    echo "ERROR: GitOps pods not all Running on infra after ${VERIFY_TIMEOUT}s."
    exit 1
  fi
  echo "  ${ERRORS} pod(s) not ready on infra; retrying... (elapsed: ${ELAPSED}s)"
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# --- Show route ---
echo ""
echo "============================================"
echo " GitOps Installation Complete"
echo "============================================"
ROUTE=$(oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}' 2>/dev/null || echo "route not found")
echo "ArgoCD URL: https://${ROUTE}"
echo ""
echo "Admin password:"
echo "  oc extract secret/openshift-gitops-cluster -n openshift-gitops --to=- --keys=admin.password 2>/dev/null"
