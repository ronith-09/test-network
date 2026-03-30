#!/bin/bash
set -euo pipefail

echo "Starting BetweenNetwork chaincode deploy automation..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FABRIC_SAMPLES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_NETWORK_DIR="${TEST_NETWORK_DIR:-${FABRIC_SAMPLES_DIR}/test-network}"
CHAINCODE_DIR="${CHAINCODE_DIR:-${FABRIC_SAMPLES_DIR}/betweennetwork/chaincode/participant-chaincode}"
IN_CONTAINER_SAMPLES_DIR="/workspace/fabric-samples"
IN_CONTAINER_TEST_NETWORK_DIR="${IN_CONTAINER_SAMPLES_DIR}/test-network"

cd "${TEST_NETWORK_DIR}"

export IMAGE_TAG="${IMAGE_TAG:-2.5.14}"
export CA_IMAGE_TAG="${CA_IMAGE_TAG:-1.5.17}"
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-net}"
export SKIP_ANCHOR_PEERS="${SKIP_ANCHOR_PEERS:-true}"
export FABRIC_TOOLS_IMAGE="${FABRIC_TOOLS_IMAGE:-hyperledger/fabric-tools:${IMAGE_TAG}}"

CHANNEL_NAME="${CHANNEL_NAME:-betweennetwork}"
CC_NAME="${CC_NAME:-participant}"
CC_LABEL="${CC_LABEL:-participant_chaincode_1}"
CC_VERSION="${CC_VERSION:-1.0}"
CC_SEQUENCE="${CC_SEQUENCE:-1}"
CC_LANG="${CC_LANG:-golang}"
PKG_FILE="${PKG_FILE:-${CC_LABEL}.tar.gz}"
BASELINE_ORGS="${BASELINE_ORGS:-between}"
CONFIGTX_FILE="${TEST_NETWORK_DIR}/configtx/configtx.yaml"
CONFIGTX_BACKUP=""

has_org() {
  local target="$1"
  local item=""

  for item in ${BASELINE_ORGS}; do
    if [[ "${item}" == "${target}" ]]; then
      return 0
    fi
  done

  return 1
}

restore_runtime_overrides() {
  if [[ -n "${CONFIGTX_BACKUP}" && -f "${CONFIGTX_BACKUP}" ]]; then
    mv "${CONFIGTX_BACKUP}" "${CONFIGTX_FILE}"
  fi
}

compute_compose_profiles() {
  local joined=""

  if has_org bank1; then
    joined="bank1"
  fi
  if has_org bank2; then
    if [[ -n "${joined}" ]]; then
      joined+=","
    fi
    joined+="bank2"
  fi
  if has_org bankd; then
    if [[ -n "${joined}" ]]; then
      joined+=","
    fi
    joined+="bankd"
  fi

  echo "${joined}"
}

prepare_configtx_for_baseline() {
  if [[ "${BASELINE_ORGS}" != "between" ]]; then
    return 0
  fi

  CONFIGTX_BACKUP="$(mktemp)"
  cp "${CONFIGTX_FILE}" "${CONFIGTX_BACKUP}"

  awk '
    BEGIN { skip_bank_orgs = 0 }
    skip_bank_orgs {
      if ($0 ~ /^################################################################################$/) {
        skip_bank_orgs = 0
        print
      }
      next
    }
    /^  - &Bank1Organization$/ { skip_bank_orgs = 1; next }
    /^        - \*Bank1Organization$/ { next }
    /^        - \*Bank2Org$/ { next }
    /^        - \*BankDOrg$/ { next }
    { print }
  ' "${CONFIGTX_BACKUP}" > "${CONFIGTX_FILE}"
}

trap restore_runtime_overrides EXIT

echo "Bringing down any existing network..."
./network.sh down || true

NET_NAME="${COMPOSE_PROJECT_NAME}_test"
if docker network inspect "${NET_NAME}" >/dev/null 2>&1; then
  echo "Removing stale docker network: ${NET_NAME}"
  docker network rm "${NET_NAME}" >/dev/null 2>&1 || true
