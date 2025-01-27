#!/bin/bash
set -e

NETWORK_NAME=$1
WALLET_NAME=$2

if [ "$NETWORK_NAME" == "mainnet" ]; then
  NETWORK=1
  MAGIC="--mainnet"
  BATCH32_FIX="addr"
elif [ "$NETWORK_NAME" == "testnet" ]; then
  NETWORK=0
  MAGIC="--testnet-magic 3311"
  BATCH32_FIX="addr_test"
else
  echo "The network $NETWORK_NAME is not supported"
  exit 1
fi

# create recovery phrases (mnemonic)
../bin/cardano-wallet recovery-phrase generate --size 24 > ${WALLET_NAME}.mnemonic.private

# split the mnemonic into words and count them
MNEMONIC_WORD_COUNT=$(cat ${WALLET_NAME}.mnemonic.private | wc -w)
if [ "$MNEMONIC_WORD_COUNT" -ne 24 ]; then
    echo "The mnemonic does not have exactly 24 words. It has $MNEMONIC_WORD_COUNT words."
    exit 1
fi

# create extended root private key from the mnemonic
cat ${WALLET_NAME}.mnemonic.private | ../bin/cardano-wallet key from-recovery-phrase Shelley > ${WALLET_NAME}.root.xprivate

# create extended payment, stake, and change keys
cat ${WALLET_NAME}.root.xprivate | IDX=0 ../bin/cardano-address key child 1852H/1815H/0H/0/0 > ${WALLET_NAME}.payment.xprivate
cat ${WALLET_NAME}.root.xprivate | ../bin/cardano-address key child 1852H/1815H/0H/2/0 > ${WALLET_NAME}.stake.xprivate
cat ${WALLET_NAME}.root.xprivate | ../bin/cardano-address key child 1852H/1815H/0H/1/0 > ${WALLET_NAME}.change.xprivate

# create public extended keys from private
cat ${WALLET_NAME}.payment.xprivate | ../bin/cardano-address key public --with-chain-code > ${WALLET_NAME}.payment.xpublic
cat ${WALLET_NAME}.stake.xprivate | ../bin/cardano-address key public --with-chain-code > ${WALLET_NAME}.stake.xpublic
cat ${WALLET_NAME}.change.xprivate | ../bin/cardano-address key public --with-chain-code > ${WALLET_NAME}.change.xpublic

# convert to regular private and public keys
cat ${WALLET_NAME}.payment.xpublic | ../bin/cardano-address address payment --network-tag $NETWORK > ${WALLET_NAME}.candidate.addr
cat ${WALLET_NAME}.candidate.addr | ../bin/cardano-address address delegation $(cat ${WALLET_NAME}.stake.xpublic) > ${WALLET_NAME}.payment.candidate.addr
cat ${WALLET_NAME}.payment.candidate.addr | ../bin/bech32 | ../bin/bech32 $BATCH32_FIX > ${WALLET_NAME}.payment.candidate.addr.fixed
mv ${WALLET_NAME}.payment.candidate.addr.fixed ${WALLET_NAME}.payment.candidate.addr

# convert extended signing keys to corresponding Shelley format keys
../bin/cardano-cli key convert-cardano-address-key --shelley-payment-key --signing-key-file ${WALLET_NAME}.payment.xprivate --out-file ${WALLET_NAME}.payment.skey
../bin/cardano-cli key convert-cardano-address-key --shelley-stake-key --signing-key-file ${WALLET_NAME}.stake.xprivate --out-file ${WALLET_NAME}.stake.skey

# get extended verification keys from signing keys
../bin/cardano-cli key verification-key --signing-key-file ${WALLET_NAME}.payment.skey --verification-key-file ${WALLET_NAME}.payment.evkey
../bin/cardano-cli key verification-key --signing-key-file ${WALLET_NAME}.stake.skey --verification-key-file ${WALLET_NAME}.stake.evkey

# get non-extended verification keys from extended verification keys
../bin/cardano-cli key non-extended-key --extended-verification-key-file ${WALLET_NAME}.payment.evkey --verification-key-file ${WALLET_NAME}.payment.vkey
../bin/cardano-cli key non-extended-key --extended-verification-key-file ${WALLET_NAME}.stake.evkey --verification-key-file ${WALLET_NAME}.stake.vkey

# build payment and stake addresses
../bin/cardano-cli address build --payment-verification-key-file ${WALLET_NAME}.payment.vkey $MAGIC --out-file ${WALLET_NAME}.payment-only.addr
../bin/cardano-cli address build --payment-verification-key-file ${WALLET_NAME}.payment.vkey $MAGIC --stake-verification-key-file ${WALLET_NAME}.stake.vkey --out-file ${WALLET_NAME}.base.addr
../bin/cardano-cli stake-address build --stake-verification-key-file ${WALLET_NAME}.stake.vkey $MAGIC --out-file ${WALLET_NAME}.stake.addr

# candidate.addr and payment-only.addr must match!
if [ "$(cat ${WALLET_NAME}.candidate.addr)" != "$(cat ${WALLET_NAME}.payment-only.addr)" ]; then
    echo "Error: candidate.addr and payment-only.addr does not match"
    exit 1
else
  # base.addr and payment.candidate.addr must match!
  if [ "$(cat ${WALLET_NAME}.base.addr)" != "$(cat ${WALLET_NAME}.payment.candidate.addr)" ]; then
      echo "Error: base.addr and payment.candidate.addr does not match"
      exit 1
  fi
fi

mv ${WALLET_NAME}.base.addr ${WALLET_NAME}.payment.addr
echo "Payment Address: $(cat ${WALLET_NAME}.payment.addr)"

# Change permissions
find `pwd` -type f -exec chmod 600 {} +
