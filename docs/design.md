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
| `{:claim_match, name}` | claim the next practice match before creating it; refused if one is claimed or being played |
| `{:claimed_started, name, id}` | record the claimed match's id; refused if the claim was settled already |
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
           (no match yet → commit {:claim_match, name}; only the winner of the claim
            POST /matches with houseBots and that name, then commits {:claimed_started, name, id}.
            A new leader that finds a claim with no id looks the match up by name first, so a
            leader dying mid-create leaves one match, never two)

loop:
  state = GET /matches/{id}/state?waitForTick=tick+1&sinceTick=tick     (long-poll)
  reconcile(state)                       start/stop unit processes to match the game
  strategy = decide_strategy(state)      Gather / Build / Attack / Defend / Scout
  if changed: commit {:set_strategy, strategy}
  send {:tick, tick, state, strategy} once to each node's relay, which works out the team-wide
    answers once (roles, who fights whom) and hands the tick to its units
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
| we own unit 88 | no process for 88 | **spawn** `Swarm.Unit(88)` on the node with the fewest units per core (newly trained, or orphaned by a dead node) |
| unit 31 is gone | process 31 exists | **stop** process 31 (unit died in game) |
| we own unit 32 | process 32 exists | nothing |

This single rule covers new units, dead units and node failures. Spawning on another node is just
`DynamicSupervisor.start_child({Swarm.UnitSupervisor, node}, {Swarm.Unit, unit_id})`.

---

## Unit decisions

New unit processes go to the node with the fewest units per core (each node's core count is asked
once and kept), not an even third each: our machines have 16, 4 and 12 cores, and with an even
split every late answer in our big games came from the 4-core one. With 180 units it now carries
about 22, against 60 before. Units already running aren't moved; new ones shift the balance.

