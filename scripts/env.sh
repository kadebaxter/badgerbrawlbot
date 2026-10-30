# Sourced by the other scripts: exports everything in .env, if there is one.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
