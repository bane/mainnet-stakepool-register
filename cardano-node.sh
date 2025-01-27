rm -rf ./ipc
mkdir ./ipc

./bin/cardano-node run --topology ./node/topology.json \
  --database-path ./data/db \
  --socket-path ./ipc/node.socket \
  --non-producing-node \
  --port 5521 \
  --config ./node/configuration.yaml
