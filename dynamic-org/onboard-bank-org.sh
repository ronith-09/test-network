#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NETWORK_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
REGISTRY_PATH="${SCRIPT_DIR}/org-registry.json"
GENERATED_ROOT="${SCRIPT_DIR}/generated"

export PATH="${TEST_NETWORK_HOME}/../bin:${TEST_NETWORK_HOME}:$PATH"
export FABRIC_CFG_PATH="${TEST_NETWORK_HOME}/configtx"

. "${TEST_NETWORK_HOME}/scripts/utils.sh"

: "${CONTAINER_CLI:=docker}"
if command -v "${CONTAINER_CLI}-compose" >/dev/null 2>&1; then
  : "${CONTAINER_CLI_COMPOSE:=${CONTAINER_CLI}-compose}"
else
  : "${CONTAINER_CLI_COMPOSE:=${CONTAINER_CLI} compose}"
fi

CHANNEL_NAME="${FABRIC_CHANNEL_NAME:-betweennetwork}"
BANK_ID=""
ORG_NAME=""
MSP_ID=""
DOMAIN=""
PEER_PORT=""
OPERATIONS_PORT=""
OUTPUT_JSON=""
VERBOSE="false"

function print_help() {
  cat <<'EOF'
Usage:
  onboard-bank-org.sh --bank-id BANKC --org-name BankC --msp-id BankCMSP --domain bankc.example.com [options]

Options:
  --channel <name>           Channel to update (default: betweennetwork)
  --peer-port <port>         Peer listen port (auto-assigned if omitted)
  --operations-port <port>   Operations port (auto-assigned if omitted)
  --output-json <path>       Write onboarding result JSON to this path
  --verbose                  Enable verbose logging
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --channel)
      CHANNEL_NAME="$2"
      shift 2
      ;;
    --bank-id)
      BANK_ID="$2"
      shift 2
      ;;
    --org-name)
      ORG_NAME="$2"
      shift 2
      ;;
    --msp-id)
      MSP_ID="$2"
      shift 2
      ;;
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --peer-port)
      PEER_PORT="$2"
      shift 2
      ;;
    --operations-port)
      OPERATIONS_PORT="$2"
      shift 2
      ;;
    --output-json)
      OUTPUT_JSON="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE="true"
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      fatalln "Unknown argument: $1"
      ;;
  esac
done

if [[ -z "${BANK_ID}" || -z "${ORG_NAME}" || -z "${MSP_ID}" || -z "${DOMAIN}" ]]; then
  print_help
  fatalln "bank-id, org-name, msp-id, and domain are required"
fi

PEER_HOST="peer0.${DOMAIN}"
CHAINCODE_PORT=""
ORG_KEY="$(echo "${DOMAIN%%.*}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
GENERATED_DIR="${GENERATED_ROOT}/${ORG_KEY}"
ORG_BASE_DIR="${TEST_NETWORK_HOME}/organizations/peerOrganizations/${DOMAIN}"
ORG_PEER_DIR="${ORG_BASE_DIR}/peers/${PEER_HOST}"
ORDERER_CA="${TEST_NETWORK_HOME}/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"
PEERCFG_PATH="${TEST_NETWORK_HOME}/compose/docker/peercfg"
DOCKER_SOCK_PATH="${DOCKER_HOST:-/var/run/docker.sock}"
DOCKER_SOCK_PATH="${DOCKER_SOCK_PATH#unix://}"

mkdir -p "${GENERATED_DIR}" "${TEST_NETWORK_HOME}/channel-artifacts"

function ensure_binary() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fatalln "$1 binary not found"
  fi
}

ensure_binary cryptogen
ensure_binary configtxgen
ensure_binary configtxlator
ensure_binary jq
ensure_binary "${CONTAINER_CLI}"

function next_peer_port() {
  jq -r '([.organizations[].peerPort] | max // 12051) + 1000' "${REGISTRY_PATH}"
}

function next_operations_port() {
  jq -r '([.organizations[].operationsPort] | max // 9448) + 1' "${REGISTRY_PATH}"
}

if [[ -z "${PEER_PORT}" ]]; then
  PEER_PORT="$(next_peer_port)"
