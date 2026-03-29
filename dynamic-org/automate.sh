#!/usr/bin/env bash

# automate.sh - Entry point for bank organization onboarding
# Triggered by BetweenNetwork backend on admin approval of a bank registration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NETWORK_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHANNEL_NAME="${FABRIC_CHANNEL_NAME:-betweennetwork}"

echo "--- Starting BetweenNetwork Onboarding Automation ---"
echo "Target Channel: ${CHANNEL_NAME}"

# 1. Verify Channel is Up
# We check if we can fetch the genesis block or query the channel from a known peer (Org1)
export PATH="${TEST_NETWORK_HOME}/../bin:${TEST_NETWORK_HOME}:$PATH"
export FABRIC_CFG_PATH="${TEST_NETWORK_HOME}/../config"

# Set context to Org1 (BetweenMSP) to verify channel
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="BetweenMSP"
export CORE_PEER_TLS_ROOTCERT_FILE="${TEST_NETWORK_HOME}/organizations/peerOrganizations/betweenorganization.example.com/tlsca/tlsca.betweenorganization.example.com-cert.pem"
export CORE_PEER_MSPCONFIGPATH="${TEST_NETWORK_HOME}/organizations/peerOrganizations/betweenorganization.example.com/users/Admin@betweenorganization.example.com/msp"
export CORE_PEER_ADDRESS="localhost:7051"

echo "Checking if channel '${CHANNEL_NAME}' is active..."
if ! peer channel list | grep -q "${CHANNEL_NAME}"; then
    echo "ERROR: Channel '${CHANNEL_NAME}' is not active or Peer is unreachable."
    echo "Please ensure the baseline network is deployed first using ./deploy.script.sh"
    exit 1
fi

echo "Channel is active. Proceeding with organization provisioning..."

# 2. Delegate to onboard-bank-org.sh
# This script handles MSP generation, Config update, Peer startup, and Channel Join.
bash "${SCRIPT_DIR}/onboard-bank-org.sh" "$@"

echo "--- Onboarding Automation Successful ---"
