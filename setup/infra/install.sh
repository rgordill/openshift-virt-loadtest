#!/usr/bin/env bash
# Setup infrastructure nodes on Azure: SKU check → create infra MachineSets → wait → move workloads → verify.
# Idempotent: safe to re-run after a partial or successful previous run (workers may already be gone).
# Requires: oc, az, python3, KUBECONFIG
# Override defaults with env vars: INFRA_VM_SIZE, INFRA_REPLICAS, INFRA_ZONES

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load defaults, allow env overrides
set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/params.env"
set +a

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/azure-auth.sh"

# Control-plane operators that run on masters by design — not moved to infra
CONTROL_PLANE_PODS="cluster-image-registry-operator|cluster-monitoring-operator"

# --- helpers ---

list_machinesets_matching() {
  local pattern="$1"
  oc get machineset -n openshift-machine-api --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null \
    | grep -E "$pattern" || true
}

discover_zones_from_role() {
  local role_substr="$1"
  oc get machineset -n openshift-machine-api -o json | python3 -c "
import json,sys
role = sys.argv[1]
ms_list = json.load(sys.stdin)
zones = []
for ms in ms_list['items']:
    if role not in ms['metadata']['name']:
        continue
    zone = ms['spec']['template']['spec']['providerSpec']['value'].get('zone','')
    if zone:
        zones.append(zone)
print(' '.join(sorted(set(zones))))
" "$role_substr"
}

count_movable_off_infra() {
  # Count movable pods that are not yet Running on an infra node
  # (includes Pending/ContainerCreating during reschedule).
  local ns="$1"
  local infra_nodes_re="$2"
  oc get pods -n "$ns" -o json 2>/dev/null | python3 -c "
import json,sys,re
ns_data = json.load(sys.stdin)
infra_re = re.compile(r'^(' + sys.argv[1] + r')$')
cp_re = re.compile(r'^(' + sys.argv[2] + r')')
not_ready = 0
for pod in ns_data.get('items', []):
    owners = pod.get('metadata', {}).get('ownerReferences', [])
    if any(o.get('kind') == 'DaemonSet' for o in owners):
        continue
    name = pod['metadata']['name']
    if cp_re.match(name):
        continue
    phase = pod.get('status', {}).get('phase', '')
    if phase in ('Succeeded', 'Failed'):
        continue
    node = pod.get('spec', {}).get('nodeName', '')
    if phase == 'Running' and infra_re.match(node or ''):
        continue
    not_ready += 1
print(not_ready)
" "$infra_nodes_re" "$CONTROL_PLANE_PODS"
}

wait_namespace_on_infra() {
  local ns="$1"
  local infra_nodes_re="$2"
  local timeout_s="$3"
  local interval_s="${4:-20}"
  local elapsed=0

  echo "Waiting for movable pods in ${ns} to land on infra nodes (timeout ${timeout_s}s)..."
  while true; do
    local off
    off=$(count_movable_off_infra "$ns" "$infra_nodes_re")
    echo "  ${ns}: ${off} movable pod(s) not yet Running on infra (elapsed: ${elapsed}s)"
    if [[ "$off" -eq 0 ]]; then
      echo "  ${ns}: all movable pods on infra."
      return 0
    fi
    if [[ "$elapsed" -ge "$timeout_s" ]]; then
      echo "  ${ns}: timed out with ${off} pod(s) still not ready on infra."
      return 1
    fi
    sleep "$interval_s"
    elapsed=$((elapsed + interval_s))
  done
}

echo "============================================"
echo " Infra Node Setup"
echo "============================================"
echo "INFRA_VM_SIZE: ${INFRA_VM_SIZE}"
echo "INFRA_REPLICAS: ${INFRA_REPLICAS}"
echo ""

# Prefer ~/.azure/osServicePrincipal.json for az CLI (SKU checks)
ensure_azure_auth
echo ""

# --- Discover cluster info (workers may already be gone on re-run) ---
echo "Discovering cluster info..."
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
echo "Infrastructure ID: ${INFRA_ID}"

