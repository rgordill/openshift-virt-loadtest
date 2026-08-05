#!/usr/bin/env bash
# Azure CLI auth helper for setup scripts.
#
# Prefer the OpenShift installer service principal file when present:
#   ~/.azure/osServicePrincipal.json
# Override path with OS_SERVICE_PRINCIPAL_FILE.
#
# Uses an isolated AZURE_CONFIG_DIR so the caller's default `az login`
# session is not overwritten. Source this file, then call ensure_azure_auth.

_ovl_azure_auth_cleanup() {
  if [[ "${_OVL_AZURE_CONFIG_OWNER:-0}" == "1" && -n "${_OVL_AZURE_CONFIG_DIR:-}" && -d "${_OVL_AZURE_CONFIG_DIR}" ]]; then
    rm -rf "${_OVL_AZURE_CONFIG_DIR}"
  fi
}

# Idempotent: safe to source / call from install.sh and check-sku.sh.
ensure_azure_auth() {
  if [[ "${_OVL_AZURE_AUTH_DONE:-0}" == "1" ]]; then
    if az account show >/dev/null 2>&1; then
      return 0
    fi
    # Marker left over after AZURE_CONFIG_DIR cleanup — re-authenticate.
    unset _OVL_AZURE_AUTH_DONE
  fi

  if ! command -v az >/dev/null 2>&1; then
    echo "ERROR: az CLI is required but not found in PATH."
    return 1
  fi

  local sp_file="${OS_SERVICE_PRINCIPAL_FILE:-${HOME}/.azure/osServicePrincipal.json}"

  # Parent already authenticated and exported AZURE_CONFIG_DIR for children.
  if [[ -n "${AZURE_CONFIG_DIR:-}" ]] && az account show >/dev/null 2>&1; then
    local acct
    acct=$(az account show -o tsv --query "[name,id]" 2>/dev/null | tr '\t' ' ')
    echo "Using Azure session: ${acct}"
    export _OVL_AZURE_AUTH_DONE=1
    return 0
  fi

  # Stale isolated config dir — drop it and log in again.
  if [[ -n "${AZURE_CONFIG_DIR:-}" ]] && [[ "${AZURE_CONFIG_DIR}" != "${HOME}/.azure" ]]; then
    unset AZURE_CONFIG_DIR
  fi

  if [[ -f "$sp_file" ]]; then
    _ovl_azure_login_with_sp "$sp_file" || return 1
  else
    echo "No service principal file at ${sp_file}; using current az login."
    if ! az account show >/dev/null 2>&1; then
      echo "ERROR: az is not logged in and ${sp_file} was not found."
      echo "  Run: az login"
      echo "  Or place OpenShift installer credentials at ${sp_file}"
      return 1
    fi
    local acct
    acct=$(az account show -o tsv --query "[name,id]" 2>/dev/null | tr '\t' ' ')
    echo "Using Azure account: ${acct}"
  fi

  export _OVL_AZURE_AUTH_DONE=1
  return 0
}

_ovl_azure_login_with_sp() {
  local sp_file="$1"
  local exports

  # Isolate credentials so we do not clobber ~/.azure from interactive login.
  if [[ -z "${_OVL_AZURE_CONFIG_DIR:-}" ]]; then
    _OVL_AZURE_CONFIG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ovl-azure-XXXXXX")
    export AZURE_CONFIG_DIR="${_OVL_AZURE_CONFIG_DIR}"
    # Owner flag is intentionally NOT exported so child scripts do not
    # delete the parent's isolated config directory on exit.
    _OVL_AZURE_CONFIG_OWNER=1
    trap '_ovl_azure_auth_cleanup' EXIT
  fi

  echo "Authenticating az CLI with service principal from ${sp_file}..."

  if ! exports=$(python3 -c "
import json, shlex, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
required = ('subscriptionId', 'clientId', 'clientSecret', 'tenantId')
missing = [k for k in required if not d.get(k)]
if missing:
    print(f'ERROR: {sys.argv[1]} missing keys: {\" \".join(missing)}', file=sys.stderr)
    sys.exit(1)
for k in required:
    print(f'_OVL_{k}={shlex.quote(str(d[k]))}')
" "$sp_file"); then
    return 1
  fi
  # shellcheck disable=SC2086
  eval "$exports"

  if ! az login --service-principal \
      --username "${_OVL_clientId}" \
      --password "${_OVL_clientSecret}" \
      --tenant "${_OVL_tenantId}" \
      --output none; then
    echo "ERROR: az login with service principal failed (${sp_file})."
    unset _OVL_subscriptionId _OVL_clientId _OVL_clientSecret _OVL_tenantId
    return 1
  fi

  if ! az account set --subscription "${_OVL_subscriptionId}"; then
    echo "ERROR: failed to set subscription ${_OVL_subscriptionId}."
    unset _OVL_subscriptionId _OVL_clientId _OVL_clientSecret _OVL_tenantId
    return 1
  fi

  local acct
  acct=$(az account show -o tsv --query "[name,id]" 2>/dev/null | tr '\t' ' ')
  echo "Azure SP login OK: ${acct}"

  unset _OVL_subscriptionId _OVL_clientId _OVL_clientSecret _OVL_tenantId
  return 0
}
