#!/usr/bin/env bash
# Starts one node of the local 3-node swarm. Run each in its own terminal:
#   scripts/node.sh a    scripts/node.sh b    scripts/node.sh c
set -euo pipefail
. "$(dirname "$0")/env.sh"

name=${1:?usage: scripts/node.sh <a|b|c>}
export SWARM_PEERS=${SWARM_PEERS:-a,b,c}

# Each node serves /metrics on its own port, since they share this machine.
case "$name" in
  a) port=9568 ;; b) port=9569 ;; c) port=9570 ;; *) port=0 ;;
esac
export SWARM_METRICS_PORT=${SWARM_METRICS_PORT:-$port}

exec iex --sname "$name" -S mix