fi

if docker network inspect fabric_test >/dev/null 2>&1; then
  echo "Removing stale docker network: fabric_test"
  docker network rm fabric_test >/dev/null 2>&1 || true
fi

for volume_name in "${COMPOSE_PROJECT_NAME}_orderer.example.com" "${COMPOSE_PROJECT_NAME}_peer0.betweenorganization.example.com"; do
  if docker volume inspect "${volume_name}" >/dev/null 2>&1; then
    echo "Removing stale docker volume: ${volume_name}"
    docker volume rm "${volume_name}" >/dev/null 2>&1 || true
  fi
done

echo "Removing stale generated artifacts..."
rm -rf organizations/peerOrganizations organizations/ordererOrganizations
rm -f channel-artifacts/*.block channel-artifacts/*.tx channel-artifacts/*.json channel-artifacts/*.pb

echo "Starting network..."
export COMPOSE_PROFILES="$(compute_compose_profiles)"
prepare_configtx_for_baseline
./network.sh up -i "${IMAGE_TAG}"

append_peer_args() {
  local peer_address="$1"
  local tls_cert="$2"

  COMMIT_PEER_ARGS+=" --peerAddresses ${peer_address} --tlsRootCertFiles ${tls_cert}"
}

populate_admincerts() {
  local org_domain="$1"
  local admin_cert_name="$2"
  local org_dir="${PWD}/organizations/peerOrganizations/${org_domain}"
  local admin_src="${org_dir}/users/${admin_cert_name}/msp/signcerts/${admin_cert_name}-cert.pem"
  local org_admincerts="${org_dir}/msp/admincerts"

  if [[ -f "${admin_src}" ]]; then
    mkdir -p "${org_admincerts}"
    cp "${admin_src}" "${org_admincerts}/"
  fi
}

populate_orderer_admincerts() {
  local orderer_dir="${PWD}/organizations/ordererOrganizations/example.com"
  local admin_src="${orderer_dir}/users/Admin@example.com/msp/signcerts/Admin@example.com-cert.pem"
  local orderer_admincerts="${orderer_dir}/msp/admincerts"

  if [[ -f "${admin_src}" ]]; then
    mkdir -p "${orderer_admincerts}"
    cp "${admin_src}" "${orderer_admincerts}/"
  fi
}

echo "Populating MSP admincerts..."
populate_admincerts "betweenorganization.example.com" "Admin@betweenorganization.example.com"
if has_org bank1; then
  populate_admincerts "bank1organization.example.com" "Admin@bank1organization.example.com"
fi
if has_org bank2; then
  populate_admincerts "bank2.example.com" "Admin@bank2.example.com"
fi
if has_org bankd; then
  populate_admincerts "bankd.example.com" "Admin@bankd.example.com"
fi
populate_orderer_admincerts

echo "Creating channel ${CHANNEL_NAME}..."
./network.sh createChannel -c "${CHANNEL_NAME}" -i "${IMAGE_TAG}"

ensure_orderer_channel() {
  local list_cmd="osnadmin channel list -o orderer.example.com:7053 --ca-file ${IN_CONTAINER_TEST_NETWORK_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt --client-cert ${IN_CONTAINER_TEST_NETWORK_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt --client-key ${IN_CONTAINER_TEST_NETWORK_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key"
  local join_cmd="osnadmin channel join --channelID ${CHANNEL_NAME} --config-block ${IN_CONTAINER_TEST_NETWORK_DIR}/channel-artifacts/${CHANNEL_NAME}.block -o orderer.example.com:7053 --ca-file ${IN_CONTAINER_TEST_NETWORK_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt --client-cert ${IN_CONTAINER_TEST_NETWORK_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt --client-key ${IN_CONTAINER_TEST_NETWORK_DIR}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key"

  if docker run --rm \
    --network fabric_test \
    -v "${FABRIC_SAMPLES_DIR}:${IN_CONTAINER_SAMPLES_DIR}" \
    -w "${IN_CONTAINER_TEST_NETWORK_DIR}" \
    "${FABRIC_TOOLS_IMAGE}" \
    bash -lc "${list_cmd}" 2>/dev/null | grep -q "\"name\": \"${CHANNEL_NAME}\""
  then
    echo "Orderer already joined channel ${CHANNEL_NAME}."
    return 0
  fi

  echo "Joining orderer to channel ${CHANNEL_NAME}..."
  docker run --rm \
    --network fabric_test \
    -v "${FABRIC_SAMPLES_DIR}:${IN_CONTAINER_SAMPLES_DIR}" \
    -w "${IN_CONTAINER_TEST_NETWORK_DIR}" \
    "${FABRIC_TOOLS_IMAGE}" \
    bash -lc "${join_cmd}"
}

ensure_orderer_channel

export PATH="${PWD}/../bin:${PWD}:$PATH"
export FABRIC_CFG_PATH="${PWD}/../config/"
export CORE_PEER_TLS_ENABLED=true

ORDERER_CA="${PWD}/organizations/ordererOrganizations/example.com/ca/ca.example.com-cert.pem"
ORDERER_TLS_CA_IN_NETWORK="${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt"

BETWEEN_PEER="localhost:7051"
BANK1_PEER="localhost:9051"
BANK2_PEER="localhost:11051"
BANKD_PEER="localhost:12051"

BETWEEN_TLS="${PWD}/organizations/peerOrganizations/betweenorganization.example.com/peers/peer0.betweenorganization.example.com/tls/ca.crt"
BANK1_TLS="${PWD}/organizations/peerOrganizations/bank1organization.example.com/peers/peer0.bank1organization.example.com/tls/ca.crt"
BANK2_TLS="${PWD}/organizations/peerOrganizations/bank2.example.com/peers/peer0.bank2.example.com/tls/ca.crt"
BANKD_TLS="${PWD}/organizations/peerOrganizations/bankd.example.com/peers/peer0.bankd.example.com/tls/ca.crt"

BETWEEN_ADMIN="${PWD}/organizations/peerOrganizations/betweenorganization.example.com/users/Admin@betweenorganization.example.com/msp"
BANK1_ADMIN="${PWD}/organizations/peerOrganizations/bank1organization.example.com/users/Admin@bank1organization.example.com/msp"
BANK2_ADMIN="${PWD}/organizations/peerOrganizations/bank2.example.com/users/Admin@bank2.example.com/msp"
BANKD_ADMIN="${PWD}/organizations/peerOrganizations/bankd.example.com/users/Admin@bankd.example.com/msp"

echo "------------------------------------------------------------"
echo "Deploy target:"
echo "Test network : ${TEST_NETWORK_DIR}"
echo "Chaincode dir: ${CHAINCODE_DIR}"
echo "Channel      : ${CHANNEL_NAME}"
echo "CC Name      : ${CC_NAME}"
echo "Label        : ${CC_LABEL}"
echo "Version      : ${CC_VERSION}"
echo "Sequence     : ${CC_SEQUENCE}"
echo "Organizations: ${BASELINE_ORGS}"
echo "------------------------------------------------------------"

if [[ ! -d "${CHAINCODE_DIR}" ]]; then
  echo "Chaincode directory not found: ${CHAINCODE_DIR}"
  exit 1
fi

echo "Packaging chaincode -> ${PKG_FILE}"
rm -f "${PKG_FILE}"

peer lifecycle chaincode package "${PKG_FILE}" \
  --path "${CHAINCODE_DIR}" \
  --lang "${CC_LANG}" \
  --label "${CC_LABEL}"

safe_install() {
  local org="$1"
  echo "Installing chaincode on ${org}..."
  set +e
  local out
  out=$(peer lifecycle chaincode install "${PKG_FILE}" 2>&1)
  local rc=$?
  set -e

  if echo "${out}" | grep -qi "already successfully installed"; then
    echo "${org}: already installed, continuing."
    return 0
  fi

  if [[ ${rc} -ne 0 ]]; then
    echo "${out}"
    exit "${rc}"
  fi

  echo "${out}"
}

set_peer_globals() {
  local org="$1"

  case "${org}" in
    between)
      export CORE_PEER_LOCALMSPID="BetweenMSP"
      export CORE_PEER_TLS_ROOTCERT_FILE="${BETWEEN_TLS}"
      export CORE_PEER_MSPCONFIGPATH="${BETWEEN_ADMIN}"
      export CORE_PEER_ADDRESS="${BETWEEN_PEER}"
      ;;
    bank1)
      export CORE_PEER_LOCALMSPID="Bank1MSP"
      export CORE_PEER_TLS_ROOTCERT_FILE="${BANK1_TLS}"
      export CORE_PEER_MSPCONFIGPATH="${BANK1_ADMIN}"
      export CORE_PEER_ADDRESS="${BANK1_PEER}"
      ;;
    bank2)
      export CORE_PEER_LOCALMSPID="Bank2MSP"
      export CORE_PEER_TLS_ROOTCERT_FILE="${BANK2_TLS}"
      export CORE_PEER_MSPCONFIGPATH="${BANK2_ADMIN}"
      export CORE_PEER_ADDRESS="${BANK2_PEER}"
      ;;
    bankd)
      export CORE_PEER_LOCALMSPID="BankDMSP"
      export CORE_PEER_TLS_ROOTCERT_FILE="${BANKD_TLS}"
      export CORE_PEER_MSPCONFIGPATH="${BANKD_ADMIN}"
      export CORE_PEER_ADDRESS="${BANKD_PEER}"
      ;;
    *)
      echo "Unknown org key: ${org}"
      exit 1
      ;;
  esac
}

set_peer_globals between
safe_install "BetweenMSP"

if has_org bank1; then
  set_peer_globals bank1
  safe_install "Bank1MSP"
fi

if has_org bank2; then
  set_peer_globals bank2
  safe_install "Bank2MSP"
fi

if has_org bankd; then
  set_peer_globals bankd
  safe_install "BankDMSP"
fi

echo "Extracting Package ID for label: ${CC_LABEL}"
CC_PACKAGE_ID=$(peer lifecycle chaincode queryinstalled | sed -n "s/Package ID: \(.*\), Label: ${CC_LABEL}/\1/p" | head -n 1)

if [[ -z "${CC_PACKAGE_ID:-}" ]]; then
  echo "Could not find Package ID for label '${CC_LABEL}'."
  peer lifecycle chaincode queryinstalled
  exit 1
fi

echo "Package ID: ${CC_PACKAGE_ID}"

run_lifecycle_in_network() {
  local msp_id="$1"
  local peer_address="$2"
  local peer_tls="$3"
  local msp_path="$4"
  local peer_args="$5"
  local lifecycle_cmd="$6"

  docker run --rm \
    --network fabric_test \
    -v "${FABRIC_SAMPLES_DIR}:/workspace/fabric-samples" \
    -w "${IN_CONTAINER_TEST_NETWORK_DIR}" \
    "${FABRIC_TOOLS_IMAGE}" \
    bash -lc "
      export FABRIC_CFG_PATH=\$PWD/../config/ && \
      export CORE_PEER_TLS_ENABLED=true && \
      export CORE_PEER_LOCALMSPID='${msp_id}' && \
      export CORE_PEER_TLS_ROOTCERT_FILE='${peer_tls}' && \
      export CORE_PEER_MSPCONFIGPATH='${msp_path}' && \
      export CORE_PEER_ADDRESS='${peer_address}' && \
      peer lifecycle chaincode ${lifecycle_cmd} ${peer_args}
    "
}

approve_for_org() {
  local org_key="$1"
  local org_name="$2"
  local peer_host=""

  echo "Approving chaincode for ${org_name}..."
  set_peer_globals "${org_key}"

  case "${org_key}" in
    between)
      peer_host="peer0.betweenorganization.example.com:7051"
      ;;
    bank1)
      peer_host="peer0.bank1organization.example.com:9051"
      ;;
    bank2)
      peer_host="peer0.bank2.example.com:11051"
      ;;
    bankd)
      peer_host="peer0.bankd.example.com:12051"
      ;;
  esac

  run_lifecycle_in_network \
    "${CORE_PEER_LOCALMSPID}" \
    "${peer_host}" \
    "${CORE_PEER_TLS_ROOTCERT_FILE/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
    "${CORE_PEER_MSPCONFIGPATH/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
    "--peerAddresses ${peer_host} --tlsRootCertFiles ${CORE_PEER_TLS_ROOTCERT_FILE/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
    "approveformyorg -o orderer.example.com:7050 --ordererTLSHostnameOverride orderer.example.com --channelID ${CHANNEL_NAME} --name ${CC_NAME} --version ${CC_VERSION} --package-id ${CC_PACKAGE_ID} --sequence ${CC_SEQUENCE} --tls --cafile ${ORDERER_TLS_CA_IN_NETWORK/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}"
}

approve_for_org between BetweenMSP
if has_org bank1; then
  approve_for_org bank1 Bank1MSP
fi
if has_org bank2; then
  approve_for_org bank2 Bank2MSP
fi
if has_org bankd; then
  approve_for_org bankd BankDMSP
fi

echo "Checking commit readiness..."
set_peer_globals between
run_lifecycle_in_network \
  "BetweenMSP" \
  "peer0.betweenorganization.example.com:7051" \
  "${BETWEEN_TLS/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
  "${BETWEEN_ADMIN/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
  "" \
  "checkcommitreadiness --channelID ${CHANNEL_NAME} --name ${CC_NAME} --version ${CC_VERSION} --sequence ${CC_SEQUENCE} --output json"

echo "Committing chaincode definition..."
COMMIT_PEER_ARGS="--peerAddresses peer0.betweenorganization.example.com:7051 --tlsRootCertFiles ${BETWEEN_TLS/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}"
if has_org bank1; then
  append_peer_args "peer0.bank1organization.example.com:9051" "${BANK1_TLS/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}"
fi
if has_org bank2; then
  append_peer_args "peer0.bank2.example.com:11051" "${BANK2_TLS/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}"
fi
if has_org bankd; then
  append_peer_args "peer0.bankd.example.com:12051" "${BANKD_TLS/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}"
fi

run_lifecycle_in_network \
  "BetweenMSP" \
  "peer0.betweenorganization.example.com:7051" \
  "${BETWEEN_TLS/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
  "${BETWEEN_ADMIN/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
  "${COMMIT_PEER_ARGS}" \
  "commit -o orderer.example.com:7050 --ordererTLSHostnameOverride orderer.example.com --channelID ${CHANNEL_NAME} --name ${CC_NAME} --version ${CC_VERSION} --sequence ${CC_SEQUENCE} --tls --cafile ${ORDERER_TLS_CA_IN_NETWORK/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}"

echo "Querying committed chaincode..."
set_peer_globals between
run_lifecycle_in_network \
  "BetweenMSP" \
  "peer0.betweenorganization.example.com:7051" \
  "${BETWEEN_TLS/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
  "${BETWEEN_ADMIN/${TEST_NETWORK_DIR}/${IN_CONTAINER_TEST_NETWORK_DIR}}" \
  "" \
  "querycommitted --channelID ${CHANNEL_NAME} --name ${CC_NAME}"

echo "Deploy complete."
echo "Next:"
echo "1. Update backend connection profile / chaincode name if needed."
echo "2. Run a test invoke, for example GetAllParticipants."
