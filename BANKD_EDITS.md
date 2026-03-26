# BankD Organization Changes

This document lists the files edited to add the `BankD` organization to the Fabric test network.

## 1. Channel configuration

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/configtx/configtx.yaml`

**What was edited:**
- Added a new organization definition named `BankDOrg`
- Set `Name` and `ID` to `BankDMSP`
- Set MSP directory to `../organizations/peerOrganizations/bankd.example.com/msp`
- Added `Readers`, `Writers`, `Admins`, and `Endorsement` policies for `BankDMSP`
- Added `BankDOrg` to the `Profiles -> ChannelUsingRaft -> Application -> Organizations` list

## 2. Crypto material definition

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/organizations/cryptogen/crypto-config-bankd.yaml`

**What was edited:**
- Created a new cryptogen configuration file for `BankD`
- Set organization domain to `bankd.example.com`
- Enabled `NodeOUs`
- Configured one peer with `Template -> Count: 1`
- Configured one additional user with `Users -> Count: 1`

## 3. Network startup script

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/network.sh`

**What was edited:**
- Added a new `cryptogen generate` step inside `createOrgs()`
- Configured the script to generate certificates using:
  `./organizations/cryptogen/crypto-config-bankd.yaml`
- Added log output line: `Creating BankD Identities`

## 4. Docker Compose peer service

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/compose/compose-test-net.yaml`

**What was edited:**
- Added a named Docker volume:
  `peer0.bankd.example.com`
- Added a new peer service:
  `peer0.bankd.example.com`
- Set MSP ID to `BankDMSP`
- Mounted peer crypto material from:
  `../organizations/peerOrganizations/bankd.example.com/peers/peer0.bankd.example.com`
- Assigned peer ports:
  `12051` for peer communication
  `12052` for chaincode communication
  `9448` for operations/metrics










**Why this was edited:**
- To start the `BankD` peer container as part of the Fabric network
- To mount the generated crypto material into the peer container
- To give `BankD` its own non-conflicting ports

## 5. Peer org environment mapping

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/scripts/envVar.sh`

**What was edited:**
- Added `PEER0_BANKD_CA` environment variable
- Added `BankD` to `setGlobals()` as organization `4`
- Set:
  `CORE_PEER_LOCALMSPID=BankDMSP`
  `CORE_PEER_TLS_ROOTCERT_FILE` for `BankD`
  `CORE_PEER_MSPCONFIGPATH` for `Admin@bankd.example.com`
  `CORE_PEER_ADDRESS=localhost:12051`
- Updated `parsePeerConnectionParameters()` to support `BankD`

**Why this was edited:**
- To allow Fabric scripts to run peer commands in the context of `BankD`
- To allow channel join, anchor peer, and chaincode commands to use BankD's MSP and TLS settings
- To make `BankD` available in shared script logic the same way as the existing organizations

## 6. Channel join script

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/scripts/createChannel.sh`

**What was edited:**
- Added `BankD` label handling in `joinChannel()`
- Added:
  `joinChannel 4`
- Added anchor peer step:
  `setAnchorPeer 4`

**Why this was edited:**
- To make the `BankD` peer join the channel after channel creation
- To include `BankD` in the same automated channel setup flow as Between, Bank1, and Bank2
- To prepare the script for anchor peer updates for `BankD`








## 7. Chaincode deployment script

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/scripts/deployCC.sh`

**What was edited:**
- Corrected Bank2 organization number from `4` to `3`
- Added chaincode install step for `BankD` using org `4`
- Added approval step for `BankD` using org `4`
- Updated install messages to match the real organization names used in this network
- Updated commit readiness checks to use:
  `BetweenMSP`
  `Bank1MSP`
  `Bank2MSP`
  `BankDMSP`
- Updated chaincode commit to use all four orgs:
  `commitChaincodeDefinition 1 2 3 4`
- Updated committed definition query to check all four orgs
- Updated init invoke flow to use all four orgs:
  `chaincodeInvokeInit 1 2 3 4`

**Why this was edited:**
- To keep organization numbering consistent across scripts
- To allow `BankD` to install chaincode packages
- To allow `BankD` to approve chaincode definitions when using the deployment script
- To make the deploy script work with the actual MSP names in this customized network
- To make chaincode commit and initialization run across all four organizations instead of the old sample network flow





## 8. Anchor peer update script

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/scripts/setAnchorPeer.sh`

**What was edited:**
- Replaced old peer host mappings that still pointed to:
  `peer0.org1.example.com`
  `peer0.org2.example.com`
  `peer0.org3.example.com`
- Updated host mappings to:
  `peer0.betweenorganization.example.com`
  `peer0.bank1organization.example.com`
  `peer0.bank2.example.com`
  `peer0.bankd.example.com`
- Added `BankD` support as organization `4`
- Set BankD anchor peer port to `12051`

**Why this was edited:**
- To make anchor peer updates use the correct peer hostnames for the current organizations
- To prevent anchor peer update failures caused by outdated org1/org2/org3 hostnames
- To include `BankD` in the anchor peer setup flow

## 9. BankD changes summary document

**File path:** `/home/ronithpatel/fabric/fabric-samples/test-network/BANKD_EDITS.md`

**What was edited:**
- Created this documentation file
- Listed the files changed for `BankD`
- Added explanation of what was changed and why

**Why this was edited:**
- To provide a single reference document showing all `BankD` changes
- To make it easier to review or explain the modifications later

## 10. BetweenNetwork deploy wrapper

**File path:** `/home/ronithpatel/fabric/fabric-samples/betweennetwork/deploy.script.sh`

**What was edited:**
- Added stale Docker volume cleanup for:
  `peer0.bankd.example.com`
- Added stale Docker network cleanup for:
  `fabric_test`
- Added cleanup of generated folders and channel artifacts before network startup
- Added MSP admincert population for:
  `bankd.example.com`
- Added `BANKD_PEER=localhost:12051`
- Added `BANKD_TLS` path for `peer0.bankd.example.com`
- Added `BANKD_ADMIN` path for `Admin@bankd.example.com`
- Updated deploy summary output to include `BankDMSP`
- Added `bankd` support in `set_peer_globals()`
- Added chaincode install flow for `BankD`
- Added approval flow for `BankD`
- Updated the commit command to include:
  `peer0.bankd.example.com:12051`
- Changed network startup from:
  `./network.sh up -ca -i "${IMAGE_TAG}"`
  to:
  `./network.sh up -i "${IMAGE_TAG}"`

**Why this was edited:**
- Because the actual wrapper script used for deployment was still configured for only three organizations
- To make the deploy wrapper work with `Between`, `Bank1`, `Bank2`, and `BankD`
- To ensure `BankD` participates in install, approval, and commit operations during chaincode deployment
- To avoid CA-mode startup, because `BankD` was added in the cryptogen flow and not in the Fabric CA enrollment flow
- To ensure fresh crypto material and channel artifacts are generated before deployment

## Notes

- No changes were made directly to generated files such as:
  `/home/ronithpatel/fabric/fabric-samples/test-network/channel-artifacts/betweennetwork.block`
- After these config changes, the network must be restarted and artifacts regenerated for `BankD` to appear in the running network.



./network.sh down

rm -rf organizations/peerOrganizations organizations/ordererOrganizations channel-artifacts/*.block channel-artifacts/*.tx channel-artifacts/*.json channel-artifacts/*.pb

./network.sh up createChannel



find organizations/peerOrganizations/bankd.example.com -maxdepth 3 -type d
docker ps | grep bankd
