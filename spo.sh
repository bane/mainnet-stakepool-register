#!/bin/bash
set -e

NETWORK_NAME=${1:-testnet}
WALLET_NAME=${2:-testnet.prime.sp01}
METADATA_URL=$3
RELAY_LB=$4
POOL_PLEDGE=${5:-25}
POOL_COST=${6:-15}
POOL_MARGIN=${7:-0.15}

# create dir where all keys will be stored
mkdir $WALLET_NAME && cd $WALLET_NAME
echo "Directory $WALLET_NAME created"

../utils/wallet.sh $NETWORK_NAME $WALLET_NAME
../utils/keys.sh $NETWORK_NAME $WALLET_NAME
../utils/fund.sh $NETWORK_NAME $WALLET_NAME $METADATA_URL $POOL_PLEDGE $POOL_COST
# start one Relay as Block Producer (do we realy need this here, before register script?)
# ../utils/register.sh $NETWORK_NAME $WALLET_NAME $METADATA_URL $RELAY_LB $POOL_PLEDGE $POOL_COST $POOL_MARGIN