The tick reaches the units through one relay per node (`Swarm.Relay`): the leader sends it once
per node, not once per unit, so the view crosses the network once for each machine. The relay works
out the answers every unit needs about the whole team once (`Swarm.UnitBrain.prepare/2`: each
fighter's job, who fights whom, the raids and where help is wanted, home's strength, the bases, the
drop-offs and each deposit's walk, which ore is by home or unsafe) and hands the tick, with them, to
each of its units, which reads its own part and makes its own decision. The answers are kept small
(deposits as ids; the lists of units and towers, which the view already carries, each unit lists
again for itself on arrival), since the view is copied into every unit's message. Before any of
this, every unit worked the whole team out again: for 145 units about 1,150 ms of work a tick;
now about 9 ms in the relay and 4 ms across the units. A node without a relay (an older release during a rolling upgrade)
gets the tick sent to each unit, as before.

Each unit gets the state and the strategy and decides for itself only. Workers mine when idle.
A fighter works out its role from the view (`Swarm.Roles`, the same rule on every node, so no
messages are needed): in the current **wave**, a **guard** (the 7 newest fighters at home), an
**escort** (each outpost, a Resource Depot more than 6 tiles from the Command Center with workers
mining there, gets a group of 3, or none if 3 can't be spared; fighters already at the outpost keep the job, and a gap goes to the closest free fighter,
so nobody rotates across the map; each outpost also gets a Guard Tower, two once we are rich), or an
**attacker** waiting for the next wave. Then, first match wins:

| Situation | Fighter does |
|---|---|
| Archer losing the fight around it (enemy fighters within 6 stronger than ours), an enemy soldier or scout within 3, away from home | Step 3 tiles back: farther from it, as close to the rally point as possible (kiting) |
| An enemy fighter to fight within 6 tiles, where we are at least as strong as they are (see below) | Attack it |
| In the wave, in the reach of an enemy tower we know of (in sight or remembered in the fog), with us at least as strong as it there | Attack that tower (walk at it first if we can't see it): only the unit being shot, the rest carry on |
| Losing where it stands, with nothing it may fight | In the wave: back to the wave's middle (3+ tiles off), or toward home; at home: back to the rally point. Nobody chases into more danger |
| Something else to fight within 6 tiles (sites, workers, buildings) | Attack it (see below) |
| In the wave | Attack-move to the target |
| Escort | Fight enemies at its outpost if the escorts (all of them) with our fighters and towers there can meet them; a stronger raid, back to the rally point. Else stand 2 tiles out from it toward the enemy |
| Guard or attacker, enemies near the main base | Attack-move to the threat, together: from the rally point, once everything at home and our towers there are at least as strong as what is there (those already within 6 carry on); otherwise wait at the rally point. Falling back, if no tower of ours reaches it: to the tower closest to it |
| Attacker, with the leader helping somewhere (`strategy.help`) | Attack-move there (guards stay home); falling back, if no tower of ours reaches it, go to the tower closest to it instead, where the workers run to |

**Towers:** a tower reaches 5 tiles the game's way (diagonals count as one) while a Soldier sees 5
in a straight line, so a tower often shoots a Soldier that can't see it. The server remembers
towers we have seen (`rememberedBuildings`), so a wave member in the reach of one we know goes
for it, walking at it until it is in sight. Only that unit: the rest of the wave goes on, and a
tower that isn't shooting at a unit is a building like any other to it.

**Helping:** one decision, made and kept by the leader (`strategy.help`), not by each attacker
every tick (which turned the group around whenever an archer stepped out of sight). It commits to
the place help is wanted (an outpost, our workers, a siege; not under an enemy tower) closest to
the rally point that home can take, so the attackers go together from there. Committed, it follows
the fight within 8 tiles, and holds until nothing has been wanted there for 15 ticks, or what is
there is 1.3× what home can bring. Committing and calling off use one measure
(`Swarm.Roles.help_odds/3`: everything at home and our towers that reach the spot, against what is
there), so they never disagree. A raid on the main base still comes first.

**Falling back:** when the raiders out of our towers' reach (Trebuchets aside) are stronger than
everything at home, wherever it stands, home falls back to the towers (`Swarm.Roles.fall_back?/2`,
`strategy.fall_back`): workers run for cover, defenders gather by the towers nearest the attack to
cover them and fight whatever follows them there (with the towers), and home fighters don't go
after those raiders, only fight back against one in range. It is the same comparison that calls
a wave home, so the wave coming back usually ends it. It holds 15 ticks past the last reason to, so
raiders stepping in and out of sight don't flip it every tick.

**Regrouping:** when enemy fighters inside the main base (within 10 of the Command Center) are at
least 1.5× everything at home, towers there included, and we have a finished backup Command
Center, we regroup there (`strategy.regroup`), in secret: the backup trains two workers of its
own, who mine by it and bank there. Attacked, one runs straight away from the enemy but never closer
to the backup, keeping its ore until it is safe, so nobody is led to it. Nobody else goes there:
home fighters and the main base's workers carry on as before, and no worker ever mines by a backup
otherwise. No wave leaves meanwhile. It ends 40 ticks after the base was last overrun.
| Guard | Stand at the post (behind the front tower, else the rally point) |
| Attacker | Wait at the rally point |

Every strength comparison (launching, recalling, strikes, sorties, the serum, home's defense) uses
one measure, `Swarm.Roles.strength/2`, so they always agree: a unit is worth its cost in Soldiers
(a full Soldier is 990, an Archer 1.25 Soldiers, a Trebuchet 3.5), less as it is hurt. HP × damage
per tick, the old measure, made an Archer a third of a Soldier, and packs of them overran us while
every comparison said home could hold. A Guard Tower at full HP (less as it is hurt) is worth some Soldiers. In a straight fight it
takes about three and a half (four kill it and lose one or two; three lose), so it is counted on
the safe side both ways: ours as 3, so we never trust home's defense too much, theirs as 4, so we
never go at one too light. Whose it is decides, not who asks: a strike's launch and its recall
both see an enemy tower and agree.

Any wave, strike or sortie is called off once it has lost over a third of the most strength it has
had (reinforcements count), not left to bleed until only a few remain. A wave takes at most 20
fighters, or two thirds of all our fighters once that is more: up to 27 fighters it may take
everyone but the seven guards, and past that a third of the army stays home (the end-of-match
all-in still takes everyone). After a wave is called home for an enemy army near home, no new wave
leaves for 20 ticks, counterattack or not. The leader also recalls the wave when home can't hold: the enemy fighters hitting any base, an outpost
or our workers are stronger than what can meet them: our fighters not in the wave within 12 tiles
of a raider, and the towers that can reach one. Defenders at another base don't count. A
recalled wave is just fighters at home again, so they walk back, fighting only what attacks them
on the way. A wave only leaves if what stays home can hold the raid going on (by the same
comparison, so a scout poking at the base holds nothing up) and any enemy army we remember within
20 tiles of the Command Center (the strongest single player's, against everything that stays home
and our towers by it), and not within 20 ticks of a recall for home. A wave out comes home for such
an army too, before it is in the base. Strikes and sorties only take fighters within 20 tiles of
the Command Center, so a recalled wave walking back isn't sent straight into another fight. Once a raid we beat has been gone for 20 ticks (3 of its fighters killed at home, the last of it
seen 20 to 50 ticks ago) a wave may leave with every attacker within 10 tiles of the rally point: a
counterattack. Not sooner: archers step out of sight and back, and a counterattack left into them
and was called straight back. For the same reason no wave at all leaves while a raid has been out
of sight for less than 20 ticks. When no wave leaves, the leader's 10-tick log line says why (`waiting: …`).

An enemy tower at our door (finished, within 12 of the Command Center; never because it is by an
outpost, usually the enemy's own base next door): home fighters never walk
into its reach (its range + 1) one at a time, not even to meet enemy units standing by it
(`Swarm.Roles.covered?/2`); fighting back is still allowed. Instead the leader strikes it, ahead of
any wave, but never while home is being raided: the attackers at home at once (the guards stay, so
the base is never empty), when that is at least 8 of them with
the strength of the tower (4 soldiers) and every other enemy tower that covers it, plus 1.5× the strongest player's units by it. The strike is a wave whose target is
the tower, and comes home once the tower is down (or too few are left, it is outmatched by the same
measure, home can't hold a raid without it, or after 120 ticks); after one comes back, no new strike for 20 ticks. An enemy building still going up within 12 of the Command Center,
and not under a tower, is razed by our attackers (`strategy.raze`, below).

Siege at our door. The leader remembers our buildings' HP; one losing HP with nothing we can see
able to reach it is being shelled from out of sight (a Trebuchet reaches 7, a tower 5, and a tower
can't see its own corners). Up to 4 home fighters go to look, one each to the four sides of it, 7
tiles out, since shells can come from anywhere. A checker that dies ends the check: nobody goes in
after what we can't see (it was an archer pack as often as siege). The closest scout goes to look
there instead (it sees 8 and steps back once anything can reach it), so we learn what it is and the
usual rules answer it with real numbers; no new checkers go out for 60 ticks meanwhile. Once we can see enemy Trebuchets in reach of our buildings, a sortie
goes at them: everyone at home (guards and attackers) at once, at 1.3× the enemy
units there (less than the 1.5 a wave wants: they are knocking our buildings down meanwhile; more
than even, or it is recalled the moment one more shows up, and out again), at least 4,
Trebuchets first. It follows the siege and comes home once it is cleared (or too few are left, it
is outmatched, or after 100 ticks). Enemy sites within 12 tiles of the Command Center, and finished
buildings within 10 (a Barracks or a Command Center built at our door; never because one is by an
outpost, which is usually the enemy's own base next door), are razed by our attackers (the guards
stay home) once there are no enemy fighters to fight, home isn't being raided, no enemy tower
covers it, and home can take what is there. Home fighters never chase a building beyond the main
base; leftover fighters split, half on workers and half on
buildings, so building and producing both stop.

The serum: a once-a-match superpower the game keeps out of its published docs (GET then POST
`/matches/{id}/superpower/superserum`): Soldiers deal double damage and move twice as fast for 30
ticks, as long as every command to them carries our key (header `X-SUPERPOWER-SUPERSERUM`), and
every player is told when we take it. It is kept for when home is being overrun and the help we
have won't do: the brain asks for it (`strategy.serum`) when a raid of at least ~8 soldiers'
strength hits home, we have 8 Soldiers or more, and either a wave out that can be back within 15
ticks can't hold it even together with home (otherwise recalling the wave is enough), or, with no
wave that close, the raid is at least 1.25× everything at home, wherever it stands (not a coin flip,
and not just because home's fighters are across the base). Never for the wave's own fights
(it should win those anyway); doubling Soldiers' speed also brings a recalled wave home sooner. That tick every Soldier sends its order
again, the game loop takes the serum, and for the 30 ticks every command goes with the key.
`Swarm.serum/1` (replicated): `:practice` (the default, not in league heats), `:on` or `:off`.

Who fights whom (`Swarm.Roles.target/3`), also the same on every node: enemy fighters come
first. Pairs are taken closest first, with enemies that can already hit us ahead of the rest,
and a unit already on an enemy stays on it. An enemy takes attackers until their damage
(`max(1, damage + Weapons - armor)`) covers its current HP, with at most 8 melee attackers. Enemy
armor is assumed +1 once we have seen an enemy TechLab, since their research is hidden. Units
left over hit a tower shooting at them, then construction sites (worth their full cost
in destruction at a tenth of the HP and no armor), then workers, then other buildings, and
Command Centers last (a player is eliminated with their last one, and everything they had left
is removed with no destruction score for anyone). Nobody chases an enemy into more danger: a fighter only goes after an enemy (or a building)
where our fighters and towers there, with it, or the group around it (our fighters within 6 of
it, who go in with it), whichever is more, are at least as strong as theirs there (their
fighters, and their towers we know of that reach the spot; a Trebuchet counts as one Soldier, as
it can't hit anything close), and otherwise only hits what it can reach without moving. Fighters at home only go after
enemies inside a base (within 10 of the Command Center or an outpost) or within 5 of one of our
workers, and fight back against any enemy fighter in range either way (never a building, so a
recalled wave walks home); the
wave fights anything.

Siege: an enemy Trebuchet (range 3–7, outranges towers) is fought before anything that can't hit
us yet, from up to 10 tiles away. One within 9 of any of our buildings counts as an attack (the
leader holds waves; attackers go), and home units may leave the base to kill it. Any unit on a
tile where an enemy shell is about to land (the `shells` in the state) steps off it first, unless
it is already moving. Each unit
remembers the order it is carrying out, so it sends nothing while that order still stands.

Leader's team strategy (`Swarm.Brain`), built in stages:

1. **Economy (done):** grow to ~20 workers (30 in a big game) while following a build order kept as data: Barracks
   (7 workers) → Resource Depot by the ore (9) → Guard Tower (11) → TechLab (13) → 2nd Barracks
   (15) → 2nd Guard Tower (17) → backup Command Center (17, once we have 10 fighters: in a small
   game it is 400 ore while the first raids come, so it comes last). The backup Command Center goes to a free
   corner of the map (no base starts within 15 of it: on a ring map none do, and in a 2–4 player
   game the unused ones are free), the one nearest us, ours if there is one: the farthest a spot
   can be from the middle, which everyone crosses, and nobody's way anywhere. Failing that, along
   our edge: on our side, no nearer the middle than our base (less 3), as far from the enemy as
   can be. At least 12 tiles from our base (6 on a crowded map), away from ore and known enemy
   buildings, with two builders, and is rebuilt if lost: a player is eliminated only with no
   Command Center at all, and elimination would wipe our survival score. It isn't a drop-off while
   our base stands, so workers never go mining by it. In a big game (6 players or more) we turtle
   up, army first: Barracks (7) → Resource Depot (9) → Guard Tower (10) → 2nd Barracks (12) →
   TechLab (13) → 2nd Guard Tower (14) → 3rd Barracks (16) → 3rd Guard Tower (16) → backup Command
   Center (once we have 10 fighters) → Guard Towers 4–10 (20 workers and 15 fighters), all on a square 5–6 tiles around the base, spread at least 5
   apart (their reaches meet), the side facing our neighbors first; the first wave waits for the
   square of 10 (until tick 900 at most); a co-op away from home waits for 15 fighters, and its tower comes
   before the rest of the build order. Barracks and the TechLab go 3–6 tiles from the Command Center, never on
   the ore side (between it and its ore, or within 3 of ore: that is the miners' path and where the
   first depot goes, between the Command Center and the ore), then behind it, away from the neighbors.
   The ore for the next building is
   set aside first (including while the builder walks there, since it is paid on arrival), and a
   failed Build is retried as soon as its `CommandFailed` event arrives. The TechLab researches
   Harvesting1, Weapons1, Armor1, then tier 2. Barracks train Soldiers and Archers with the rest.
   Miners run for cover: from an enemy fighter about to hit them, and, out of our towers' reach,
   from one within 6 tiles when the enemies there are stronger than our fighters and towers there
   or home is falling back (below). Cover is next to the closest of our Guard Towers on their side
   of the enemy (else the closest of our fighters or drop-offs on their side of it). They don't
   mine ore with an enemy fighter within 5 tiles. Workers only mine ore within 10 tiles of a drop-off, by a drop-off at home first (the Command
   Center and depots within 6 of it, as everywhere a depot farther out is an outpost), then by an
   outpost, once home's ore is gone or unsafe: the shortest trip, stacked as deep as it
   takes (the game has no limit on miners per deposit, and each mines at full speed), so with a
   depot two tiles from its field they mine and bank without walking. A miner moves over once
   another deposit's trip is 2 tiles shorter than its own (a new depot went up by fresh ore). With all of that unsafe, safe ore farther away on our side
   (where the rule below puts a depot); with no safe ore at all, an idle worker waits next to the
   closest of our towers instead of standing in the field.
   **Ore is remembered:** the server only sends the deposits in sight, but deposits never move and a
   Gather may name one in the fog, so the leader keeps every deposit it has seen (forgetting one
   once it should see it and doesn't: mined out) and adds them to the view the brain and every unit
   plan with. Once we have a scout, the first one **surveys** our side for ore before taking its post:
   spots on two rings (10 and 20 tiles) around the Command Center, on our side of the map, each
   done once anything of ours sees it (or after 40 ticks of trying).
   **Ore for workers:** once a Barracks is up, 100 ore (two workers) is kept back from everything but
   workers, and with fewer than 5 workers left, workers are trained before anything else: losing
   every worker with nothing banked would end the economy for good. When home has been short of ore for 30 ticks in a row (under
   3,000 left within reach of a drop-off, so the next depot is up before it runs out; how many
   workers there are doesn't matter, they stack), a Resource
   Depot goes by the ore with the shortest trip of those out of reach (where idle workers go
   next), ahead of the build order; while it goes up, workers with no ore in reach mine by it.
   And whenever 3 or more workers are already mining one field out of reach, a depot goes by
   that field right away (a depot costs one Soldier and saves them all the walk). Depots only go by ore on our
   side (closer to our Command Center than to any enemy start, so never a contested deposit
   between players; an eliminated player's start doesn't count) and not within 4 tiles of where
   we lost a building in the last 300 ticks while enemy fighters we know of are within 10 of it
   (once they are gone, a lost depot is built again). Guard Towers go 3–4 tiles from the Command Center,
   so their 5-tile range covers the base, toward the nearest neighbor still in that no tower
   faces yet, so they spread over the ways in (the middle of the map with no neighbor left). Below an army floor (6 fighters,
   plus 1 per 100 ticks) the Barracks train before anything is built or researched.
   With 500+ ore on hand once the first Barracks is up ("rich"): the build order stops waiting
   for workers, except for depots; once it is done,
   extras follow (a 3rd and 4th Barracks, up to 5 Guard Towers); each building gets two
   builders; Barracks queue up to 5. Builders add up (each worker by a site adds 1 work a tick),
   so a depot (placed two tiles from as many deposits of its field as possible: a worker on the tile
   between depot and deposit mines and banks without a step) is built by the workers mining the
   ore it will serve, up to 5 (a co-op in about 5
   ticks, by the miners it saves the walk), and the first Barracks by the 3 closest workers. Siege is only for the waves (at home a 350-ore Trebuchet is
   a fifth as strong as the 3.5 Soldiers it costs): at 25 fighters, with the build order done,
   SiegeEngineering is researched and a SiegeWorkshop built, which keeps 2 Trebuchets. They wait
   at the rally point and, 2 or more at a time, go out with a wave. A wave with siege holds 9 tiles short of
   its target until the Trebuchets are there (at most 60 ticks), then goes in; Trebuchets step
   back from anything inside their 3-tile blind spot.
2. **Roles and waves (done):** the leader launches a wave once 15 attackers wait at the rally
   point (18 for the first in a big game; 10, before the tower square, for an early strike on a
   neighbor within 30 tiles that a scout has just looked at and that we outmatch 2 to 1), and never with fewer than 12 (15 in a big game),
   counterattacks included. While it is out, attackers trained later follow it in batches of 5 or more and become
   part of it, so it goes out and comes back as one. The members are kept in the replicated
   memory, so a new leader knows who is out. The wave is recalled when fewer than 5 of it are
   left, when home can't hold without it, or when the strongest single enemy player at its front
   is stronger than the whole wave, reinforcements on their way included. Players are counted
   apart: two fighting each other near us don't add up, so we can come in on them. No wave leaves
   while home couldn't hold the current raid without it, or for 20 ticks after a recall for home.
3. **Scouting and attack decisions (done):** two scouts, one per neighbor (the two nearest
   opponents), each waiting halfway between our Command Center and that neighbor's start, where
   an attack from them comes through. Before a wave leaves, once 5 attackers wait at the rally
   point and we haven't looked at that player in the last 60 ticks, the scout watching that side
   goes to 6 tiles short of the target, then back to its post; the launch waits for the look (at
   most 40 ticks), except for a counterattack. While a wave is out, the scout watching its
   target's side works in front of it: 6 tiles ahead of its lead unit for up to 8 ticks, then 5
   tiles behind its middle for 10 ticks, out of the fight, and again, through every new target;
   the wave never waits for it. With enemies already by the spot ahead, the wave is at them, so
   the scout stays behind it. A scout steps back once an enemy could reach it (its range + 2) or
   it is taking damage: with the wave, behind the wave; otherwise straight away from the enemy to 2
   tiles past its reach (at least 3 tiles farther when it is taking damage), not all the way home.
   It waits 6 ticks before going back, and a post or spot to look from that an enemy we can see
   covers is pulled back out of its reach first. The spot to look from is 7 tiles short of the
   target (the scout sees 8). The leader's
   10-tick log line says what each scout is doing and where (`scouts: 288 wave (51,16), …`). The
   leader remembers every enemy fighter seen (dropped when we kill it, after 300 ticks unseen, or
   when one of our units or buildings should see it where we last saw it and doesn't) and
   launches a wave once the staged attackers are 1.5× the known enemy army plus towers, by HP ×
   damage per tick (at least 8; 15 while we know nothing), and stronger than the strongest single
   player's army we can see on the way. A wave facing a stronger force pulls back. Waves only go after the weaker (by survival score, which the server
   reports for every player) of our two nearest opponents, never across the map; a wave sticks to
   that opponent, and comes home whenever home can't hold on its own. In the last 300 ticks, if we are behind on score, every fighter
   attacks; if ahead, we don't throw units away, since living units count toward the score.
Joining: `Swarm.join(name_or_id)` commits the request to the replicated state; the leader finds
the match, and a league match goes on as below, any other is played once. League matches: the
league is kept in the replicated state. The leader joins
(idempotent, so a new leader simply joins again), long-polls `state?waitForTick=0` for each round,
plays the heat with a fresh brain and its own map, then joins again (a join is for one round;
the wait answers `JOIN_NEXT_ROUND` without one, and the leader then joins) and waits, until
`MATCH_FINISHED`.
The wait for a round runs in a process of its own (the server holds that poll up to 30 s), and the
leader checks every second that we are still in the league: after `Swarm.leave()` between rounds
it moves on at once, to a match `Swarm.join` asked for, say, and gives up its place in the next
round on the server (unless that round is already split into heats: then it plays its heat). During
a heat, leaving means no more rounds after this one.

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
