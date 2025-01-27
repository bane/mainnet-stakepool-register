#!/bin/bash
set -e

NETWORK_NAME=$1
WALLET_NAME=$2
METADATA_URL=$3
RELAY_LB=$4
POOL_PLEDGE=$5
POOL_COST=$6
POOL_MARGIN=$7

if [ "$NETWORK_NAME" == "mainnet" ]; then
  MAGIC="--mainnet"
elif [ "$NETWORK_NAME" == "testnet" ]; then
  MAGIC="--testnet-magic 3311"
else
  echo "The network $NETWORK_NAME is not supported"
  exit 1
fi

# Function: Check transaction confirmation
wait_for_confirmation() {
  local ADDRESS=$1

  echo "Waiting for transaction to be confirmed..."
  local INIT_UTXO=$(../bin/cardano-cli query utxo --address "$ADDRESS" $MAGIC --socket-path ../ipc/node.socket)

  for ((i=0; i<30; i++)); do

    echo "Checking transaction confirmation... ($((i+1))/30)"
    local CURRENT_UTXO=$(../bin/cardano-cli query utxo --address "$ADDRESS" $MAGIC --socket-path ../ipc/node.socket)

    if [[ "$CURRENT_UTXO" != "$INIT_UTXO" ]]; then 
      echo "Transaction confirmed."
      return
    else
      sleep 10
    fi

  done

  echo "Transaction not confirmed after 300 seconds. Please check the transaction manually."

  exit 1
}

# Funcion: Convert APEX to Lovelace (1 APEX = 1 000 000 Lovelace)
apex_to_lovelace() {
  local APEX=$1

  echo "$APEX * 1000000" | bc
}

POOL_PLEDGE_LOVELACE=$(apex_to_lovelace $POOL_PLEDGE)
POOL_COST_LOVELACE=$(apex_to_lovelace $POOL_COST)

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

# Retrieve tx-ins
TX_INS=$(jq -r 'keys[]' ${WALLET_NAME}.utxo.json | awk '{print "--tx-in " $1}' | paste -sd " " -)

# Calculate the amount to send
if (( STAKE_ADDRESS_DEPOSIT > 0 )); then
  SEND_AMOUNT_LOVELACE=$((STAKE_ADDRESS_DEPOSIT + 1000000)) # Stake address deposit + 1 APEX
else
  SEND_AMOUNT_LOVELACE=1000000 # 1 APEX
fi

# Get current slot
CURRENT_SLOT=$(../bin/cardano-cli query tip $MAGIC --socket-path ../ipc/node.socket | jq -r '.slot')
echo "Current Slot: $CURRENT_SLOT"

# Build raw transaction
../bin/cardano-cli transaction build-raw $TX_INS \
  --tx-out $(cat ${WALLET_NAME}.payment.addr)+$SEND_AMOUNT_LOVELACE \
  --tx-out $(cat ${WALLET_NAME}.payment.addr)+$((TOTAL_BALANCE - SEND_AMOUNT_LOVELACE - 200000)) \
  --invalid-hereafter $((CURRENT_SLOT + 10000)) \
  --fee 200000 \
  --certificate ${WALLET_NAME}.stake.cert \
  --out-file ${WALLET_NAME}.tx.raw
echo "Built raw transaction"

# Sign the transaction
../bin/cardano-cli transaction sign \
  --tx-body-file ${WALLET_NAME}.tx.raw \
  --signing-key-file ${WALLET_NAME}.payment.skey \
  --signing-key-file ${WALLET_NAME}.stake.skey \
  $MAGIC \
  --out-file ${WALLET_NAME}.tx.signed
echo "Signed the transaction"

# Submit the transaction and wait for confirmation
../bin/cardano-cli transaction submit \
  --tx-file ${WALLET_NAME}.tx.signed \
  $MAGIC \
  --socket-path ../ipc/node.socket

wait_for_confirmation $(cat ${WALLET_NAME}.payment.addr)
echo "Registered stake address on blockchain"

# Generate pool registration certificate
../bin/cardano-cli stake-pool registration-certificate \
  --cold-verification-key-file ${WALLET_NAME}.node.vkey \
  --vrf-verification-key-file ${WALLET_NAME}.vrf.vkey \
  --pool-pledge $POOL_PLEDGE_LOVELACE \
  --pool-cost $POOL_COST_LOVELACE \
  --pool-margin $POOL_MARGIN \
  --pool-reward-account-verification-key-file ${WALLET_NAME}.stake.vkey \
  --pool-owner-stake-verification-key-file ${WALLET_NAME}.stake.vkey \
  $MAGIC \
  --single-host-pool-relay $RELAY_LB \
  --pool-relay-port 5521 \
  --metadata-url $METADATA_URL \
  --metadata-hash $METADATA_HASH \
  --out-file ${WALLET_NAME}.pool.cert
