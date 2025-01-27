#!/bin/bash
set -e

NETWORK_NAME=$1
WALLET_NAME=$2
METADATA_URL=$3
POOL_PLEDGE=$4
POOL_COST=$5

if [ "$NETWORK_NAME" == "mainnet" ]; then
  MAGIC="--mainnet"
elif [ "$NETWORK_NAME" == "testnet" ]; then
  MAGIC="--testnet-magic 3311"
else
  echo "The network $NETWORK_NAME is not supported"
  exit 1
fi

# Funcion: Convert APEX to Lovelace (1 APEX = 1 000 000 Lovelace)
apex_to_lovelace() {
  local APEX=$1

  echo "$APEX * 1000000" | bc
}

POOL_PLEDGE_LOVELACE=$(apex_to_lovelace $POOL_PLEDGE)
POOL_COST_LOVELACE=$(apex_to_lovelace $POOL_COST)

# Download the Stake Pool metadata from the provided URL
curl -s $METADATA_URL -o ${WALLET_NAME}.metadata.json

# Check if the metadata file is downloaded successfully
if [ ! -f "${WALLET_NAME}.metadata.json" ]; then
  echo "Failed to download the metadata file from $METADATA_URL"
  exit 1
else
  echo "Downloaded stake pool metadata from $METADATA_URL"
fi

# Generate metadata hash
METADATA_HASH=$(../bin/cardano-cli stake-pool metadata-hash --pool-metadata-file ${WALLET_NAME}.metadata.json | tr -d '\n\r')

# Check if the metadata hash is generated
if [ -z "$METADATA_HASH" ]; then
  echo "Failed to generate Stake Pool metadata hash"
  exit 1
else
  echo "Stake Pool metadata hash: $METADATA_HASH"
  echo "$METADATA_HASH" > ${WALLET_NAME}.metadata-hash.txt
  echo "Stake Pool metadata generated successfully"
fi

# Query protocol parameters and get min pool cost and stake pool deposit
../bin/cardano-cli query protocol-parameters $MAGIC --socket-path ../ipc/node.socket --out-file ${WALLET_NAME}.parameters.json
if [ ! -f "${WALLET_NAME}.parameters.json" ]; then
  echo "Failed to generate parameters.json"
  exit 1
else
  echo "parameters.json generated successfully" 
fi

MIN_POOL_COST=$(cat ${WALLET_NAME}.parameters.json | jq -r .minPoolCost)
echo "MinPoolCost: $MIN_POOL_COST"

STAKE_ADDRESS_DEPOSIT=$(cat ${WALLET_NAME}.parameters.json | jq -r .stakeAddressDeposit)
echo "StakeAddressDeposite: $STAKE_ADDRESS_DEPOSIT"

# Calculate the required funds
REQUIRED_FUNDS_LOVELACE=$((POOL_PLEDGE_LOVELACE + MIN_POOL_COST + STAKE_ADDRESS_DEPOSIT + 2000000)) # Adding an extra 2 APEX for fees
REQUIRED_FUNDS_APEX=$(echo "$REQUIRED_FUNDS_LOVELACE / 1000000" | bc)

# Check payment address balance
../bin/cardano-cli query utxo \
  --address "`cat ${WALLET_NAME}.payment.addr`" \
  $MAGIC \
  --socket-path ../ipc/node.socket \
  --out-file ${WALLET_NAME}.utxo.json

# Calculate total balance and verify sufficient funds
TOTAL_BALANCE=$(jq -r '[.[] | .value.lovelace] | add' ${WALLET_NAME}.utxo.json)
TOTAL_BALANCE_APEX=$(echo "$TOTAL_BALANCE / 1000000" | bc)

if (( TOTAL_BALANCE < REQUIRED_FUNDS_LOVELACE )); then
  echo "Insufficient funds in payment address"
  echo "Required: $REQUIRED_FUNDS_APEX APEX"
  echo "Found: $TOTAL_BALANCE_APEX"
  
  echo "Please fund the address `cat ${WALLET_NAME}.payment.addr`"
  read -p "$(echo Press Enter to continue after funding the address)"
  
  # Check payment address balance, again
  ../bin/cardano-cli query utxo \
    --address "`cat ${WALLET_NAME}.payment.addr`" \
    $MAGIC \
    --socket-path ../ipc/node.socket \
    --out-file ${WALLET_NAME}.utxo.json

  # Calculate total balance and verify sufficient funds, again
  TOTAL_BALANCE=$(jq -r '[.[] | .value.lovelace] | add' ${WALLET_NAME}.utxo.json)
  TOTAL_BALANCE_APEX=$(echo "$TOTAL_BALANCE / 1000000" | bc)

  if (( TOTAL_BALANCE < REQUIRED_FUNDS_LOVELACE )); then
    echo "Still insufficient funds in payment address"
    exit 1
  fi
fi

# Change permissions
find `pwd` -type f -exec chmod 600 {} +
