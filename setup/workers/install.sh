#!/usr/bin/env bash
# Create regular (untainted) worker MachineSets for kube-burner / KubeVirt load tests.
# Requires: oc, az, python3, KUBECONFIG
# Run AFTER setup/infra/install.sh (installer workers are removed there).
# Override defaults with env vars: WORKER_VM_SIZE, WORKER_REPLICAS, WORKER_ZONES
#
# MachineSets are labeled app.kubernetes.io/part-of=openshift-virt-loadtest so
# setup/infra/install.sh will not delete them on re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_SCRIPT_DIR="$(cd "$SCRIPT_DIR/../infra" && pwd)"

set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/params.env"
set +a

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/azure-auth.sh"

echo "============================================"
echo " Worker Node Setup (kube-burner / virt)"
echo "============================================"
echo "WORKER_VM_SIZE: ${WORKER_VM_SIZE}"
echo "WORKER_REPLICAS: ${WORKER_REPLICAS}"
echo ""

ensure_azure_auth
echo ""

# --- Nested virtualization MachineConfig (worker MCP) ---
echo "Applying nested virtualization MachineConfig for worker role..."
oc apply -f "$SCRIPT_DIR/machineconfig-nested-virt.yaml"
echo ""

# --- Discover cluster info ---
echo "Discovering cluster info..."
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
echo "Infrastructure ID: ${INFRA_ID}"

REF_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=NAME:.metadata.name \
  | grep -E 'infra|storage|worker' | head -1 || true)
if [[ -z "$REF_MS" ]]; then
  echo "ERROR: No MachineSet found to use as providerSpec reference."
  exit 1
fi
echo "Reference MachineSet: ${REF_MS}"

REGION=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.location}')
echo "Region: ${REGION}"

