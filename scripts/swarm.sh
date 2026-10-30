#!/usr/bin/env bash
# Control the swarm running in the cluster, from any machine with kubectl access to it:
#
#   scripts/swarm.sh play balanced rusher   # one match against these house bots (default: sitter)
#   scripts/swarm.sh play 3 balanced        # three matches
#   scripts/swarm.sh status                 # leader, league, match, units per node
#   scripts/swarm.sh enemies                # what the leader knows of the enemy armies
#   scripts/swarm.sh stop                   # no more matches after the current one
#   scripts/swarm.sh join season-week3      # play a league match, round after round (name or id)
#   scripts/swarm.sh leave                  # no more league rounds after this one
#   scripts/swarm.sh join-match <id>        # take a seat in someone's match, play it when it fills
#   scripts/swarm.sh host 6 [--name kaden-brawl] [house bots...]   # host a match others join
#   scripts/swarm.sh unhost                 # give up our seat before it starts (joined or hosted)
#   scripts/swarm.sh shell                  # an iex on a swarm node (leave with Ctrl+C, a)
#   scripts/swarm.sh logs                   # follow the leader's log
#
# It runs Swarm.* (lib/swarm.ex) on one of the pods; those go through ra, so any pod will do.
set -euo pipefail

ns=${SWARM_NAMESPACE:-netrts}

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

# A running swarm pod.
pod() {
  local p
  p=$(kubectl -n "$ns" get pods -l app=swarm --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n $p ]] || { echo "no running swarm pod in namespace $ns" >&2; exit 1; }
  echo "$p"
}

rpc() { kubectl -n "$ns" exec "$(pod)" -- bin/swarm rpc "$1"; }

# Names go into an Elixir expression, so only plain ones.
name() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || { echo "not a valid name: $1" >&2; exit 1; }
  echo "$1"
}

cmd=${1:-}
[[ -n $cmd ]] || usage
shift

case "$cmd" in
  play)
    n=1
    if [[ ${1:-} =~ ^[0-9]+$ ]]; then n=$1; shift; fi
    bots=()
    for b in "${@:-sitter}"; do bots+=("\"$(name "$b")\""); done
    list=$(IFS=,; echo "${bots[*]}")
    rpc "Swarm.play($n, opponents: [$list])"
    echo "asked for $n match(es) against ${*:-sitter}; the leader's log has the Watch link (scripts/swarm.sh logs)"
    ;;
  status) rpc 'Swarm.status()' ;;
  enemies) rpc 'Swarm.enemies()' ;;
  stop) rpc 'Swarm.stop()' ;;
  join) rpc "Swarm.join(\"$(name "${1:?usage: join <league match name>}")\")" ;;
  leave) rpc 'Swarm.leave()' ;;
  join-match)
    id=${1:?usage: join-match <match id>}
    [[ $id =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
      { echo "not a match id: $id" >&2; exit 1; }
    rpc "IO.inspect(Swarm.join_match(\"$id\"))"
    ;;
  host)
    seats=${1:?usage: host <seats> [--name NAME] [house bots...]}
    [[ $seats =~ ^[0-9]+$ ]] || { echo "seats must be a number: $seats" >&2; exit 1; }
    shift
    opts=""
    if [[ ${1:-} == --name ]]; then opts=", name: \"$(name "${2:?--name needs a name}")\""; shift 2; fi
    bots=()
    for b in "$@"; do bots+=("\"$(name "$b")\""); done
    list=$(IFS=,; echo "${bots[*]}")
    rpc "IO.inspect(Swarm.host($seats, bots: [$list]$opts))"
    echo "the leader's log has the match id and how others join (scripts/swarm.sh logs)"
    ;;
  unhost | leave-match) rpc 'IO.inspect(Swarm.leave_match())' ;;
  shell) kubectl -n "$ns" exec -it "$(pod)" -- bin/swarm remote ;;
  logs)
    leader=$(kubectl -n "$ns" exec "$(pod)" -- bin/swarm rpc \
      'case Swarm.Ra.members() do {:ok, _, {_, n}} -> IO.puts(n |> to_string() |> String.split(["@", "."]) |> Enum.at(1)); _ -> :ok end')
    [[ -n $leader ]] || { echo "no leader right now" >&2; exit 1; }
    echo "following $leader (the leader)" >&2
    kubectl -n "$ns" logs -f "$leader"
    ;;
  *) usage ;;
esac