fi

if [[ -z "${OPERATIONS_PORT}" ]]; then
  OPERATIONS_PORT="$(next_operations_port)"
fi

CHAINCODE_PORT="$((PEER_PORT + 1))"

function render_template() {
  local template_path="$1"
  local output_path="$2"

  sed \
    -e "s|__ORG_NAME__|${ORG_NAME}|g" \
    -e "s|__BANK_ID__|${BANK_ID}|g" \
    -e "s|__MSP_ID__|${MSP_ID}|g" \
    -e "s|__MSP_DIR__|${ORG_BASE_DIR}/msp|g" \
    -e "s|__DOMAIN__|${DOMAIN}|g" \
    -e "s|__PEER_HOST__|${PEER_HOST}|g" \
    -e "s|__PEER_PORT__|${PEER_PORT}|g" \
    -e "s|__CHAINCODE_PORT__|${CHAINCODE_PORT}|g" \
    -e "s|__OPERATIONS_PORT__|${OPERATIONS_PORT}|g" \
    -e "s|__PEERCFG_PATH__|${PEERCFG_PATH}|g" \
    -e "s|__PEER_CRYPTO_PATH__|${ORG_PEER_DIR}|g" \
    -e "s|__DOCKER_SOCK__|${DOCKER_SOCK_PATH}|g" \
    "${template_path}" > "${output_path}"
}

function one_line_pem() {
  awk 'NF {sub(/\n/, ""); printf "%s\\\\n",$0;}' "$1"
}

function indented_pem() {
  sed 's/^/        /' "$1"
}

function set_org_context() {
  local msp_id="$1"
  local domain="$2"
  local peer_port="$3"

  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID="${msp_id}"
  export CORE_PEER_TLS_ROOTCERT_FILE="${TEST_NETWORK_HOME}/organizations/peerOrganizations/${domain}/tlsca/tlsca.${domain}-cert.pem"
  export CORE_PEER_MSPCONFIGPATH="${TEST_NETWORK_HOME}/organizations/peerOrganizations/${domain}/users/Admin@${domain}/msp"
  export CORE_PEER_ADDRESS="localhost:${peer_port}"
}

function sign_with_current_orgs() {
  while IFS= read -r org_json; do
    local signer_msp signer_domain signer_port
    signer_msp="$(echo "${org_json}" | jq -r '.mspId')"
    signer_domain="$(echo "${org_json}" | jq -r '.domain')"
    signer_port="$(echo "${org_json}" | jq -r '.peerPort')"

    set_org_context "${signer_msp}" "${signer_domain}" "${signer_port}"
    peer channel signconfigtx -f "${GENERATED_DIR}/org_update_in_envelope.pb"
  done < <(jq -c '.organizations[] | select(.active == true)' "${REGISTRY_PATH}")
}

function update_registry() {
  local tmp_registry
  tmp_registry="$(mktemp)"

  jq \
    --arg key "${ORG_KEY}" \
    --arg displayName "${ORG_NAME}" \
    --arg mspId "${MSP_ID}" \
    --arg domain "${DOMAIN}" \
    --arg peerHost "${PEER_HOST}" \
    --argjson peerPort "${PEER_PORT}" \
    --argjson operationsPort "${OPERATIONS_PORT}" \
    '
      .organizations |= (
        map(select(.mspId != $mspId)) + [{
          key: $key,
          displayName: $displayName,
          mspId: $mspId,
          domain: $domain,
          peerHost: $peerHost,
          peerPort: $peerPort,
          operationsPort: $operationsPort,
          active: true
        }]
      )
    ' "${REGISTRY_PATH}" > "${tmp_registry}"

  mv "${tmp_registry}" "${REGISTRY_PATH}"
}