WORKER_MS=$(list_machinesets_matching 'worker' | head -1)
INFRA_MS=$(list_machinesets_matching 'infra' | head -1)
REF_MS="${WORKER_MS:-$INFRA_MS}"
if [[ -z "$REF_MS" ]]; then
  echo "ERROR: No worker or infra MachineSet found to use as providerSpec reference."
  exit 1
fi
echo "Reference MachineSet: ${REF_MS}"

REGION=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.location}')
echo "Region: ${REGION}"

ZONES=$(discover_zones_from_role worker)
if [[ -z "$ZONES" ]]; then
  ZONES=$(discover_zones_from_role infra)
fi
ZONES="${INFRA_ZONES:-$ZONES}"
if [[ -z "$ZONES" ]]; then
  echo "ERROR: Could not discover zones (no worker/infra MachineSets with zones). Set INFRA_ZONES."
  exit 1
fi
echo "Target infra zones: ${ZONES}"

# --- SKU availability check ---
export REGION ZONES INFRA_VM_SIZE
bash "$SCRIPT_DIR/check-sku.sh"
echo ""

# --- Extract providerSpec from reference MachineSet ---
echo "Extracting providerSpec from ${REF_MS}..."
PROVIDER_SPEC=$(oc get machineset "$REF_MS" -n openshift-machine-api -o json | python3 -c "
import json,sys
ms = json.load(sys.stdin)
ps = ms['spec']['template']['spec']['providerSpec']['value']
print(json.dumps(ps, indent=2))
")

# --- Create / scale infra MachineSets per zone ---
for ZONE in $ZONES; do
  MS_NAME="${INFRA_ID}-infra-${REGION}${ZONE}"
  echo ""
  echo "Ensuring infra MachineSet: ${MS_NAME} (zone ${ZONE})..."

  if oc get machineset "$MS_NAME" -n openshift-machine-api &>/dev/null; then
    CURRENT=$(oc get machineset "$MS_NAME" -n openshift-machine-api -o jsonpath='{.spec.replicas}')
    if [[ "${CURRENT:-0}" != "${INFRA_REPLICAS}" ]]; then
      echo "  MachineSet exists (replicas=${CURRENT}); scaling to ${INFRA_REPLICAS}..."
      oc scale machineset "$MS_NAME" -n openshift-machine-api --replicas="${INFRA_REPLICAS}"
    else
      echo "  MachineSet already exists with replicas=${INFRA_REPLICAS}."
    fi
    continue
  fi

  echo "$PROVIDER_SPEC" | python3 -c "
import json,sys

ps = json.load(sys.stdin)
ps['vmSize'] = '${INFRA_VM_SIZE}'
ps['zone'] = '${ZONE}'

ms = {
    'apiVersion': 'machine.openshift.io/v1beta1',
    'kind': 'MachineSet',
    'metadata': {
        'name': '${MS_NAME}',
        'namespace': 'openshift-machine-api',
        'labels': {
            'machine.openshift.io/cluster-api-cluster': '${INFRA_ID}',
            'machine.openshift.io/cluster-api-machine-role': 'infra',
            'machine.openshift.io/cluster-api-machine-type': 'infra',
        }
    },
    'spec': {
        'replicas': ${INFRA_REPLICAS},
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
                    'machine.openshift.io/cluster-api-machine-role': 'infra',
                    'machine.openshift.io/cluster-api-machine-type': 'infra',
                    'machine.openshift.io/cluster-api-machineset': '${MS_NAME}',
                }
            },
            'spec': {
                'metadata': {
                    'labels': {
                        'node-role.kubernetes.io/infra': '',
                    }
                },
                'taints': [
                    {
                        'key': 'node-role.kubernetes.io/infra',
                        'value': 'reserved',
                        'effect': 'NoSchedule',
                    }
                ],
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

# --- Wait for infra nodes to be Ready ---
echo ""
echo "Waiting for infra nodes to become Ready..."
TIMEOUT=600
INTERVAL=15
ELAPSED=0
EXPECTED=$(echo "$ZONES" | wc -w | tr -d ' ')
EXPECTED=$((EXPECTED * INFRA_REPLICAS))

while true; do
  READY_COUNT=$(oc get nodes -l node-role.kubernetes.io/infra --no-headers 2>/dev/null | grep -c " Ready" || true)
  echo "  Infra nodes Ready: ${READY_COUNT}/${EXPECTED} (elapsed: ${ELAPSED}s)"

  if [[ "$READY_COUNT" -ge "$EXPECTED" ]]; then
    echo "All ${EXPECTED} infra nodes are Ready."
    break
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timed out waiting for infra nodes after ${TIMEOUT}s."
    oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=infra
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
oc get nodes -l node-role.kubernetes.io/infra -o wide
echo ""

# --- Move platform infra workloads (idempotent oc apply / patch) ---
echo "============================================"
echo " Moving infra workloads to infra nodes"
echo "============================================"

echo ""
echo "--- Moving Router (IngressController/default) ---"
oc apply -f "$SCRIPT_DIR/workloads/ingresscontroller-patch.yaml"

echo ""
echo "--- Moving Image Registry ---"
oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge \
  --patch "$(python3 -c "
import yaml,json,sys
with open('${SCRIPT_DIR}/workloads/imageregistry-patch.yaml') as f:
    doc = yaml.safe_load(f)
print(json.dumps({'spec': {'nodeSelector': doc['spec']['nodeSelector'], 'tolerations': doc['spec']['tolerations']}}))
")"

echo ""
echo "--- Moving Monitoring Stack ---"
oc apply -f "$SCRIPT_DIR/workloads/cluster-monitoring-config.yaml"

INFRA_NODES=$(oc get nodes -l node-role.kubernetes.io/infra --no-headers -o custom-columns=NAME:.metadata.name | tr '\n' '|' | sed 's/|$//')
echo ""
echo "Infra nodes: $(echo "$INFRA_NODES" | tr '|' ', ')"

# Router / registry usually move quickly; monitoring (Prometheus PVC remount) needs longer.
echo ""
echo "============================================"
echo " Waiting for infra workload placement"
echo "============================================"

PLACEMENT_ERRORS=0
wait_namespace_on_infra "openshift-ingress" "$INFRA_NODES" 300 15 || PLACEMENT_ERRORS=$((PLACEMENT_ERRORS + 1))
wait_namespace_on_infra "openshift-image-registry" "$INFRA_NODES" 300 15 || PLACEMENT_ERRORS=$((PLACEMENT_ERRORS + 1))
# Prometheus / Alertmanager stateful restarts commonly need 10+ minutes
wait_namespace_on_infra "openshift-monitoring" "$INFRA_NODES" 900 20 || PLACEMENT_ERRORS=$((PLACEMENT_ERRORS + 1))

echo ""
echo "============================================"
echo " Verifying infra workload placement"
echo "============================================"

ERRORS=0
for ns in openshift-ingress openshift-image-registry openshift-monitoring; do
  echo ""
  echo "=== ${ns} ==="
  ERR_FILE=$(mktemp)
  PODS=$(oc get pods -n "$ns" -o json | python3 -c "
import json,sys,re
data = json.load(sys.stdin)
infra_re = re.compile(r'^(' + sys.argv[1] + r')$')
cp_re = re.compile(r'^(' + sys.argv[2] + r')')
errors = 0
for pod in data.get('items', []):
    if pod.get('status', {}).get('phase') != 'Running':
        continue
    owners = pod.get('metadata', {}).get('ownerReferences', [])
    if any(o.get('kind') == 'DaemonSet' for o in owners):
        continue
    name = pod['metadata']['name']
    node = pod.get('spec', {}).get('nodeName', 'unknown')
    if cp_re.match(name):
        print(f'  SKIP (control-plane operator): {name} -> {node}')
        continue
    if infra_re.match(node):
        print(f'  OK: {name} -> {node}')
    else:
        print(f'  FAIL: {name} -> {node} (NOT on infra node)')
        errors += 1
print(errors, file=sys.stderr)
" "$INFRA_NODES" "$CONTROL_PLANE_PODS" 2>"$ERR_FILE")
  echo "$PODS"
  NS_ERRORS=$(cat "$ERR_FILE" 2>/dev/null || echo 0)
  rm -f "$ERR_FILE"
  if [[ -z "$PODS" ]]; then
    echo "  No movable Running pods found"
  fi
  ERRORS=$((ERRORS + NS_ERRORS))
done

if [[ "$ERRORS" -gt 0 || "$PLACEMENT_ERRORS" -gt 0 ]]; then
  echo ""
  echo "ERROR: infra workload placement incomplete (verify_errors=${ERRORS}, wait_timeouts=${PLACEMENT_ERRORS})."
  echo "Re-run this script after checking: oc get pods -n openshift-monitoring -o wide"
  exit 1
fi

# --- Scale down / delete old worker MachineSets (no-op if already removed) ---
echo ""
echo "============================================"
echo " Removing old worker nodes"
echo "============================================"

WORKER_MACHINESETS=$(list_machinesets_matching 'worker')
if [[ -z "$WORKER_MACHINESETS" ]]; then
  echo "No worker MachineSets found (already removed)."
else
  for WMS in $WORKER_MACHINESETS; do
    CURRENT=$(oc get machineset "$WMS" -n openshift-machine-api -o jsonpath='{.spec.replicas}')
    if [[ "${CURRENT:-0}" -gt 0 ]]; then
      echo "Scaling down ${WMS} from ${CURRENT} to 0..."
      oc scale machineset "$WMS" -n openshift-machine-api --replicas=0
    else
      echo "  ${WMS} already at 0 replicas."
    fi
  done

  echo ""
  echo "Waiting for worker nodes to drain and terminate..."
  TIMEOUT=900
  INTERVAL=30
  ELAPSED=0

  while true; do
    WORKER_COUNT=$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra' --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "  Worker-only nodes remaining: ${WORKER_COUNT} (elapsed: ${ELAPSED}s)"

    if [[ "$WORKER_COUNT" -eq 0 ]]; then
      echo "All old worker nodes removed."
      break
    fi

    if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
      echo "ERROR: Timed out waiting for worker removal after ${TIMEOUT}s."
      oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/infra' -o wide
      exit 1
    fi

    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
  done

  echo ""
  echo "Deleting old worker MachineSets..."
  for WMS in $WORKER_MACHINESETS; do
    if oc get machineset "$WMS" -n openshift-machine-api &>/dev/null; then
      echo "  Deleting ${WMS}..."
      oc delete machineset "$WMS" -n openshift-machine-api --wait=false --ignore-not-found
    else
      echo "  ${WMS} already deleted."
    fi
  done
fi

# --- Clear default node-selector on namespaces that ship without the annotation ---
# Without openshift.io/node-selector: "", a scheduler defaultNodeSelector (or the
# absence of untainted workers after worker MachineSets are removed) can leave
# Pods unschedulable. Red Hat workaround for openshift-network-console
# (OCPBUGS-56949); also apply to related namespaces that commonly lack it.
# See: https://access.redhat.com/solutions/7115341
echo ""
echo "Annotating namespaces with openshift.io/node-selector=\"\" ..."
for NS in \
  openshift-network-console \
  openshift-network-diagnostics \
  openshift-catalogd \
  openshift-cluster-olm-operator \
  openshift-operator-controller; do
  if oc get namespace "$NS" &>/dev/null; then
    echo "  Ensuring annotation on namespace/${NS}..."
    oc annotate namespace "$NS" openshift.io/node-selector="" --overwrite
  fi
done

# After worker MachineSets are deleted, only infra/storage/master nodes remain.
# Infra and storage carry NoSchedule taints, so Deployments in the namespaces
# above still need an infra toleration to schedule (operator does not expose
# placement for these). Apply after the node-selector annotation.
echo ""
echo "Adding infra tolerations so pods can schedule on infra nodes..."
INFRA_TOLERATION='{"spec":{"template":{"spec":{"tolerations":[{"key":"node-role.kubernetes.io/infra","value":"reserved","effect":"NoSchedule"}]}}}}'
for DEP_NS_NAME in \
  "openshift-network-console/networking-console-plugin" \
  "openshift-network-diagnostics/network-check-source"; do
  NS="${DEP_NS_NAME%%/*}"
  DEP="${DEP_NS_NAME##*/}"
  if oc get deployment "$DEP" -n "$NS" &>/dev/null; then
    HAS_TOL=$(oc get deployment "$DEP" -n "$NS" -o json | python3 -c "
import json,sys
dep=json.load(sys.stdin)
tols=dep.get('spec',{}).get('template',{}).get('spec',{}).get('tolerations') or []
print('yes' if any(t.get('key')=='node-role.kubernetes.io/infra' for t in tols) else 'no')
")
    if [[ "$HAS_TOL" == "yes" ]]; then
      echo "  ${NS}/${DEP} already has infra toleration."
    else
      echo "  Patching ${NS}/${DEP}..."
      oc patch deployment "$DEP" -n "$NS" --type=strategic -p "$INFRA_TOLERATION"
    fi
  fi
done

# --- Post-removal pod health check ---
echo ""
echo "============================================"
echo " Post-removal pod health check"
echo "============================================"

echo "Waiting for cluster to stabilize (up to 180s)..."
STABLE_TIMEOUT=180
STABLE_INTERVAL=20
STABLE_ELAPSED=0
while true; do
  PROBLEM_COUNT=$(oc get pods --all-namespaces --no-headers 2>/dev/null \
    | awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {c++} END {print c+0}')
  echo "  Non-Running/Completed pods: ${PROBLEM_COUNT} (elapsed: ${STABLE_ELAPSED}s)"
  if [[ "$PROBLEM_COUNT" -eq 0 || "$STABLE_ELAPSED" -ge "$STABLE_TIMEOUT" ]]; then
    break
  fi
  sleep "$STABLE_INTERVAL"
  STABLE_ELAPSED=$((STABLE_ELAPSED + STABLE_INTERVAL))
done

echo ""
echo "--- Checking for unhealthy pods across all namespaces ---"
PROBLEM_PODS=$(oc get pods --all-namespaces --no-headers 2>/dev/null \
  | awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {print $1"/"$2, $4}' || true)

if [[ -z "$PROBLEM_PODS" ]]; then
  echo "  All pods are Running/Completed."
else
  echo "  Pods in non-healthy state:"
  echo "$PROBLEM_PODS"
fi

echo ""
echo "--- Checking for pods in CrashLoopBackOff or Error ---"
CRASH_PODS=$(oc get pods --all-namespaces --no-headers 2>/dev/null \
  | awk '$4 == "CrashLoopBackOff" || $4 == "Error" || $4 == "ImagePullBackOff" {print $1"/"$2, $4}' || true)

if [[ -z "$CRASH_PODS" ]]; then
  echo "  No CrashLoopBackOff / Error / ImagePullBackOff pods."
else
  echo "  PROBLEM pods:"
  echo "$CRASH_PODS"
fi

echo ""
echo "--- Checking cluster operators ---"
UNHEALTHY_CO=$(oc get co --no-headers | awk '$3!="True" || $4=="True" || $5=="True" {print $0}' || true)
if [[ -z "$UNHEALTHY_CO" ]]; then
  echo "  All cluster operators healthy."
else
  echo "  Cluster operator issues:"
  echo "$UNHEALTHY_CO"
fi

echo ""
echo "--- Node summary ---"
oc get nodes -o wide

echo ""
echo "============================================"
echo " Infra setup complete!"
echo " - Infra workloads verified on infra nodes"
echo " - Old worker nodes removed (or already absent)"
echo " - Cluster health checked"
echo "============================================"
