#!/bin/bash
set -euo pipefail

echo "Upgrading BetweenNetwork chaincode without network redeploy..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FABRIC_SAMPLES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_NETWORK_DIR="${TEST_NETWORK_DIR:-${FABRIC_SAMPLES_DIR}/test-network}"
CHAINCODE_DIR="${CHAINCODE_DIR:-${FABRIC_SAMPLES_DIR}/betweennetwork/chaincode/participant-chaincode}"
REGISTRY_PATH="${TEST_NETWORK_DIR}/dynamic-org/org-registry.json"
CHANNEL_NAME="${CHANNEL_NAME:-betweennetwork}"
CC_NAME="${CC_NAME:-participant}"
CC_VERSION="${CC_VERSION:-}"
CC_SEQUENCE="${CC_SEQUENCE:-}"
CC_LANG="${CC_LANG:-golang}"
IMAGE_TAG="${IMAGE_TAG:-2.5.14}"
FABRIC_TOOLS_IMAGE="${FABRIC_TOOLS_IMAGE:-hyperledger/fabric-tools:${IMAGE_TAG}}"
IN_CONTAINER_SAMPLES_DIR="/workspace/fabric-samples"
IN_CONTAINER_TEST_NETWORK_DIR="${IN_CONTAINER_SAMPLES_DIR}/test-network"

cd "${TEST_NETWORK_DIR}"

export PATH="${PWD}/../bin:${PWD}:$PATH"
export FABRIC_CFG_PATH="${PWD}/../config/"
export CORE_PEER_TLS_ENABLED=true

ORDERER_CA="${PWD}/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"

if [[ ! -d "${CHAINCODE_DIR}" ]]; then
  echo "Chaincode directory not found: ${CHAINCODE_DIR}"
  exit 1
fi

if [[ ! -f "${REGISTRY_PATH}" ]]; then
  echo "Org registry not found: ${REGISTRY_PATH}"
  exit 1
fi

ensure_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required binary not found: $1"
    exit 1
  fi
}

ensure_binary peer
ensure_binary jq
ensure_binary configtxlator
ensure_binary docker

set_globals_between() {
  export CORE_PEER_LOCALMSPID="BetweenMSP"
  export CORE_PEER_TLS_ROOTCERT_FILE="${PWD}/organizations/peerOrganizations/betweenorganization.example.com/peers/peer0.betweenorganization.example.com/tls/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="${PWD}/organizations/peerOrganizations/betweenorganization.example.com/users/Admin@betweenorganization.example.com/msp"
  export CORE_PEER_ADDRESS="localhost:7051"
}

registry_value_by_msp() {
  local msp_id="$1"
  local key="$2"

  jq -r --arg mspId "${msp_id}" --arg key "${key}" '
    .organizations[]
    | select(.mspId == $mspId)
    | .[$key]
  ' "${REGISTRY_PATH}" | head -n 1
}

peer_port_for_domain() {
  local domain="$1"

  jq -r --arg domain "${domain}" '
    .organizations[]
    | select(.domain == $domain)
    | .peerPort
  ' "${REGISTRY_PATH}" | head -n 1
}

load_org_context() {
  local msp_id="$1"
  local domain
  local peer_port
  local peer_host
  local tls_file
  local admin_path

  domain="$(registry_value_by_msp "${msp_id}" "domain")"
  if [[ -z "${domain}" || "${domain}" == "null" ]]; then
    return 1
  fi

  peer_port="$(peer_port_for_domain "${domain}")"
  if [[ -z "${peer_port}" || "${peer_port}" == "null" ]]; then
    return 1
  fi

  peer_host="peer0.${domain}"
  tls_file="${PWD}/organizations/peerOrganizations/${domain}/peers/${peer_host}/tls/ca.crt"
  admin_path="${PWD}/organizations/peerOrganizations/${domain}/users/Admin@${domain}/msp"

  if [[ ! -f "${tls_file}" || ! -d "${admin_path}" ]]; then
    return 1
  fi

  export CORE_PEER_LOCALMSPID="${msp_id}"
  export CORE_PEER_TLS_ROOTCERT_FILE="${tls_file}"
  export CORE_PEER_MSPCONFIGPATH="${admin_path}"
  export CORE_PEER_ADDRESS="localhost:${peer_port}"
  return 0
}

fetch_channel_org_msps() {
  set_globals_between

  peer channel fetch config /tmp/"${CHANNEL_NAME}"_config_block.pb \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    -c "${CHANNEL_NAME}" \
    --tls \
    --cafile "${ORDERER_CA}" >/dev/null

  configtxlator proto_decode \
    --input /tmp/"${CHANNEL_NAME}"_config_block.pb \
    --type common.Block \
    --output /tmp/"${CHANNEL_NAME}"_config_block.json

  jq -r '.data.data[0].payload.data.config.channel_group.groups.Application.groups | keys[]' \
    /tmp/"${CHANNEL_NAME}"_config_block.json
}

echo "Checking current committed definition..."
set_globals_between

CURRENT_VERSION="$(peer lifecycle chaincode querycommitted --channelID "${CHANNEL_NAME}" --name "${CC_NAME}" 2>/dev/null | sed -n 's/.*Version: \([^,]*\), Sequence:.*/\1/p' | head -n 1)"
CURRENT_SEQ="$(peer lifecycle chaincode querycommitted --channelID "${CHANNEL_NAME}" --name "${CC_NAME}" 2>/dev/null | sed -n 's/.*Sequence: \([0-9]\+\).*/\1/p' | head -n 1)"