echo "Generated pool registration certificate"

# Generate delegation certificate
../bin/cardano-cli stake-address delegation-certificate \
  --stake-verification-key-file ${WALLET_NAME}.stake.vkey \
  --cold-verification-key-file ${WALLET_NAME}.node.vkey \
  --out-file ${WALLET_NAME}.deleg.cert
echo "Generated delegation certificate"

# Get current slot
CURRENT_SLOT=$(../bin/cardano-cli query tip $MAGIC --socket-path ../ipc/node.socket | jq -r '.slot')
echo "Current Slot: $CURRENT_SLOT"

# Check payment address balance
../bin/cardano-cli query utxo \
  --address "`cat ${WALLET_NAME}.payment.addr`" \
  $MAGIC \
  --socket-path ../ipc/node.socket \
  --out-file ${WALLET_NAME}.utxo.json

# Retrieve tx-ins
TX_INS=$(jq -r 'keys[]' ${WALLET_NAME}.utxo.json | awk '{print "--tx-in " $1}' | paste -sd " " -)

# Calculate total balance
TOTAL_BALANCE=$(jq -r '[.[] | .value.lovelace] | add' ${WALLET_NAME}.utxo.json)
echo "Total Balance: $TOTAL_BALANCE"

# Build raw transaction
../bin/cardano-cli transaction build-raw $TX_INS \
  --tx-out $(cat ${WALLET_NAME}.payment.addr)+$POOL_PLEDGE_LOVELACE \
  --tx-out $(cat ${WALLET_NAME}.payment.addr)+$((TOTAL_BALANCE - POOL_PLEDGE_LOVELACE - 200000)) \
  --invalid-hereafter $((CURRENT_SLOT + 10000)) \
  --fee 200000 \
  --certificate-file ${WALLET_NAME}.pool.cert \
  --certificate-file ${WALLET_NAME}.deleg.cert \
  --out-file ${WALLET_NAME}.tx-pledge.raw

if ! test -f "${WALLET_NAME}.tx-pledge.raw"; then
  echo "Failed to create tx-pledge.raw file"
  exit 1
else
  echo "Built pledge raw transaction"
fi

# Sign the transaction
../bin/cardano-cli transaction sign \
  --tx-body-file ${WALLET_NAME}.tx-pledge.raw \
  --signing-key-file ${WALLET_NAME}.payment.skey \
  --signing-key-file ${WALLET_NAME}.node.skey \
  --signing-key-file ${WALLET_NAME}.stake.skey \
  $MAGIC \
  --out-file ${WALLET_NAME}.tx-pledge.signed

if ! test -f "${WALLET_NAME}.tx-pledge.signed"; then
  echo "Failed to create tx-pledge.signed file"
  exit 1
else
  echo "Signed the transaction"
fi

# !!! WARNING: Proceed with caution regarding any further actions !!!
echo "Proceed with caution regarding any further actions (press any key to continue)"
read -n 1 -s

# Submit the transaction
../bin/cardano-cli transaction submit \
  --tx-file ${WALLET_NAME}.tx-pledge.signed \
  $MAGIC \
  --socket-path ../ipc/node.socket
echo "Submitted the pool registration transaction"

# Wait for confirmation
echo "Waiting for confirmation"
wait_for_confirmation $(cat ${WALLET_NAME}.payment.addr)

# Get stake pool ID if not already retrieved
../bin/cardano-cli stake-pool id --cold-verification-key-file ${WALLET_NAME}.node.vkey --output-format hex > ${WALLET_NAME}.pool-id.txt
echo "Retrieved hex stake pool ID: `(cat ${WALLET_NAME}.pool-id.txt)`"

POOL_ID_HEX=$(cat ${WALLET_NAME}.pool-id.txt)
POOL_ID_BASE64=$(echo -n $POOL_ID_HEX | xxd -r -p | base64)
echo "Congratulations, this is your new stake pool registered - $POOL_ID_BASE64"

# Check stake pool registration
../bin/cardano-cli query stake-snapshot \
  --stake-pool-id $POOL_ID_HEX \
  $MAGIC \
  --socket-path ../ipc/node.socket
echo "Checked stake pool registration"

# Change permissions
find `pwd` -type f -exec chmod 600 {} +