function create_anchor_peer_update() {
  local config_json="${GENERATED_DIR}/${MSP_ID}_config.json"
  local modified_json="${GENERATED_DIR}/${MSP_ID}_modified_config.json"
  local update_pb="${GENERATED_DIR}/${MSP_ID}_anchors.pb"

  peer channel fetch config "${GENERATED_DIR}/anchor_config_block.pb" -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com -c "${CHANNEL_NAME}" --tls --cafile "${ORDERER_CA}" >&"${GENERATED_DIR}/anchor_fetch.log"
  configtxlator proto_decode --input "${GENERATED_DIR}/anchor_config_block.pb" --type common.Block --output "${GENERATED_DIR}/anchor_config_block.json"
  jq .data.data[0].payload.data.config "${GENERATED_DIR}/anchor_config_block.json" > "${config_json}"

  jq \
    --arg mspId "${MSP_ID}" \
    --arg host "${PEER_HOST}" \
    --argjson port "${PEER_PORT}" \
    '.channel_group.groups.Application.groups[$mspId].values += {
      "AnchorPeers": {
        "mod_policy": "Admins",
        "value": {
          "anchor_peers": [
            {
              "host": $host,
              "port": $port
            }
          ]
        },
        "version": "0"
      }
    }' "${config_json}" > "${modified_json}"

  configtxlator proto_encode --input "${config_json}" --type common.Config --output "${GENERATED_DIR}/anchor_original.pb"
  configtxlator proto_encode --input "${modified_json}" --type common.Config --output "${GENERATED_DIR}/anchor_modified.pb"
  configtxlator compute_update --channel_id "${CHANNEL_NAME}" --original "${GENERATED_DIR}/anchor_original.pb" --updated "${GENERATED_DIR}/anchor_modified.pb" --output "${GENERATED_DIR}/anchor_update.pb"
  configtxlator proto_decode --input "${GENERATED_DIR}/anchor_update.pb" --type common.ConfigUpdate --output "${GENERATED_DIR}/anchor_update.json"
  echo "{\"payload\":{\"header\":{\"channel_header\":{\"channel_id\":\"${CHANNEL_NAME}\",\"type\":2}},\"data\":{\"config_update\":$(cat "${GENERATED_DIR}/anchor_update.json")}}}" | jq . > "${GENERATED_DIR}/anchor_update_in_envelope.json"
  configtxlator proto_encode --input "${GENERATED_DIR}/anchor_update_in_envelope.json" --type common.Envelope --output "${update_pb}"

  peer channel update -f "${update_pb}" -c "${CHANNEL_NAME}" -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile "${ORDERER_CA}" >&"${GENERATED_DIR}/anchor_update.log"
}

infoln "Preparing dynamic onboarding assets for ${MSP_ID}"

render_template "${TEMPLATES_DIR}/crypto-config-template.yaml" "${GENERATED_DIR}/crypto-config.yaml"
render_template "${TEMPLATES_DIR}/configtx-org-template.yaml" "${GENERATED_DIR}/configtx.yaml"
render_template "${TEMPLATES_DIR}/compose-org-template.yaml" "${GENERATED_DIR}/compose-org.yaml"
render_template "${TEMPLATES_DIR}/docker-compose-org-template.yaml" "${GENERATED_DIR}/docker-compose-org.yaml"

if [[ ! -d "${ORG_BASE_DIR}/msp" ]]; then
  infoln "Generating crypto material for ${MSP_ID}"
  cryptogen generate --config="${GENERATED_DIR}/crypto-config.yaml" --output="${TEST_NETWORK_HOME}/organizations"
else
  infoln "Crypto material for ${MSP_ID} already exists, reusing it"
fi

infoln "Generating organization definition JSON for ${MSP_ID}"
FABRIC_CFG_PATH="${GENERATED_DIR}" configtxgen -printOrg "${MSP_ID}" > "${ORG_BASE_DIR}/org-definition.json"

infoln "Starting peer container for ${PEER_HOST}"
DOCKER_SOCK="${DOCKER_SOCK_PATH}" ${CONTAINER_CLI_COMPOSE} -f "${GENERATED_DIR}/compose-org.yaml" -f "${GENERATED_DIR}/docker-compose-org.yaml" up -d

