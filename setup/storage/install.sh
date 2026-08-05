#!/usr/bin/env bash
# Create ODF storage MachineSets: disk/VM SKU checks → managed-csi-v2 SC → MachineSets → wait.
# Requires: oc, az, python3, KUBECONFIG
# Override defaults with env vars: ODF_VM_SIZE, ODF_REPLICAS, ODF_DISK_SKU

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
echo " ODF Storage Node Setup"
echo "============================================"
echo "ODF_VM_SIZE: ${ODF_VM_SIZE}"
echo "ODF_REPLICAS: ${ODF_REPLICAS}"
echo "ODF_DISK_SKU: ${ODF_DISK_SKU}"
echo "ODF_OSD_STORAGE_CLASS: ${ODF_OSD_STORAGE_CLASS}"
echo ""

# Prefer ~/.azure/osServicePrincipal.json for az CLI (SKU checks)
ensure_azure_auth
echo ""

# --- Discover cluster info ---
echo "Discovering cluster info..."
INFRA_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
echo "Infrastructure ID: ${INFRA_ID}"

# Use an existing infra MachineSet as reference for providerSpec
REF_MS=$(oc get machineset -n openshift-machine-api --no-headers -o custom-columns=NAME:.metadata.name | grep -E 'infra|worker' | head -1)
echo "Reference MachineSet: ${REF_MS}"

REGION=$(oc get machineset "$REF_MS" -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.location}')
echo "Region: ${REGION}"

# Discover all zones
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
ZONES="${ODF_ZONES:-$ZONES}"
echo "Target zones: ${ZONES}"

# --- VM SKU check ---
export REGION ZONES
export INFRA_VM_SIZE="$ODF_VM_SIZE"
bash "$INFRA_SCRIPT_DIR/check-sku.sh"
echo ""

# --- Premium SSD v2 disk SKU check + StorageClass ---
export DISK_SKU="$ODF_DISK_SKU"
bash "$SCRIPT_DIR/check-disk-sku.sh"
echo ""

SC_MANIFEST="$SCRIPT_DIR/../../argocd/manifests/odf/storagecluster/managed-csi-v2-storageclass.yaml"
echo "Applying OSD StorageClass ${ODF_OSD_STORAGE_CLASS} (${ODF_DISK_SKU})..."
oc apply -f "$SC_MANIFEST"
oc get sc "$ODF_OSD_STORAGE_CLASS"
echo ""

# --- Extract providerSpec ---
echo "Extracting providerSpec from ${REF_MS}..."
PROVIDER_SPEC=$(oc get machineset "$REF_MS" -n openshift-machine-api -o json | python3 -c "
import json,sys
ms = json.load(sys.stdin)
ps = ms['spec']['template']['spec']['providerSpec']['value']
print(json.dumps(ps, indent=2))
")

# --- Create storage MachineSets per zone ---
for ZONE in $ZONES; do
  MS_NAME="${INFRA_ID}-storage-${REGION}${ZONE}"
  echo ""
  echo "Creating storage MachineSet: ${MS_NAME} (zone ${ZONE})..."

  if oc get machineset "$MS_NAME" -n openshift-machine-api &>/dev/null; then
    echo "  MachineSet ${MS_NAME} already exists, ensuring replicas=${ODF_REPLICAS}..."
    oc scale machineset "$MS_NAME" -n openshift-machine-api --replicas="${ODF_REPLICAS}"
    continue
  fi

  echo "$PROVIDER_SPEC" | python3 -c "
import json,sys

ps = json.load(sys.stdin)
ps['vmSize'] = '${ODF_VM_SIZE}'
ps['zone'] = '${ZONE}'

ms = {
    'apiVersion': 'machine.openshift.io/v1beta1',
    'kind': 'MachineSet',
    'metadata': {
        'name': '${MS_NAME}',
        'namespace': 'openshift-machine-api',
        'labels': {
            'machine.openshift.io/cluster-api-cluster': '${INFRA_ID}',
            'machine.openshift.io/cluster-api-machine-role': 'storage',
            'machine.openshift.io/cluster-api-machine-type': 'storage',
        }
    },
    'spec': {
        'replicas': ${ODF_REPLICAS},
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
                    'machine.openshift.io/cluster-api-machine-role': 'storage',
                    'machine.openshift.io/cluster-api-machine-type': 'storage',
                    'machine.openshift.io/cluster-api-machineset': '${MS_NAME}',
                }
            },
            'spec': {
                'metadata': {
                    'labels': {
                        'node-role.kubernetes.io/worker': '',
                        'node-role.kubernetes.io/storage': '',
                        'cluster.ocs.openshift.io/openshift-storage': '',
                    }
                },
                'taints': [
                    {
                        'key': 'node.ocs.openshift.io/storage',
                        'value': 'true',
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

# --- Wait for storage nodes to be Ready ---
echo ""
echo "Waiting for storage nodes to become Ready..."
TIMEOUT=600
INTERVAL=15
ELAPSED=0
ZONE_COUNT=$(echo "$ZONES" | wc -w | tr -d ' ')
EXPECTED=$((ZONE_COUNT * ODF_REPLICAS))

while true; do
  READY_COUNT=$(oc get nodes -l cluster.ocs.openshift.io/openshift-storage --no-headers 2>/dev/null | grep -c " Ready" || true)
  echo "  Storage nodes Ready: ${READY_COUNT}/${EXPECTED} (elapsed: ${ELAPSED}s)"

  if [[ "$READY_COUNT" -ge "$EXPECTED" ]]; then
    echo "All ${EXPECTED} storage nodes are Ready."
    break
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    echo "ERROR: Timed out waiting for storage nodes after ${TIMEOUT}s."
    oc get machines -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=storage
    exit 1
  fi

  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
done

echo ""
oc get nodes -l cluster.ocs.openshift.io/openshift-storage -o wide

echo ""
echo "============================================"
echo " ODF storage nodes ready!"
echo " Nodes are labeled with cluster.ocs.openshift.io/openshift-storage"
echo " and tainted with node.ocs.openshift.io/storage=true:NoSchedule"
echo " OSD StorageClass: ${ODF_OSD_STORAGE_CLASS} (${ODF_DISK_SKU})"
echo "============================================"
