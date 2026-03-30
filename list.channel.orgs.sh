#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FABRIC_SAMPLES_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_NETWORK_DIR="${TEST_NETWORK_DIR:-${FABRIC_SAMPLES_DIR}/test-network}"
CHANNEL_NAME="${CHANNEL_NAME:-betweennetwork}"

cd "${TEST_NETWORK_DIR}"

export PATH="${PWD}/../bin:${PWD}:$PATH"
export FABRIC_CFG_PATH="${PWD}/../config/"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="BetweenMSP"
export CORE_PEER_TLS_ROOTCERT_FILE="${PWD}/organizations/peerOrganizations/betweenorganization.example.com/peers/peer0.betweenorganization.example.com/tls/ca.crt"
export CORE_PEER_MSPCONFIGPATH="${PWD}/organizations/peerOrganizations/betweenorganization.example.com/users/Admin@betweenorganization.example.com/msp"
export CORE_PEER_ADDRESS="localhost:7051"

ORDERER_CA="${PWD}/organizations/ordererOrganizations/example.com/tlsca/tlsca.example.com-cert.pem"
BLOCK_FILE="/tmp/${CHANNEL_NAME}_config_block.pb"
BLOCK_JSON="/tmp/${CHANNEL_NAME}_config_block.json"

if ! command -v peer >/dev/null 2>&1; then
  echo "peer binary not found"
  exit 1
fi

if ! command -v configtxlator >/dev/null 2>&1; then
  echo "configtxlator binary not found"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq binary not found"
  exit 1
fi

echo "Fetching channel config for ${CHANNEL_NAME}..."
peer channel fetch config "${BLOCK_FILE}" \
  -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  -c "${CHANNEL_NAME}" \
  --tls \
  --cafile "${ORDERER_CA}" >/dev/null

configtxlator proto_decode \
  --input "${BLOCK_FILE}" \
  --type common.Block \
  --output "${BLOCK_JSON}"

echo "Organizations present in channel ${CHANNEL_NAME}:"
jq -r '.data.data[0].payload.data.config.channel_group.groups.Application.groups | keys[]' "${BLOCK_JSON}"