infoln "Fetching live channel configuration for ${CHANNEL_NAME}"
FIRST_SIGNER_DOMAIN="$(jq -r '.organizations[] | select(.active == true) | .domain' "${REGISTRY_PATH}" | head -n 1)"
FIRST_SIGNER_MSP="$(jq -r '.organizations[] | select(.active == true) | .mspId' "${REGISTRY_PATH}" | head -n 1)"
FIRST_SIGNER_PORT="$(jq -r '.organizations[] | select(.active == true) | .peerPort' "${REGISTRY_PATH}" | head -n 1)"
set_org_context "${FIRST_SIGNER_MSP}" "${FIRST_SIGNER_DOMAIN}" "${FIRST_SIGNER_PORT}"

peer channel fetch config "${GENERATED_DIR}/config_block.pb" -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com -c "${CHANNEL_NAME}" --tls --cafile "${ORDERER_CA}" >&"${GENERATED_DIR}/fetch_config.log"
configtxlator proto_decode --input "${GENERATED_DIR}/config_block.pb" --type common.Block --output "${GENERATED_DIR}/config_block.json"
jq .data.data[0].payload.data.config "${GENERATED_DIR}/config_block.json" > "${GENERATED_DIR}/config.json"

# Merge the newly generated org definition into the current Application group without recreating the channel.
jq -s --arg mspId "${MSP_ID}" \
  '.[0] * {"channel_group":{"groups":{"Application":{"groups": {($mspId):.[1]}}}}}' \
  "${GENERATED_DIR}/config.json" "${ORG_BASE_DIR}/org-definition.json" > "${GENERATED_DIR}/modified_config.json"

configtxlator proto_encode --input "${GENERATED_DIR}/config.json" --type common.Config --output "${GENERATED_DIR}/original_config.pb"
configtxlator proto_encode --input "${GENERATED_DIR}/modified_config.json" --type common.Config --output "${GENERATED_DIR}/modified_config.pb"
configtxlator compute_update --channel_id "${CHANNEL_NAME}" --original "${GENERATED_DIR}/original_config.pb" --updated "${GENERATED_DIR}/modified_config.pb" --output "${GENERATED_DIR}/org_update.pb"
configtxlator proto_decode --input "${GENERATED_DIR}/org_update.pb" --type common.ConfigUpdate --output "${GENERATED_DIR}/org_update.json"
echo "{\"payload\":{\"header\":{\"channel_header\":{\"channel_id\":\"${CHANNEL_NAME}\",\"type\":2}},\"data\":{\"config_update\":$(cat "${GENERATED_DIR}/org_update.json")}}}" | jq . > "${GENERATED_DIR}/org_update_in_envelope.json"
configtxlator proto_encode --input "${GENERATED_DIR}/org_update_in_envelope.json" --type common.Envelope --output "${GENERATED_DIR}/org_update_in_envelope.pb"

infoln "Collecting channel update signatures from active organizations"
sign_with_current_orgs

set_org_context "${FIRST_SIGNER_MSP}" "${FIRST_SIGNER_DOMAIN}" "${FIRST_SIGNER_PORT}"
peer channel update -f "${GENERATED_DIR}/org_update_in_envelope.pb" -c "${CHANNEL_NAME}" -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile "${ORDERER_CA}" >&"${GENERATED_DIR}/channel_update.log"

infoln "Fetching latest channel block for ${PEER_HOST}"
set_org_context "${MSP_ID}" "${DOMAIN}" "${PEER_PORT}"
peer channel fetch 0 "${GENERATED_DIR}/${CHANNEL_NAME}.block" -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com -c "${CHANNEL_NAME}" --tls --cafile "${ORDERER_CA}" >&"${GENERATED_DIR}/fetch_block.log"

JOIN_SUCCESS="false"
for attempt in 1 2 3 4 5; do
  if peer channel join -b "${GENERATED_DIR}/${CHANNEL_NAME}.block" >&"${GENERATED_DIR}/join.log"; then
    JOIN_SUCCESS="true"
    break
  fi

  if grep -Eq "LedgerID already exists|ledger \\[.*\\] already exists with state \\[ACTIVE\\]" "${GENERATED_DIR}/join.log"; then
    JOIN_SUCCESS="true"
    break
  fi

  sleep 3
done

