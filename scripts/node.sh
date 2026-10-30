#!/usr/bin/env bash
# Starts one node of the local 3-node swarm. Run each in its own terminal:
#   scripts/node.sh a    scripts/node.sh b    scripts/node.sh c
set -euo pipefail
. "$(dirname "$0")/env.sh"

name=${1:?usage: scripts/node.sh <a|b|c>}
export SWARM_PEERS=${SWARM_PEERS:-a,b,c}

exec iex --sname "$name" -S mix
