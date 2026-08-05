#!/usr/bin/env bash
# Check Azure VM SKU availability in a given region and zones.
# Exits non-zero only when the Azure API confirms the SKU is unavailable
# or not present in a requested zone.
#
# If az cannot query SKUs (missing Microsoft.Compute/skus/read, network
# errors, etc.), prints a warning and exits 0 so install can continue —
# the Machine API will still fail later if the size is truly invalid.
#
# Required env: INFRA_VM_SIZE, REGION
# Optional env: ZONES (space-separated, e.g. "1 3")
# Optional env: SKIP_SKU_CHECK=1 to skip entirely

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/azure-auth.sh"

: "${INFRA_VM_SIZE:?INFRA_VM_SIZE must be set}"
: "${REGION:?REGION must be set}"

if [[ "${SKIP_SKU_CHECK:-0}" == "1" ]]; then
  echo "SKIP_SKU_CHECK=1 set; skipping Azure SKU availability check."
  exit 0
fi

ensure_azure_auth

echo "Checking SKU ${INFRA_VM_SIZE} availability in region ${REGION}..."

SKU_ERR=$(mktemp)
trap 'rm -f "$SKU_ERR"; _ovl_azure_auth_cleanup' EXIT

set +e
SKU_JSON=$(az vm list-skus --location "$REGION" --size "$INFRA_VM_SIZE" \
  --resource-type virtualMachines \
  --query "[?name=='${INFRA_VM_SIZE}']" -o json 2>"$SKU_ERR")
AZ_RC=$?
set -e

if [[ $AZ_RC -ne 0 ]]; then
  echo "WARNING: Unable to query Azure SKUs (az exit ${AZ_RC}). Continuing without SKU validation."
  if [[ -s "$SKU_ERR" ]]; then
    sed 's/^/  /' "$SKU_ERR"
  fi
  echo "  Tip: grant Microsoft.Compute/skus/read on the subscription, or set SKIP_SKU_CHECK=1."
  exit 0
fi

if [[ -z "${SKU_JSON//[[:space:]]/}" ]]; then
  echo "WARNING: Azure SKU query returned empty output. Continuing without SKU validation."
  exit 0
fi

COUNT=$(echo "$SKU_JSON" | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as e:
    print(f'INVALID:{e}', file=sys.stderr)
    sys.exit(2)
if not isinstance(data, list):
    print('INVALID:expected JSON array', file=sys.stderr)
    sys.exit(2)
print(len(data))
" 2>"$SKU_ERR") || {
  echo "WARNING: Failed to parse Azure SKU response. Continuing without SKU validation."
  sed 's/^/  /' "$SKU_ERR" 2>/dev/null || true
  exit 0
}

if [[ "$COUNT" -eq 0 ]]; then
  echo "ERROR: SKU ${INFRA_VM_SIZE} is not available in region ${REGION}."
  echo "Available sizes in ${REGION} (first 20):"
  az vm list-skus --location "$REGION" --resource-type virtualMachines \
    --query "[?resourceType=='virtualMachines' && length(restrictions)==\`0\`].name" -o tsv 2>/dev/null \
    | head -20 || true
  exit 1
fi

RESTRICTED=$(echo "$SKU_JSON" | python3 -c "
import json,sys
skus = json.load(sys.stdin)
for s in skus:
    if s.get('restrictions'):
        for r in s['restrictions']:
            print(f\"  Restriction: {r.get('type','?')}: {r.get('reasonCode','?')}\")
")

if [[ -n "$RESTRICTED" ]]; then
  echo "WARNING: SKU ${INFRA_VM_SIZE} has restrictions in ${REGION}:"
  echo "$RESTRICTED"
fi

AVAILABLE_ZONES=$(echo "$SKU_JSON" | python3 -c "
import json,sys
skus = json.load(sys.stdin)
zones = set()
for s in skus:
    for li in s.get('locationInfo',[]):
        for z in li.get('zones',[]):
            zones.add(z)
print(' '.join(sorted(zones)))
")

echo "SKU ${INFRA_VM_SIZE} available in zones: ${AVAILABLE_ZONES:-<none reported>}"

if [[ -n "${ZONES:-}" ]]; then
  if [[ -z "$AVAILABLE_ZONES" ]]; then
    echo "WARNING: Azure did not report zone info for ${INFRA_VM_SIZE}; skipping zone validation."
  else
    for z in $ZONES; do
      if ! echo "$AVAILABLE_ZONES" | grep -qw "$z"; then
        echo "ERROR: SKU ${INFRA_VM_SIZE} is NOT available in zone ${z} of region ${REGION}."
        exit 1
      fi
    done
    echo "All requested zones (${ZONES}) are available."
  fi
fi

echo "SKU check passed."
