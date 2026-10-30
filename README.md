# NetRTS Swarm

A distributed Badger Brawl (NetRTS) bot in Elixir: every game unit is its own process, spread
across three BEAM nodes on separate machines (k3s). The nodes agree on a leader with Raft (`ra`);
the leader talks to the game server and sets strategy, and each unit decides for itself.

Design: [docs/design.md](docs/design.md).

## Running locally

Register a bot on the server once by hand, then:

```bash
mix deps.get
cp .env.example .env      # fill in NETRTS_API_KEY; .env is git-ignored
```

Single process, no cluster (the baseline):

```bash
scripts/solo.sh
```

The swarm: three nodes, each in its own terminal.

```bash
scripts/node.sh a
scripts/node.sh b
scripts/node.sh c
```

Once two are up they elect a leader, which starts the match. In any node's `iex`:
`Swarm.status()` shows the leader and the units per node, and `Swarm.play()` plays another match.
`Swarm.play(opponents: ["balanced", "rusher"])` plays a free-for-all against those house bots (one
seat each, up to 15), and keeps them for later matches. `SWARM_OPPONENT=balanced,rusher` in `.env`
sets the default.
Each node keeps its Raft log in `data/<node>/`; stop all nodes and `rm -rf data` to start fresh.

## League matches

League matches (`Preseason`, `Season`, `Championship`) are created by the admins and played in
rounds of heats. On league night, start the nodes with `SWARM_MATCHES=0` in `.env` so the leader
doesn't start a practice match first, then in any node's `iex`:

```elixir
Swarm.join("season-week3")   # the name the admin gave it
Swarm.status()               # league: season-week3
Swarm.leave()                # no more rounds after the current one
```

The leader joins, waits for each round, plays the heat with a fresh brain, and waits again until
the admin closes the match. The league lives in the replicated state, so if the leader's node dies
another node rejoins (joining twice is harmless) and picks up the same heat. If the admin hasn't
created the match yet, the leader keeps looking every 10 s. The bot must be Discord-verified.
