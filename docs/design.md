# NetRTS Swarm — Design

A distributed Badger Brawl (NetRTS) bot written in Elixir. Every unit in the game is its own
Elixir process. The processes are spread across three BEAM nodes running on different machines,
and they coordinate only by message passing. The three nodes run a Raft cluster with
[`ra`](https://github.com/rabbitmq/ra) (RabbitMQ's Raft library) to agree on a leader and on the
team's shared state. The leader talks to the game server and sets strategy, and each unit decides
what its own unit does.

Status: design only, no code yet.

## Goals

- Every game unit is controlled by its own process, and processes share no memory.
- The system spans several physical machines (3 k3s nodes), so messages really cross a network.
- Consensus on the leader and the team's shared state (match, strategy, last submitted tick)
  through Raft, using `ra`.
- The bot keeps playing when a machine or BEAM node dies: `ra` elects a new leader, and the units
  that lived on the dead node are re-spawned on the survivors.
- Beat `sitter`, then `balanced` / `rusher`, on `https://netrts.snowse.io`.

## Non-goals (for now)

- Writing Raft ourselves. `ra` does elections, terms, log replication and persistence. See
  [Later](#later) for making it more complex once everything works.
- One machine per unit.

---

## Big picture

```
                    netrts.snowse.io  (NetRTS game server)
                            ▲  REST/JSON, leader node only
                            │
 ┌──────────────────────────┼──────────────────────────────────────────┐
 │ k3s cluster              │                                          │
 │                          │                                          │
 │  Machine 1               │ Machine 2               Machine 3        │
 │  ┌────────────────┐    ┌─┴──────────────┐      ┌────────────────┐   │
 │  │ BEAM swarm-0   │◄──►│ BEAM swarm-1 ★ │◄────►│ BEAM swarm-2   │   │
 │  │  ra server     │    │  ra server     │      │  ra server     │   │
 │  │  Worker 31 ●   │    │  GameLoop      │      │  Worker 33 ●   │   │
 │  │  Archer 90 ●   │    │  Soldier 77 ●  │      │  Scout 81  ●   │   │
 │  └────────────────┘    └────────────────┘      └────────────────┘   │
 │        ▲                       ▲                        ▲           │
 │        └──── distributed Erlang (full mesh, shared cookie) ┘        │
 └─────────────────────────────────────────────────────────────────────┘
   ● unit process (one per game unit)     ★ node whose ra server is the Raft leader
```

| Layer | Responsible for |
|---|---|
| **Kubernetes (k3s)** | Keeps 3 BEAM nodes running, one per machine, each with its own disk for the Raft log. Restarts a killed node. Knows nothing about the game. |
| **BEAM / OTP** | Connects the nodes, delivers messages (local or remote, same code), reports dead processes (`:DOWN`) and dead nodes (`:nodedown`), restarts crashed processes inside a node. |
| **`ra`** | Raft among the 3 nodes: elects the leader, replicates the team state, refuses writes without a majority. |
| **Our code** | The replicated state machine, the leader's game loop, matching unit processes to the game state, each unit's decisions. |

---

## Processes inside one node

Every node runs the same release with the same supervision tree:

```
Swarm.Application
├── Cluster.Supervisor        libcluster: finds and connects the other nodes
├── :pg scope :swarm          process groups across the cluster (who are all the units?)
├── ra system + ra server     this node's member of the Raft cluster (runs Swarm.Machine)
├── Swarm.UnitSupervisor      DynamicSupervisor: unit processes placed on THIS node
│   ├── Swarm.Unit (31)       GenServer = one game unit
│   └── Swarm.Unit (90)
└── Swarm.LeaderSupervisor    DynamicSupervisor: holds Swarm.GameLoop while this node's
    └── Swarm.GameLoop        ra server is leader (otherwise empty)
```

- **`Swarm.Unit`**: one GenServer per game unit. It holds `unit_id`, `type`, its latest view of the
  game and the latest strategy. It doesn't vote; it answers whichever node is leading.
- **`Swarm.Machine`**: our `ra` state machine (`:ra_machine` behaviour). It is a pure module, so it
  is easy to test (see [Testing](#testing)).
- **`Swarm.GameLoop`**: exists only on the leader node. `Swarm.Machine` starts and stops it as the
  local ra server becomes leader or steps down.

Every unit process joins the `:pg` group `:units` when it starts, so
`:pg.get_members(:swarm, :units)` lists every unit in the cluster, wherever it runs. A unit
process also registers itself under `{:unit, unit_id}` so the leader can find a specific one.

---

## Consensus with `ra`

### The cluster

- Three ra servers, one per node: `{:swarm_ra, :"swarm@swarm-0…"}`, `…swarm-1…`, `…swarm-2…`. The
  StatefulSet gives the pods stable names, so the member list is fixed and known in advance.
- Started once with `:ra.start_cluster/4`. After a restart a node calls `:ra.restart_server/2`,
  re-reads its log from disk and catches up from the leader.
- A majority is 2 of 3. Losing one node is fine; losing two stops the cluster, which is the
  correct Raft behaviour.

### What `ra` does for us

- Leader election with terms and randomized timeouts.
- Heartbeats and failure detection between the servers.
- Log replication: a command is only applied once a majority has it.
- Persistence: each server writes its log to disk.
- Split-brain safety: a minority side can't elect a leader or commit anything.

### The replicated state (`Swarm.Machine`)

```elixir
%{
  match_name: "swarm-2026-10-29-1",
  match_id: "…",
  strategy: %StrategyOrder{type: :gather, target: nil, building: nil},
  last_tick: 412          # last tick whose commands were submitted
}
```

Commands, applied in `apply/3` (pure: state in, state + reply out):

| Command | Effect |
|---|---|
| `{:match_started, name, id}` | remember the match |
| `{:set_strategy, order}` | change the team strategy |
| `{:tick_submitted, tick}` | record progress (and act as a fence, below) |

`state_enter/2` is called when the local server changes role. On `:leader` it starts
`Swarm.GameLoop` on this node; on any other role it stops it.

### Fencing an old leader

During a partition an old leader can still be running for a moment. Before posting commands, the
game loop commits `{:tick_submitted, tick}` through `ra`. Only a leader that still has a majority
can commit, so a deposed leader's commit fails and it never sends stale orders.

---

## The leader's game loop

`Swarm.GameLoop` runs only on the leader node:

```
on start:  read match_id / strategy from the replicated state
           (no match yet → POST /matches with houseBots, commit {:match_started, …})

loop:
  state = GET /matches/{id}/state?waitForTick=tick+1&sinceTick=tick     (long-poll)
  reconcile(state)                       start/stop unit processes to match the game
  strategy = decide_strategy(state)      Gather / Build / Attack / Defend / Scout
  if changed: commit {:set_strategy, strategy}
  broadcast {:tick, tick, state, strategy} to all units
  collect {:command, tick, unit_id, cmd} until a deadline (~40% of the tick interval)
  commands = unit commands ++ economy commands (Produce, Research, Rally from buildings)
  commit {:tick_submitted, tick}         fails if we are no longer leader → stop
  POST /matches/{id}/commands
```

- **Buildings are not units.** Production, research and rally points are part of the leader's
  strategy. Units only command themselves (Move / Attack / Gather / Build / Stop).
- **Orders persist in the game.** A unit already doing the right thing answers `:no_change`, and
  late answers are dropped (the unit keeps its previous order). Missing a deadline is never fatal.
- **A new leader resumes from replicated state.** It already knows the match and strategy, so it
  long-polls the current state and carries on. Cost: a tick or two without new orders.
- The API key (`nrts_…`) is registered once by hand and stored in a k8s Secret, so any node can
  act as leader.

---

## Reconciliation

Each tick the leader makes the unit processes match the game state:

| Game says | Processes say | Action |
|---|---|---|
| we own unit 88 | no process for 88 | **spawn** `Swarm.Unit(88)` on the node with the fewest units (newly trained, or orphaned by a dead node) |
| unit 31 is gone | process 31 exists | **stop** process 31 (unit died in game) |
| we own unit 32 | process 32 exists | nothing |

This single rule covers new units, dead units and node failures. Spawning on another node is just
`DynamicSupervisor.start_child({Swarm.UnitSupervisor, node}, {Swarm.Unit, unit_id})`.

---

## Unit decisions

Each unit gets the state and the strategy and decides for itself only. Workers mine when idle.
A fighter works out its role from the view (`Swarm.Roles`, the same rule on every node, so no
messages are needed): in the current **wave**, a **guard** (the newest fighters at home, at least 3
or a quarter of the army), an **escort** (each outpost, a Resource Depot more than 10 tiles from
the Command Center, gets one per 3 workers mining there, 2 to 5; fighters already at the outpost
keep the job, and a gap goes to the closest free fighter, so nobody rotates across the map), or an
**attacker** waiting for the next wave. Then, first match wins:

| Situation | Fighter does |
|---|---|
| Something to fight within 6 tiles | Attack it (see below) |
| In the wave, home can't hold and the wave is closer to home than the target | Attack-move to the threat |
| In the wave | Attack-move to the target |
| Escort | Fight enemies at its outpost, else stand 2 tiles out from it toward the enemy |
| Guard or attacker, enemies near the main base | Attack-move to the threat |
| Attacker, an outpost or workers in the field under attack | Go help the closest (guards stay home) |
| Guard | Stand at the post (behind the front tower, else the rally point) |
| Attacker | Wait at the rally point |

"Home can't hold" means the enemy fighters near the base outnumber home fighters plus 2 per
finished tower. It is judged from the wave's center, so the whole wave agrees.

Who fights whom (`Swarm.Roles.target/3`), also the same on every node: enemy fighters come
first. Pairs are taken closest first, with enemies that can already hit us ahead of the rest,
and a unit already on an enemy stays on it. An enemy takes attackers until their damage
(`max(1, damage + Weapons - armor)`) covers its current HP, with at most 8 melee attackers. Enemy
armor is assumed +1 once we have seen an enemy TechLab, since their research is hidden. Units
left over hit towers, then workers, then other buildings. Fighters at home only go after
enemies inside a base (within 10 of the Command Center or an outpost), within 5 of one of our
workers, or already in their own range; the
wave fights anything.

Siege: an enemy Trebuchet (range 3–7, outranges towers) is fought before anything that can't hit
us yet, from up to 10 tiles away. One within 9 of any of our buildings counts as an attack (the
leader holds waves; attackers go), and home units may leave the base to kill it. Any unit on a
tile where an enemy shell is about to land (the `shells` in the state) steps off it first, unless
it is already moving. Each unit
remembers the order it is carrying out, so it sends nothing while that order still stands.

Leader's team strategy (`Swarm.Brain`), built in stages:

1. **Economy (done):** grow to ~20 workers while following a build order kept as data: Barracks
   (7 workers) → Resource Depot by the ore (9) → Guard Tower toward the enemy (11) → TechLab (13)
   → 2nd Barracks (15) → 2nd Guard Tower (17). The ore for the next building is
   set aside first (including while the builder walks there, since it is paid on arrival), and a
   failed Build is retried as soon as its `CommandFailed` event arrives. The TechLab researches
   Harvesting1, Weapons1, Armor1, then tier 2. Barracks train Soldiers and Archers with the rest.
   Miners about to be hit run to the rally point. Workers only mine ore within 10 tiles of a drop-off: the shortest trip with fewer than 3
   workers on it, else the shortest. When home has been short of ore for 30 ticks in a row (under
   1,500 left within reach of a drop-off, or more than 3 workers per nearby deposit), a Resource
   Depot goes by the closest other ore, ahead of the build order. Depots only go by ore on our
   side (closer to our Command Center than to any enemy start, so never a contested deposit
   between players) and not within 4 tiles of where we lost a building in the last 300 ticks. Below an army floor (6 fighters,
   plus 1 per 100 ticks) the Barracks train before anything is built or researched.
   With 500+ ore on hand once the first Barracks is up ("rich"): the build order stops waiting
   for workers, except for depots; once it is done,
   extras follow (SiegeWorkshop after SiegeEngineering, a 3rd and 4th Barracks, up to 5 Guard
   Towers); each building gets two builders; Barracks queue up to 5. A SiegeWorkshop keeps 2
   Trebuchets, which hold the guard post and let the game aim them (idle ones fire by themselves,
   at enemies standing still first).
2. **Roles and waves (done):** the leader launches a wave once 15 attackers wait at the rally
   point; only those go, so units trained later wait for the next wave instead of trickling out.
   The members are kept in the replicated memory, so a new leader knows who is out. The wave is
   recalled when fewer than 5 of it are left. No wave leaves while the base is under attack.
3. **Scouting and attack decisions (done):** one Scout (replaced when it dies) visits the spot it
   saw longest ago, checks the enemy base most often, gets as close as is safe (enemy range + 2),
   runs when closer or taking damage, and then checks other spots before coming back. The
   leader remembers every enemy fighter seen (dropped when we kill it or after 300 ticks
   unseen) and launches a wave once the staged attackers are 1.5× the known enemy army plus
   towers, by HP × damage per tick (at least 8; 15 while we know nothing). A wave facing a
   stronger force pulls back. In the last 300 ticks, if we are behind on score, every fighter
   attacks; if ahead, we don't throw units away, since living units count toward the score.
League matches: `Swarm.join(name)` commits the league to the replicated state. The leader joins
(idempotent, so a new leader simply joins again), long-polls `state?waitForTick=0` for each round,
plays the heat with a fresh brain and its own map, then waits again until `MATCH_FINISHED`.

Watching it: every node serves Prometheus metrics at `:9568/metrics` (`Swarm.Metrics`: game
figures from the leader, and each node's own share of the swarm), and the leader logs each
decision with its reason (`Swarm.Decisions`). `k8s/observability/` has the PodMonitor, Loki and
Alloy settings, and a Grafana dashboard.

4. **AI coach (next):** every ~40 ticks an LLM suggests settings for the brain, committed through `ra`.

---

## Messages

Raft traffic between the ra servers is handled by `ra`. Our own messages are plain Elixir terms;
there is no HTTP between nodes.

| Message | From → To | Purpose |
|---|---|---|
| `{:tick, tick, state, strategy}` | game loop → all units | here is the world, decide |
| `{:command, tick, unit_id, cmd \| :no_change}` | unit → game loop | my unit's order |

Because pids work across nodes, both are sent with the same `send/2` whether the receiver is on
this machine or another.

---

## Failure scenarios (also the demo script)

| What we do | What should happen |
|---|---|
| `kubectl delete pod swarm-1` (the leader) | ra elects a new leader among swarm-0/2 → its `state_enter` starts the game loop → match resumes from replicated state → orphaned units re-spawned on swarm-0/2 → k8s restarts swarm-1, which rejoins as a follower and gets new units over time |
| `kubectl delete pod swarm-0` (a follower) | No election. The leader re-spawns swarm-0's units elsewhere |
| A unit dies in the game | The leader stops its process |
| NetworkPolicy isolates the leader's node | The isolated node can't commit, so its game loop stops at the fence; the other two elect a leader and keep playing; when the partition heals, the old leader rejoins as a follower |
| Delete two pods at once | No majority: no leader, no orders, until a node comes back. Show this as the limit of the system |
| Kill one unit process (`Process.exit`) | Its node's supervisor restarts it |

Metrics to record for the report: election time (leader lost → game loop running again), ticks
with no commands submitted, orphan adoption time, number of leader changes per match.

---

## Deployment

- **Image (to be created in milestone 5):** `mix release` in a multi-stage Dockerfile, pushed to a
  public **GHCR** repository that we'll set up then.
- **StatefulSet `swarm`**, 3 replicas → stable names `swarm-0..2` and node names
  `swarm@swarm-N.swarm.<ns>.svc.cluster.local`, which are also the ra member ids.
- **`volumeClaimTemplates`** using k3s's built-in `local-path` storage, so each node keeps its ra
  log across restarts.
- **`topologySpreadConstraints`** (maxSkew 1 on `kubernetes.io/hostname`) so each machine runs
  exactly one node.
- **Headless Service `swarm`** for DNS discovery; libcluster `Cluster.Strategy.Kubernetes.DNS`
  (or `DNSPoll`) finds peers.
- **Secret** with `RELEASE_COOKIE` and the NetRTS API key.
- k3s ships a NetworkPolicy controller, so the partition demo needs no extra install.

Local development uses the same code with libcluster's `Epmd` strategy and a fixed host list:

```bash
iex --sname a -S mix
iex --sname b -S mix
iex --sname c -S mix
```

Everything up to milestone 4 works on a laptop.

---

## Milestones

| # | Milestone | Done when |
|---|---|---|
| 0 | Warm-up: 2–3 `iex` nodes connect and send messages; a toy GenServer pinged across nodes; a 3-node `ra` cluster from the ra README, kill one, watch a new leader | You can explain `send`, `receive`, GenServer, node connect, and what ra does |
| 1 | `Swarm.NetRts` client (`Req` + `Jason`): create match, long-poll state, post commands. One process plays a full match vs `sitter` | A match finishes with commands accepted |
| 2 | Unit processes + reconciliation on one node: one process per unit, units answer `:tick` with commands | Units spawn and stop as the game changes |
| 3 | `Swarm.Machine` with tests; 3-node ra cluster on the laptop; `state_enter` starts/stops the game loop; fence before posting | Kill the leader node in a terminal, another node takes over the match |
| 4 | Units spread across the 3 laptop nodes (libcluster, `:pg`), orphan adoption | Kill a node, its units reappear on the others, the match keeps going |
| 5 | Docker image on GHCR, StatefulSet on k3s across 3 machines | Match runs across the 3 machines |
| 6 | Strategy that beats `sitter`, then `balanced` / `rusher` | Wins recorded |
| 7 | Chaos runs (delete pod, partition, two pods down), metrics, demo video, report | Deliverables done |

## Testing

- **State machine tests:** `Swarm.Machine.apply/3` is pure, so plain ExUnit tests cover it.
- **Multi-node tests:** OTP's `:peer` starts extra BEAM nodes from ExUnit to run a real 3-node ra
  cluster and kill members.
- **Game tests:** play vs `sitter` on snowse.io (or a local NetRTS server for private runs).
- **Chaos:** scripted `kubectl` scenarios from the table above, with timings logged.

## Later

Once the ra version works, options for going further:

- **Write the election yourself:** replace ra's election with our own Raft and compare against
  ra (election time, behaviour under partition).
- **Units as voters:** every unit process votes, with the vote count taken from the game state so
  a minority side can't win.
- **Units as ra members:** add and remove ra members as units are trained and die. This exercises
  Raft membership changes.

## Decisions log

| Decision | Choice | Why |
|---|---|---|
| Language | Elixir | Used in class; process-per-unit and message passing are native |
| Repo | Separate from NetRTS | Bot only depends on the HTTP API |
| Unit placement | Many unit processes per BEAM node, 3 nodes on 3 machines | Simpler than pod-per-unit, no idle pool |
| Consensus | `ra` among the 3 nodes | Production-grade Raft; get everything working first, make it more complex later |
| Who talks to NetRTS | The node whose ra server leads | No special coordinator; leadership and the game connection move together |
| Fencing | Commit `{:tick_submitted, tick}` before posting | A deposed leader can't commit, so it can't send stale orders |
| Registry | GHCR, public | Free, simple pulls from k3s (set up in milestone 5) |
| Orchestration | k3s StatefulSet, 3 replicas, local-path volumes | Stable ra member names, logs survive restarts, one node per machine |
