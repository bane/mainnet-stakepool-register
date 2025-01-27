#!/bin/bash
set -e

NETWORK_NAME=$1
WALLET_NAME=$2

if [ "$NETWORK_NAME" == "mainnet" ]; then
  MAGIC="--mainnet"
elif [ "$NETWORK_NAME" == "testnet" ]; then
  MAGIC="--testnet-magic 3311"
else
  echo "The network $NETWORK_NAME is not supported"
  exit 1
fi

# Wait node to synchronize
while true; do

  SYNC_STATUS=$(../bin/cardano-cli query tip $MAGIC --socket-path ../ipc/node.socket | jq -r '.syncProgress')

  if [ "$SYNC_STATUS" == "100.00" ]; then
    echo "Synchronization is complete"
    break
  else
    echo "Synchronization progress: $SYNC_STATUS%"
    sleep 10
  fi

done

# Generate keys, certificates, addresses...
echo "Start generating keys"

../bin/cardano-cli node key-gen-KES --verification-key-file ${WALLET_NAME}.kes.vkey --signing-key-file ${WALLET_NAME}.kes.skey
echo "Generated KES keys"

../bin/cardano-cli node key-gen --cold-verification-key-file ${WALLET_NAME}.node.vkey --cold-signing-key-file ${WALLET_NAME}.node.skey --operational-certificate-issue-counter ${WALLET_NAME}.node.counter
echo "Generated node cold keys and counter"

# Get current slot
CURRENT_SLOT=$(../bin/cardano-cli query tip $MAGIC --socket-path ../ipc/node.socket | jq -r '.slot')
echo "Current Slot: $CURRENT_SLOT"

# Determine slots per KES period
SLOTS_PER_KES_PERIOD=$(cat ../node/genesis/shelley/genesis.json | jq -r '.slotsPerKESPeriod')
echo "Slots Per KES Period: $SLOTS_PER_KES_PERIOD"

# Calculate KES period
START_KES_PERIOD=$((CURRENT_SLOT / SLOTS_PER_KES_PERIOD))
echo "Start KES Period: $START_KES_PERIOD"

# Generate operational certificate
../bin/cardano-cli node issue-op-cert --kes-verification-key-file ${WALLET_NAME}.kes.vkey --cold-signing-key-file ${WALLET_NAME}.node.skey --operational-certificate-issue-counter ${WALLET_NAME}.node.counter --kes-period $START_KES_PERIOD --out-file ${WALLET_NAME}.node.cert
echo "Generated node operational certificate"

../bin/cardano-cli node key-gen-VRF --verification-key-file ${WALLET_NAME}.vrf.vkey --signing-key-file ${WALLET_NAME}.vrf.skey
echo "Generated node VRF keys"

# Generate payment keys and stake keys
# Already created using 'wallet.sh'

../bin/cardano-cli stake-address registration-certificate --stake-verification-key-file ${WALLET_NAME}.stake.vkey --out-file ${WALLET_NAME}.stake.cert
echo "Generated stake address registration certificate"

# Change permissions
find `pwd` -type f -exec chmod 600 {} +