ZONES=$(oc get machineset -n openshift-machine-api -o json | python3 -c "
import json,sys
ms_list = json.load(sys.stdin)
zones = set()
for ms in ms_list['items']:
    zone = ms['spec']['template']['spec']['providerSpec']['value'].get('zone','')
    if zone:
        zones.add(zone)
print(' '.join(sorted(zones)))
")
ZONES="${WORKER_ZONES:-$ZONES}"
if [[ -z "$ZONES" ]]; then
  echo "ERROR: Could not discover zones. Set WORKER_ZONES (e.g. \"1 2 3\")."
  exit 1
fi
echo "Target zones: ${ZONES}"

# --- VM SKU check ---
export REGION ZONES
export INFRA_VM_SIZE="$WORKER_VM_SIZE"
bash "$INFRA_SCRIPT_DIR/check-sku.sh"
echo ""

# --- Extract providerSpec ---
echo "Extracting providerSpec from ${REF_MS}..."
PROVIDER_SPEC=$(oc get machineset "$REF_MS" -n openshift-machine-api -o json | python3 -c "
import json,sys
ms = json.load(sys.stdin)
ps = ms['spec']['template']['spec']['providerSpec']['value']
print(json.dumps(ps, indent=2))
")

# --- Create worker MachineSets per zone ---
for ZONE in $ZONES; do
  MS_NAME="${INFRA_ID}-worker-${REGION}${ZONE}"
  echo ""
  echo "Ensuring worker MachineSet: ${MS_NAME} (zone ${ZONE})..."

  if oc get machineset "$MS_NAME" -n openshift-machine-api &>/dev/null; then
    echo "  MachineSet ${MS_NAME} already exists, ensuring replicas=${WORKER_REPLICAS} and vmSize=${WORKER_VM_SIZE}..."
    oc scale machineset "$MS_NAME" -n openshift-machine-api --replicas="${WORKER_REPLICAS}"
    oc patch machineset "$MS_NAME" -n openshift-machine-api --type=json -p "[
      {\"op\":\"replace\",\"path\":\"/spec/template/spec/providerSpec/value/vmSize\",\"value\":\"${WORKER_VM_SIZE}\"}
    ]"
    oc label machineset "$MS_NAME" -n openshift-machine-api \
      app.kubernetes.io/part-of=openshift-virt-loadtest --overwrite
    continue
  fi

  echo "$PROVIDER_SPEC" | python3 -c "
import json,sys

ps = json.load(sys.stdin)
ps['vmSize'] = '${WORKER_VM_SIZE}'
ps['zone'] = '${ZONE}'

ms = {
    'apiVersion': 'machine.openshift.io/v1beta1',
    'kind': 'MachineSet',
    'metadata': {
        'name': '${MS_NAME}',
        'namespace': 'openshift-machine-api',
        'labels': {
            'machine.openshift.io/cluster-api-cluster': '${INFRA_ID}',
            'machine.openshift.io/cluster-api-machine-role': 'worker',
            'machine.openshift.io/cluster-api-machine-type': 'worker',
            'app.kubernetes.io/part-of': 'openshift-virt-loadtest',
        }
    },
    'spec': {
        'replicas': ${WORKER_REPLICAS},
        'selector': {
            'matchLabels': {
                'machine.openshift.io/cluster-api-cluster': '${INFRA_ID}',
                'machine.openshift.io/cluster-api-machineset': '${MS_NAME}',
            }
        },
        'template': {
            'metadata': {
                'labels': {
                    'machine.openshift.io/cluster-api-cluster': '${INFRA_ID}',
                    'machine.openshift.io/cluster-api-machine-role': 'worker',
                    'machine.openshift.io/cluster-api-machine-type': 'worker',
                    'machine.openshift.io/cluster-api-machineset': '${MS_NAME}',
                }
            },
            'spec': {
                'metadata': {
                    'labels': {
                        'node-role.kubernetes.io/worker': '',
                    }
                },
                'providerSpec': {
                    'value': ps
                }
            }
        }
    }
}

print(json.dumps(ms, indent=2))
" | oc apply -f -
done

# --- Wait for worker nodes to be Ready ---
echo ""
echo "Waiting for worker nodes to become Ready..."
TIMEOUT=600
INTERVAL=15
ELAPSED=0
ZONE_COUNT=$(echo "$ZONES" | wc -w | tr -d ' ')
EXPECTED=$((ZONE_COUNT * WORKER_REPLICAS))

while true; do
  READY_COUNT=$(oc get machines -n openshift-machine-api -o json | python3 -c "
import json,sys
data = json.load(sys.stdin)
ready = 0
for m in data.get('items', []):
    labels = m.get('metadata', {}).get('labels') or {}
    if labels.get('machine.openshift.io/cluster-api-machine-role') != 'worker':
        continue
    # Only count machines from our managed worker MachineSets
    ms = labels.get('machine.openshift.io/cluster-api-machineset', '')
    if '-worker-' not in ms:
        continue
    phase = m.get('status', {}).get('phase', '')
    if phase == 'Running':
        ready += 1
print(ready)
" 2>/dev/null || echo 0)

  NODE_COUNT=$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra,!node-role.kubernetes.io/storage' \
    --no-headers 2>/dev/null | grep -c " Ready" || true)

  echo "  Worker machines Running: ${READY_COUNT}/${EXPECTED}; worker-only Ready nodes: ${NODE_COUNT} (elapsed: ${ELAPSED}s)"

  if [[ "$READY_COUNT" -ge "$EXPECTED" && "$NODE_COUNT" -ge "$EXPECTED" ]]; then
    echo "All ${EXPECTED} worker nodes are Ready."
    break
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timed out waiting for worker nodes after ${TIMEOUT}s."
    oc get machineset -n openshift-machine-api | grep worker || true
    oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=worker
    oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra,!node-role.kubernetes.io/storage' -o wide
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

# --- Verify nested virtualization on one worker (best-effort) ---
echo ""
echo "Verifying nested virtualization on a worker node (best-effort)..."
SAMPLE_NODE=$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra,!node-role.kubernetes.io/storage' \
  --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1 || true)
if [[ -n "$SAMPLE_NODE" ]]; then
  NESTED=$(oc debug node/"$SAMPLE_NODE" --quiet -- chroot /host \
    bash -c 'cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo missing' \
    2>/dev/null | tr -d '\r' | tail -1 || echo missing)
  echo "  ${SAMPLE_NODE}: nested=${NESTED}"
  if [[ "$NESTED" != "1" && "$NESTED" != "Y" && "$NESTED" != "y" ]]; then
    echo "  WARNING: nested virt not yet 1/Y (MachineConfig may still be rolling, or kvm module not loaded)."
    echo "  Check: oc get mcp worker; oc debug node/${SAMPLE_NODE} -- chroot /host cat /sys/module/kvm_amd/parameters/nested"
  else
    echo "  Nested virtualization is enabled."
  fi
else
  echo "  No worker-only node found to verify."
fi

echo ""
oc get machineset -n openshift-machine-api | grep -E 'NAME|worker' || true
echo ""
oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra,!node-role.kubernetes.io/storage' -o wide
echo ""
oc get mcp worker

echo ""
echo "============================================"
echo " Worker nodes ready for kube-burner / virt"
echo " SKU: ${WORKER_VM_SIZE} (AMD memory-optimized default)"
echo " Nested virt MachineConfig: 80-enable-nested-virt"
echo " Untainted workers: node-role.kubernetes.io/worker"
echo " Scale later: oc scale machineset <name> -n openshift-machine-api --replicas=N"
echo "============================================"