if [[ "${JOIN_SUCCESS}" != "true" ]]; then
  cat "${GENERATED_DIR}/join.log"
  fatalln "Unable to join ${PEER_HOST} to channel ${CHANNEL_NAME}"
fi

infoln "Setting anchor peer for ${MSP_ID}"
create_anchor_peer_update

ORDERER_PEM_ESCAPED="$(one_line_pem "${ORDERER_CA}")"
PEER_PEM_ESCAPED="$(one_line_pem "${ORG_BASE_DIR}/tlsca/tlsca.${DOMAIN}-cert.pem")"
ORDERER_PEM_YAML="$(indented_pem "${ORDERER_CA}")"
PEER_PEM_YAML="$(indented_pem "${ORG_BASE_DIR}/tlsca/tlsca.${DOMAIN}-cert.pem")"

sed \
  -e "s|__MSP_ID__|${MSP_ID}|g" \
  -e "s|__PEER_HOST__|${PEER_HOST}|g" \
  -e "s|__PEER_PORT__|${PEER_PORT}|g" \
  -e "s|__ORDERER_PEM__|${ORDERER_PEM_ESCAPED}|g" \
  -e "s|__PEER_PEM__|${PEER_PEM_ESCAPED}|g" \
  "${TEMPLATES_DIR}/connection-profile-template.json" > "${ORG_BASE_DIR}/connection-${ORG_KEY}.json"

sed \
  -e "s|__MSP_ID__|${MSP_ID}|g" \
  -e "s|__PEER_HOST__|${PEER_HOST}|g" \
  -e "s|__PEER_PORT__|${PEER_PORT}|g" \
  -e "s|__ORDERER_PEM_YAML__|${ORDERER_PEM_YAML//$'\n'/\\n}|g" \
  -e "s|__PEER_PEM_YAML__|${PEER_PEM_YAML//$'\n'/\\n}|g" \
  "${TEMPLATES_DIR}/connection-profile-template.yaml" | sed -e $'s/\\n/\n/g' > "${ORG_BASE_DIR}/connection-${ORG_KEY}.yaml"

update_registry

RESULT_JSON="$(mktemp)"
jq -n \
  --arg bankId "${BANK_ID}" \
  --arg channelName "${CHANNEL_NAME}" \
  --arg mspId "${MSP_ID}" \
  --arg orgName "${ORG_NAME}" \
  --arg domain "${DOMAIN}" \
  --arg peerHost "${PEER_HOST}" \
  --arg orgDefinitionJson "${ORG_BASE_DIR}/org-definition.json" \
  --arg connectionProfileJson "${ORG_BASE_DIR}/connection-${ORG_KEY}.json" \
  --arg connectionProfileYaml "${ORG_BASE_DIR}/connection-${ORG_KEY}.yaml" \
  --arg composeFile "${GENERATED_DIR}/compose-org.yaml" \
  --arg dockerComposeFile "${GENERATED_DIR}/docker-compose-org.yaml" \
  --argjson peerPort "${PEER_PORT}" \
  --argjson chaincodePort "${CHAINCODE_PORT}" \
  --argjson operationsPort "${OPERATIONS_PORT}" \
  '{
    success: true,
    bankId: $bankId,
    channelName: $channelName,
    mspId: $mspId,
    orgName: $orgName,
    domain: $domain,
    peerHost: $peerHost,
    peerPort: $peerPort,
    chaincodePort: $chaincodePort,
    operationsPort: $operationsPort,
    orgDefinitionJson: $orgDefinitionJson,
    connectionProfileJson: $connectionProfileJson,
    connectionProfileYaml: $connectionProfileYaml,
    composeFile: $composeFile,
    dockerComposeFile: $dockerComposeFile
  }' > "${RESULT_JSON}"

if [[ -n "${OUTPUT_JSON}" ]]; then
  mkdir -p "$(dirname "${OUTPUT_JSON}")"
  cp "${RESULT_JSON}" "${OUTPUT_JSON}"
fi

cat "${RESULT_JSON}"
rm -f "${RESULT_JSON}"

successln "${MSP_ID} successfully added to channel ${CHANNEL_NAME} without restarting the network"