if [[ -n "${CURRENT_SEQ}" ]]; then
  NEXT_SEQ=$((CURRENT_SEQ + 1))
  echo "Current committed sequence: ${CURRENT_SEQ} (next required: ${NEXT_SEQ})"
else
  NEXT_SEQ=1
  echo "No committed definition found. Using initial sequence: ${NEXT_SEQ}"
fi

if [[ -z "${CC_SEQUENCE}" ]]; then
  CC_SEQUENCE="${NEXT_SEQ}"
elif [[ "${CC_SEQUENCE}" -ne "${NEXT_SEQ}" ]]; then
  echo "ERROR: CC_SEQUENCE must be exactly ${NEXT_SEQ} (not ${CC_SEQUENCE})"
  exit 1
fi

if [[ -z "${CC_VERSION}" ]]; then
  if [[ -n "${CURRENT_VERSION}" ]]; then
    CC_VERSION="${CURRENT_VERSION%.*}.$((${CURRENT_VERSION##*.} + 1))"
  else
    CC_VERSION="1.0"
  fi
fi

CC_LABEL="${CC_LABEL:-participant_chaincode_${CC_VERSION//./_}}"
PKG_FILE="${CC_LABEL}.tar.gz"

echo "------------------------------------------------------------"
echo "Channel      : ${CHANNEL_NAME}"
echo "CC Name      : ${CC_NAME}"
echo "CC Version   : ${CC_VERSION}"
echo "CC Sequence  : ${CC_SEQUENCE}"
echo "CC Label     : ${CC_LABEL}"
echo "Chaincode dir: ${CHAINCODE_DIR}"
echo "------------------------------------------------------------"

echo "Packaging chaincode -> ${PKG_FILE}"
rm -f "${PKG_FILE}"

peer lifecycle chaincode package "${PKG_FILE}" \
  --path "${CHAINCODE_DIR}" \
  --lang "${CC_LANG}" \
  --label "${CC_LABEL}"

safe_install() {
  local org_label="$1"
  echo "Installing chaincode on ${org_label}..."
  set +e
  local out
  out="$(peer lifecycle chaincode install "${PKG_FILE}" 2>&1)"
  local rc=$?
  set -e

  if echo "${out}" | grep -qi "already successfully installed"; then
    echo "${org_label}: already installed, continuing."
    return 0
  fi

  if [[ ${rc} -ne 0 ]]; then
    echo "${out}"
    exit "${rc}"
  fi

  echo "${out}"
}

echo "Discovering channel member MSPs..."
mapfile -t CHANNEL_MSPS < <(fetch_channel_org_msps)
if [[ ${#CHANNEL_MSPS[@]} -eq 0 ]]; then
  echo "No application MSPs found on channel ${CHANNEL_NAME}"
  exit 1
fi

echo "Channel MSPs: ${CHANNEL_MSPS[*]}"

declare -a APPROVAL_MSPS=()
declare -a COMMIT_PEER_ARGS=()

for msp_id in "${CHANNEL_MSPS[@]}"; do
  if ! load_org_context "${msp_id}"; then
    echo "Skipping ${msp_id}: no usable registry/admin context found."
    continue
  fi

  safe_install "${msp_id}"
  APPROVAL_MSPS+=("${msp_id}")
  COMMIT_PEER_ARGS+=("--peerAddresses" "${CORE_PEER_ADDRESS}" "--tlsRootCertFiles" "${CORE_PEER_TLS_ROOTCERT_FILE}")
done

if [[ ${#APPROVAL_MSPS[@]} -eq 0 ]]; then
  echo "No channel member orgs had usable peer/admin contexts for lifecycle approval."
  exit 1
fi

echo "Resolving Package ID for label: ${CC_LABEL}"
set_globals_between
CC_PACKAGE_ID="$(peer lifecycle chaincode queryinstalled | sed -n "s/Package ID: \\(.*\\), Label: ${CC_LABEL}/\\1/p" | head -n 1)"

if [[ -z "${CC_PACKAGE_ID}" ]]; then
  echo "Could not find Package ID for label '${CC_LABEL}'."
  peer lifecycle chaincode queryinstalled
  exit 1
fi

echo "Package ID: ${CC_PACKAGE_ID}"

for msp_id in "${APPROVAL_MSPS[@]}"; do
  load_org_context "${msp_id}"
  echo "Approving chaincode for ${msp_id}..."
  peer lifecycle chaincode approveformyorg \
    -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com \
    --channelID "${CHANNEL_NAME}" \
    --name "${CC_NAME}" \
    --version "${CC_VERSION}" \
    --package-id "${CC_PACKAGE_ID}" \
    --sequence "${CC_SEQUENCE}" \
    --tls \
    --cafile "${ORDERER_CA}"
done

echo "Checking commit readiness..."
set_globals_between
peer lifecycle chaincode checkcommitreadiness \
  --channelID "${CHANNEL_NAME}" \
  --name "${CC_NAME}" \
  --version "${CC_VERSION}" \
  --sequence "${CC_SEQUENCE}" \
  --output json

echo "Committing chaincode definition..."
peer lifecycle chaincode commit \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID "${CHANNEL_NAME}" \
  --name "${CC_NAME}" \
  --version "${CC_VERSION}" \
  --sequence "${CC_SEQUENCE}" \
  --tls \
  --cafile "${ORDERER_CA}" \
  "${COMMIT_PEER_ARGS[@]}"

echo "Upgrade complete."
peer lifecycle chaincode querycommitted --channelID "${CHANNEL_NAME}" --name "${CC_NAME}"
