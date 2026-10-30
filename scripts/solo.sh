#!/usr/bin/env bash
# Plays one match with the non-distributed bot (no cluster, no ra, no unit processes).
set -euo pipefail
. "$(dirname "$0")/env.sh"

exec mix swarm.solo
