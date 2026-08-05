#!/usr/bin/env bash
# Check Azure managed-disk SKU availability (e.g. PremiumV2_LRS) in a region/zones.
#
# Required env: DISK_SKU, REGION
# Optional env: ZONES (space-separated, e.g. "1 2 3")
# Optional env: SKIP_DISK_SKU_CHECK=1 to skip
#
# Exits non-zero only when the Azure API confirms the disk SKU is unavailable.
# If az cannot query SKUs, prints a warning and exits 0 (same soft-fail as check-sku.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/azure-auth.sh"

: "${DISK_SKU:?DISK_SKU must be set (e.g. PremiumV2_LRS)}"
: "${REGION:?REGION must be set}"

if [[ "${SKIP_DISK_SKU_CHECK:-0}" == "1" ]]; then
  echo "SKIP_DISK_SKU_CHECK=1 set; skipping Azure disk SKU availability check."
  exit 0
fi

ensure_azure_auth

echo "Checking disk SKU ${DISK_SKU} availability in region ${REGION}..."

SKU_ERR=$(mktemp)
trap 'rm -f "$SKU_ERR"; _ovl_azure_auth_cleanup' EXIT

set +e
SKU_JSON=$(az vm list-skus --location "$REGION" --resource-type disks \
  --query "[?name=='${DISK_SKU}']" -o json 2>"$SKU_ERR")
AZ_RC=$?
set -e

if [[ $AZ_RC -ne 0 ]]; then
  echo "WARNING: Unable to query Azure disk SKUs (az exit ${AZ_RC}). Continuing without disk SKU validation."
  if [[ -s "$SKU_ERR" ]]; then
    sed 's/^/  /' "$SKU_ERR"
  fi
  echo "  Tip: grant Microsoft.Compute/skus/read, or set SKIP_DISK_SKU_CHECK=1."
  exit 0
fi

if [[ -z "${SKU_JSON//[[:space:]]/}" ]]; then
  echo "WARNING: Azure disk SKU query returned empty output. Continuing without disk SKU validation."
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
  echo "WARNING: Failed to parse Azure disk SKU response. Continuing without disk SKU validation."
  sed 's/^/  /' "$SKU_ERR" 2>/dev/null || true
  exit 0
}

if [[ "$COUNT" -eq 0 ]]; then
  echo "ERROR: Disk SKU ${DISK_SKU} is not available in region ${REGION}."
  echo "Available disk SKUs in ${REGION} (first 30):"
  az vm list-skus --location "$REGION" --resource-type disks \
    --query "[].name" -o tsv 2>/dev/null | sort -u | head -30 || true
  exit 1
fi

AVAILABLE_ZONES=$(echo "$SKU_JSON" | python3 -c "
import json,sys
skus = json.load(sys.stdin)
zones = set()
for s in skus:
    for li in s.get('locationInfo', []):
        # Prefer location match; list-skus --location already filters
        for z in li.get('zones', []) or []:
            zones.add(str(z))
print(' '.join(sorted(zones)))
")

echo "Disk SKU ${DISK_SKU} available in zones: ${AVAILABLE_ZONES:-<none reported>}"

if [[ -n "${ZONES:-}" ]]; then
  if [[ -z "$AVAILABLE_ZONES" ]]; then
    echo "WARNING: Azure did not report zone info for ${DISK_SKU}; skipping zone validation."
  else
    for z in $ZONES; do
      if ! echo "$AVAILABLE_ZONES" | grep -qw "$z"; then
        echo "ERROR: Disk SKU ${DISK_SKU} is NOT available in zone ${z} of region ${REGION}."
        exit 1
      fi
    done
    echo "All requested zones (${ZONES}) support ${DISK_SKU}."
  fi
fi

echo "Disk SKU check passed."
