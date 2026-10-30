#!/usr/bin/env bash
# iex with .env loaded but no cluster, no ra and no unit processes: for trying things out.
#   Task.start(&Swarm.Solo.run/0)   plays a match without taking over the shell
set -euo pipefail
. "$(dirname "$0")/env.sh"

SWARM_CLUSTER=false exec iex -S mix
