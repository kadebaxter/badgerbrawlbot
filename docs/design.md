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
  commands = Orders.pick(unit commands, economy commands)
                                         the same command for many units goes as one; at most 100
                                         a tick (the server runs no more), economy commands always
                                         and last, then units in a fight, attacks, moves, gathers
  commit {:tick_submitted, tick}         fails if we are no longer leader → stop
  POST /matches/{id}/commands           one request; rejections logged as a warning
  next tick's strategy.resend            units cut or too late: they decide again from before that
                                         decision, so they send it again
```

- **Buildings are not units.** Production, research and rally points are part of the leader's
  strategy. Units only command themselves (Move / Attack / Gather / Build / Stop).
- **Orders persist in the game.** A unit already doing the right thing answers `:no_change`. A
  late answer, or a command cut to stay within 100, is not sent; the unit keeps its previous order
  in the game and is told next tick (`strategy.resend`), so it sends the new one again. Missing a
  deadline is never fatal, and never leaves a unit thinking an order went out that didn't.
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
| Archer whose fight isn't a "go" (see **Fights by group**), an enemy soldier or scout within 3, away from home | Step 3 tiles back: farther from it, as close to the rally point as possible (kiting) |
| In a fight (see **Fights by group**) | Go: attack its enemy (at home, attack-move at the raid). Gather: to the gather spot, hitting only what it can reach from where it stands. Away: in the wave, hold at the gather spot; at home, out of its reach, by our tower on our side, else the rally point, else the Command Center |
| An enemy fighter to fight within 6 tiles (8 for one it is already attacking: a path around a wall can step it out to 7 first), where its fight says go | Attack it |
| In the wave, in the reach of an enemy tower we know of (in sight or remembered in the fog), with us at least as strong as it there | Attack that tower (walk at it first if we can't see it): only the unit being shot, the rest carry on |
| Losing where it stands (they are 1.3× us by the same measure that sends it in), with nothing it may fight | In the wave: back to the wave's middle (3+ tiles off), or toward home; at home: back to the rally point. Nobody chases into more danger |
| Something else to fight within 6 tiles (sites, workers, buildings) | Attack it (see below) |
| In the wave | Attack-move to the target |
| Escort | Fight enemies at its outpost if the escorts (all of them) with our fighters and towers there can meet them; a stronger raid, back to the rally point. Else stand 2 tiles out from it toward the enemy |
| Guard or attacker, enemies near the main base | Attack-move to the threat, together: from the rally point, once everything at home and our towers there are at least as strong as what is there (those already within 6 carry on); otherwise wait at the rally point. Falling back, if no tower of ours reaches it: to the tower closest to it |
| Attacker, with the leader helping somewhere (`strategy.help`) | A plain move there until within 10, then an attack-move (an attack-move stops for everything on the way: a recalled wave sent to help fought its way through an enemy base for 100 ticks); guards stay home. Falling back, if no tower of ours reaches it, go to the tower closest to it instead, where the workers run to |

**Towers:** a tower reaches 5 tiles the game's way (diagonals count as one) while a Soldier sees 5
in a straight line, so a tower often shoots a Soldier that can't see it. The server remembers
towers we have seen (`rememberedBuildings`), so a wave member in the reach of one we know goes
for it, walking at it until it is in sight. Only that unit: the rest of the wave goes on, and a
tower that isn't shooting at a unit is a building like any other to it.

**Fights by group:** our fighters used to judge a fight each from where it stood (our fighters and
theirs within 6 of it, priced by cost). Two Soldiers ten tiles apart saw different fights, a step
forward changed the numbers, and a pack of archers parked just out of our towers' reach had our
fighters walk up, turn back and walk up again while the archers shot our workers. Now each node
works out, once a tick (`Swarm.Roles.groups/2`, in `prepare/2`), the fights: every group of enemy
fighters (within 3 tiles of each other, including ones just out of sight), with our fighters in
it (those within 10 of it, each in the nearest group's, and home attackers from anywhere in the
nearest raid's, if it is worth 2 Soldiers or more), and for each:

- an estimate of the fight played out tick by tick (`Swarm.Fight.advantage/2`): ours walking in
  from just out of its reach, theirs shooting as soon as ours are in theirs, damage falling on the
  front units first, both sides at once. It is our share left minus theirs, -1 to 1. Who hits
  first decides it: 26 Soldiers going in together beat 23 stacked archers with 18 left; the same
  26 arriving one a tick all die. Comparing prices can't see that. It is worked out for all of
  ours in the fight (`all`) and for those ready to go in (within 3 past its reach, `ready`);
- the gather spot, 2 tiles past its reach (and its towers'), on the side ours come from;
- the fallback, by our tower on our side, out of its reach.

A fight we were going into last tick is seen through: it stays "go" for everyone while `all` is
no worse than -0.5 (the leader remembers which, `View.going_in`). The estimate swings every tick
with who happens to be near; a call that swung with it (go in, stay out, gather: seven times in
twelve ticks) had 25 of ours lose to 20, a few fighting at a time while the rest walked in and out.
The same the other way: a fight we were staying out of last tick (`View.staying_out`) is gathered
for again only once `all` reaches +0.3, not at even (37 of ours went gather, stay out, gather ten
times in twenty ticks in front of 72); those ready winning it is still "go".

Each fighter then decides for itself, by the same rule on the same numbers (`Swarm.Roles.verdict/2`):
go in once those ready come out at least even; while all of us would but those ready wouldn't,
gather; otherwise stay out of its reach. One already in (attacking one of them) stays in until
`ready` drops below -0.15, and one on its way to the gather spot keeps going until `all` does:
the one-measure rule, with a margin, so nobody flips. Nobody gives orders: they move together
because they see the same fight. Workers run from an enemy fighter within its reach plus 2, and,
out of our towers' reach, from one within 6 whose fight would beat us; ore whose nearest drop-off
an enemy reaches (its range plus 2) is unsafe; an idle worker with nothing safe to mine waits by a
tower or drop-off no enemy reaches. It is cheap: for 300 of ours against 100 of theirs the relay's
whole `prepare/2` takes about 18 ms (it took 58 before, mostly working out odds for every pair of
fighters); the groups take 4 of that. The decision log says each fight's call when it changes
(`fight`).

**Helping:** one decision, made and kept by the leader (`strategy.help`), not by each attacker
every tick (which turned the group around whenever an archer stepped out of sight). It commits to
the place help is wanted (an outpost, our workers, a siege; not under an enemy tower) closest to
the rally point that home can take, so the attackers go together from there. Committed, it follows
the fight within 8 tiles, but only to where home can still take what is there (following onto the
middle of a pack had it called off the next tick and committed again at its edge), and holds until nothing has been wanted there for 15 ticks, or what is
there is 1.3× what home can bring. Committing and calling off use one measure
(`Swarm.Roles.help_odds/3`: everything at home and our towers that reach the spot, against what is
there), so they never disagree. After it is called off, no new help for 20 ticks, and for 120 ticks
help near where it was called off commits only at 1.3× what is there (the margin it was called off
at), so it doesn't walk out to the same pack every 20 ticks. A raid on the
main base still comes first.

**Finishing a Command Center:** an enemy Command Center that our fighters by it can bring down in 5
ticks is attacked before anything else (by those within 6 of it), and the wave or strike they are
in isn't called off meanwhile, whatever its losses: a player is eliminated with their last one.

**Falling back:** when a raid (2 Soldiers or more) with raiders out of our towers' reach
(Trebuchets aside) would beat everything we have for it, gathered or not (its fight is "away"),
home falls back to the towers (`Swarm.Roles.fall_back?/2`,
`strategy.fall_back`): workers run for cover, defenders gather by the towers nearest the attack to
cover them and fight whatever follows them there (with the towers), and home fighters don't go
after those raiders, only fight back against one in range. A raid we would beat is no reason to wait at
the towers: the attackers gather and go. It holds 15 ticks past the last reason to, so
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

The fight's estimate plays the fight out with our upgrades, and takes theirs to be the same: an
opponent's research is hidden from us (only spectators see it), and taken to have none they came
out far weaker than they were (24 against 25 was +0.52, "go in", where it was -0.34).

Every strength comparison (launching, recalling, strikes, sorties, the serum, home's defense) uses
one measure, `Swarm.Roles.strength/2`, so they always agree: a unit is worth its cost in Soldiers
(a full Soldier is 990, an Archer 1.25 Soldiers, a Trebuchet 3.5), less as it is hurt. HP × damage
per tick, the old measure, made an Archer a third of a Soldier, and packs of them overran us while
every comparison said home could hold. A Guard Tower at full HP (less as it is hurt) is worth some Soldiers. In a straight fight it
takes about three and a half (four kill it and lose one or two; three lose), so it is counted on
the safe side both ways: ours as 3, so we never trust home's defense too much, theirs as 4, so we
never go at one too light. Whose it is decides, not who asks: a strike's launch and its recall
both see an enemy tower and agree.

A wave whose player is eliminated comes home, not on into the next player: the next wave waits
20 ticks for it to get back, and for a scout's look at its new target. Any wave, strike or sortie is called off once it has lost over a third of the most strength it has
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
It is taken at even odds or worse (the raid at least as strong as home; it was 1.25 times, by
when too few Soldiers were left for it to matter), and only when it turns the fight: the fight's own
estimate, worked out with our Soldiers on it, has all of ours ahead (twice our Soldiers matching
the raid said yes to 40 against 71, where the estimate with it was about -0.3). A Soldier on the
serum, theirs or ours (the server marks each, `Swarm.Roles.serum?/1`), counts for two in every
strength comparison and hits twice as hard in the fight's estimate. Raiders on theirs in our
base are answered with ours, whatever the odds. Ours counts from the tick after it is taken,
before the server has marked anyone (`View.serum_on`, set by `Swarm.Brain.see/2`): every Soldier
of ours hits twice as hard in the fight's estimate, and the one call that comes out of it is for
Soldiers and Archers alike. On the tick it is taken, a fight we were going into stays on. (There
was a rule that sent every Soldier at the raid whatever the estimates said; with the estimate one
tick behind the serum, 34 Soldiers charged 49 while 19 Archers were called away and never fired.)
`Swarm.serum/1` (replicated): `:practice` (the default, not in league heats), `:on` or `:off`.

Who fights whom (`Swarm.Roles.target/3`), also the same on every node: enemy fighters come
first. Pairs are taken closest first, with enemies that can already hit us ahead of the rest,
and a unit already on an enemy stays on it. An enemy takes attackers until their damage
(`max(1, damage + Weapons - armor)`) covers its current HP, with at most 8 melee attackers. Enemy
armor is assumed +1 once we have seen an enemy TechLab, since their research is hidden. Units
left over hit a tower shooting at them, then construction sites (worth their full cost
in destruction at a tenth of the HP and no armor), then workers, then other buildings, and
Command Centers last (a player is eliminated with their last one, and everything they had left
is removed with no destruction score for anyone). Nobody chases an enemy into more danger: a fighter only goes after an enemy fighter when its
fight says go (**Fights by group**), and after a building
where our fighters and towers there, with it, or the group around it (our fighters within 6 of
it, who go in with it), whichever is more, are at least as strong as theirs there (their
fighters, including ones seen in the last 5 ticks that are out of sight now, where we last saw
them, so one step out of sight of a pack doesn't make it safe; and their towers we know of that reach the spot; a Trebuchet counts as one Soldier, as
it can't hit anything close), and otherwise only hits what it can reach without moving. Going in
and pulling back use that one measure (`Swarm.Roles.odds_for/3`) with a gap between them: a
fighter goes in at even, and pulls back only when they are 1.3× us; in between it carries on.
Two separate measures had soldiers step in, find themselves "losing" on the new tile, step back,
be "even" again, and flip every tick. Fighters at home only go after
enemies inside a base (within 10 of the Command Center or an outpost) or within 5 of one of our
workers, and fight back against any enemy fighter in range either way (never a building, so a
recalled wave walks home); the
wave fights anything.

Siege: an enemy Trebuchet (range 3–7, outranges towers) is fought before anything that can't hit
us yet, from up to 10 tiles away. One within 9 of any of our buildings counts as an attack (the
leader holds waves; attackers go), and home units may leave the base to kill it. Any unit on a
tile where an enemy shell is about to land (the `shells` in the state) steps off it first, moving or
not, and keeps at it until the shell has landed: nothing else it would do overrules the step (an
archer, slower than a tile a tick, used to turn back to its target before clearing the tile). Each unit
remembers the order it is carrying out, so it sends nothing while that order still stands.

Leader's team strategy (`Swarm.Brain`), built in stages:

**Game sizes.** Three plans, by how many players the game started with:

| Players | Plan |
|---|---|
| 2–5 (small) | 20 workers; Barracks → depot → tower → TechLab → 2nd Barracks → 2nd tower → backup Command Center (at 10 fighters); first wave at 15, then 12 |
| 6–9 (medium) | 30 workers; army first: Barracks → depot → a tower facing each neighbor (2) → 2nd Barracks → TechLab → 3rd Barracks → 2 more towers (4 in all) → backup Command Center (at 20 fighters); first wave at 15, then 12, at the weaker neighbor, no waiting for a tower square. Once a neighbor is eliminated, a depot goes on its ore (the side nearest us) with a tower: a second base in a corner next to us, not in the middle |
| 10+ (big) | 30 workers; three Barracks early and a square of 10 towers around the base; first wave at 18 once the square is up (or tick 900), then 15 |

1. **Economy (done):** grow to ~20 workers (30 in a big game; more while there is the ore for them: one for every 150 ore left in the fields we can mine or take, up to 60) while following a build order kept as data: Barracks
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
   Workers run for cover, whatever they are doing (mining, carrying, walking to their ore, or
   building: a site under fire waits): from an enemy fighter about to hit them, and, out of our towers' reach,
   from one within 6 tiles when the enemies there are stronger than our fighters and towers there
   or home is falling back (below). Cover is next to the closest of our Guard Towers on their side
   of the enemy (else the closest of our fighters or drop-offs on their side of it). They don't
   mine ore with an enemy fighter within 8 tiles (archers shoot from 4: the walk there is covered
   too). Workers only mine ore within 10 tiles of a drop-off, by a drop-off at home first (the Command
   Center and depots within 6 of it, as everywhere a depot farther out is an outpost), then by an
   outpost, once home's ore is gone or unsafe: the shortest trip, stacked as deep as it
   takes (the game has no limit on miners per deposit, and each mines at full speed), so with a
   depot two tiles from its field they mine and bank without walking. A miner moves over once
   another deposit's trip is 2 tiles shorter than its own (a new depot went up by fresh ore). With all of that unsafe, safe ore farther away on our side
   (where the rule below puts a depot), and with none on our side, ore clear of every enemy base
   (at least 14 tiles from every opponent's start and every enemy building we know of: the ore in
   the gap between two bases is on nobody's side); with no safe ore at all, an idle worker waits next to the
   closest of our towers instead of standing in the field.
   **Ore is remembered:** the server only sends the deposits in sight, but deposits never move and a
   Gather may name one in the fog, so the leader keeps every deposit it has seen (forgetting one
   once it should see it and doesn't: mined out, or once the server rejects a Gather on it as gone)
   and adds them to the view the brain and every unit plan with. Once we have a scout, the first one **surveys** our side for ore before taking its post:
   spots on two rings (10 and 20 tiles) around the Command Center, on our side of the map, each
   done once anything of ours sees it (or after 40 ticks of trying).
   **Ore for workers:** once a Barracks is up (or from tick 300 on), 100 ore (two workers) is kept
   back from everything but workers, and with fewer than 5 workers left, workers are trained before
   anything else. While the main base is raided or overrun, the reserve isn't spent on workers
   there (they only die); the backup Command Center's own workers have first claim on it: losing
   every worker with nothing banked would end the economy for good. When home has been short of ore for 30 ticks in a row (under
   3,000 left within reach of a drop-off, or under 100 for each worker, so the next depot is up
   before it runs out), a Resource
   Depot goes by the ore with the shortest trip of those out of reach (where idle workers go
   next; on our side first, else clear of every enemy base, and a field with at least 400 left),
   ahead of the build order, and in a big game without waiting for 15 fighters; while it goes up,
   workers with no ore in reach mine by it.
   **A spot where building keeps failing** (away from home: more than 10 tiles from the Command
   Center) is blocked for 300 ticks at three strikes: an order that failed or whose builder died,
   a worker sent to an abandoned site again, or what stood there destroyed (two strikes). No
   worker is sent to a site there, nothing new goes up within 2 tiles, and the next depot goes by
   another field (logged as `site_blocked`).
   And whenever 3 or more workers are mining one field more than 2 tiles from a drop-off (a
   depot going up counts) with at least 1,000 ore left, a depot goes right by that field, 2 tiles
   from the ore, right away: a
   worker stands one tile from each, so it mines and banks without a step; a depot costs one
   Soldier and saves them all the walk. Only a spot within 2 tiles counts (none open, none
   ordered, or the field would keep asking for another). The home ore waits for the build
   order's own depot. Depots only go by ore on our
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
   past the extras, another Barracks goes up whenever we are rich and every one we have is busy
   (two or more queued, none going up), up to 10;
   SiegeEngineering is researched and a SiegeWorkshop built, which keeps 2 Trebuchets, and one
   for every 2 finished towers of the opponent with the most we know of, up to 6. They wait
   at the rally point and, 2 or more at a time, go out with a wave. A wave with siege holds 9 tiles short of
   its target until the Trebuchets are there (at most 60 ticks). With towers within 10 of the
   target, the Trebuchets then shell them while the rest keeps holding: each attacks the known
   tower nearest it by name (attack-moving, the game fires a Trebuchet at the nearest unit, and at
   a building only with no unit in reach), which walks it to 7 tiles off, outside the tower's 5;
   one in the fog it walks to a tile it sees the tower from itself (6 off one way, no more than 3
   the other: inside its round sight of 7, outside every known tower's reach), exactly that tile.
   Everyone goes in once those towers are down, the Trebuchets are gone, or no tower has fallen
   for 90 ticks. Trebuchets step
   back from anything inside their 3-tile blind spot. A tower standing on its own (no other of
   theirs within 6) the wave takes together, shooting at us or not.
   **Trebuchets for their workers:** SiegeEngineering comes right after the first Weapons and
   Armor, from 15 fighters (it was 25 and the whole build order done). A Trebuchet out with a wave
   shells, before any tower, the biggest stack of enemy workers standing still on one tile in its
   reach (three or more: a shell hits everything on the tile it lands on, and their miners stand a
   dozen to a tile). A party also goes hunting with their army alive: Trebuchets at the rally
   point and four attackers or more go for a drop-off of theirs with no fighters of theirs we
   know of within 12 that the escort couldn't meet.
   **A siege party:** with their army gone (the attackers at the rally point are 1.5 times the
   fighters of theirs we know of, none included), the Trebuchets at the rally point go out
   without a wave's worth of attackers, one of them or more, with whoever is there. Their towers
   don't count against a party (it outranges them), and it isn't called back for being few; their
   fighters call it back as ever. The end-of-match push takes the Trebuchets too.
   **The opening** (two to five players): depot, Barracks, TechLab, a second and third Barracks,
   then the first tower, a fourth Barracks and the second tower. The depot by the home ore is the
   first thing built, at tick 0, by three
   workers (it used to wait for 9 workers, then for the army floor and the reserve: up at tick 199
   once). No Guard Tower before tick 100; then towers build up to 8 as we can pay (the bots that
   tower up first mostly lose, the ones that win end with 7 to 10). Another Barracks goes up
   whenever every finished one is busy and we can pay for it, rich or not, up to 14 (one going up
   at a time, and one more for every 750 ore in the bank), on its own order
   (apart from the one building at a time of the rest, which a run of depots and towers once kept
   busy for 300 ticks with 5,258 ore in the bank); by a base Command Center when there is no room
   left by the main one. Workers: one for every
   150 ore we can get at, up to 80. Home counts as short of ore under 150 for each worker.
   **Base Command Centers:** one more Command Center than we have at 16, 30 and 50 workers
   (with a Barracks up, 12 fighters or more, whatever the size of their army;
   one going up at a time, three builders; it has its own order, so the rest of the building
   carries on while they walk, its 400 held in the bank until they break ground; short of the 400
   every Barracks goes on training one at a time, only the second place in each queue waits), by
   the safest field worth one (how far from the nearest living enemy's start or known building, or
   twice how far from the middle of the map if less, up to 30; equally safe, the nearer us) that
   one of ours has seen in the last 45 ticks (the survey scout goes to look at the best candidate,
   and back every 20 ticks): 2,500
   ore or more, no drop-off of ours by it, at least 14 tiles from every living enemy's start and
   every building of theirs we know of, out of their towers' reach and 12 from their fighters we
   remember. It is a base, not the hidden backup (`View.bases`): a drop-off, an outpost with two
   towers, and it trains workers too (every base one a tick while we are short); a worker by it
   mines by it. On two- to four-player maps the ore we haven't seen counts: the map is mirrored
   left to right and top to bottom, so every deposit we have seen tells us three more (dropped
   once we look and find none). Fields farther from every enemy start than from ours come first.
   **The middle first:** until we have a base in the middle of the map (within a quarter of its
   width of the center), the fields there come before the safest, the nearest to us. The middle
   holds the most ore, and whoever sits there with an army keeps everyone else off it. With a
   base of ours there the army lives at it: the rally point is three tiles from it, toward the
   nearest enemy start, and it gets four towers. The usual nine guards stay at the main base,
   behind its tower nearest the enemy (it was a quarter of the fighters at home; see **A fixed
   home guard of nine**). The army is called back (the rally point
   is the main base's again) while enemy fighters come at the main base, within 15 tiles of its
   Command Center and nearer to it than to the forward base, more than those at home and its
   towers can meet, and all of ours with those towers are at least as strong as they are; it
   stays while they are there and for 20 ticks after.
   **An eliminated player's start** comes before all of them, and nothing of theirs the server
   still remembers counts (their buildings go with them). But only once a scout has seen it clear
   in the last 45 ticks: the survey scout goes there, and back every 20 ticks, while that field is
   worth a base. With no field worth one, the build order's hidden backup goes up as before.
   **Upgrades:** every tier of Weapons (units and towers), Armor (units) and Fortify (buildings,
   towers too), in the order Harvesting1, Harvesting2, Weapons1, Armor1, Armor2, Weapons2, Armor3,
   then SiegeEngineering and Fortify (all the Armor before SiegeEngineering:
   the house bots end with Armor3); a second TechLab at 25
   workers, ahead of the rest of the build order, so two are researched at a time.
   **Both Harvestings ahead of the rest, and the Tech Lab early:** each Harvesting is one more ore
   a mining tick (2, then 3, then 4) for every worker we ever have. The first Tech Lab is ordered
   at ten workers (it was thirteen) and built by two, so it is up in 20 ticks. The house bots had
   Harvesting1 at ticks 122 and 128 and we at 164: for those 40 ticks they mined 750 to 860 ore in
   20 ticks to our 510 on the same workers. Harvesting2 they had at tick 251, and we after all the
   Weapons, the Armor and SiegeEngineering.
   **These come first:** both Harvestings and every Weapons and Armor are started the tick a
   Tech Lab is free, ahead of every building, base, worker and fighter, and their ore is kept
   until it is there (`research_first/2`). One on one, a house bot had Weapons2 and Armor2 at
   ticks 385 and 391 and we at 441 and 431, behind two Command Centers and ten towers: 15 of its
   Soldiers killed 22 of ours and 12 workers at our base for 9, on an estimate of +0.5.
   **Out of ore, we go for whoever is on what is left:** with nothing left for us to mine (we have
   banked nothing for 100 ticks and nobody is mining, the map not proven empty), the opponent with
   the most ore we know of within 16 tiles of their start or a building of theirs (1,000 or more)
   is who the next wave goes after, neighbor or not, if our fighters are 1.5 times what we know
   they have, towers included. Otherwise the weaker neighbor, as ever. Ore by a
   living opponent is nowhere we may go: we looked everywhere else, found none, and 57 workers
   stood idle for 600 ticks with 4,500 ore by the base of one who had eight fighters to our 29;
   our waves went at another who had none, and a third took that base and mined it.
   **A depot by ore our workers walk for comes first:** ahead of the research, the first base,
   the fighters and the Barracks, out of the workers' reserve too, and its 100 is kept until it is
   there. It is built by the workers mining or walking to that ore, three at least (the closest
   free ones make up the number). It used to come with the rest of the building, after the army
   floor: below the floor it got nothing, and one builder was sent alone to a depot fifty workers
   were waiting on. With three or four players a depot still only goes to a field in the middle
   within 8 tiles of a Command Center of ours, but not once there is no ore left by any drop-off
   of ours: then that ore is all there is.
   A depot goes two tiles from the ore; with a building of theirs within 4 tiles of that ore (seen
   or remembered) and no drop-off of ours within three, the open tile three from it will do, next
   to theirs. A tile a building of theirs we remember stands on is not open. One of their depots
   stood where ours was to go: ours was ordered there three times, and fifty workers walked ten
   tiles each way for 110 ticks until we had knocked theirs down.
   **A look right after a beaten raid:** when eight or more of a raid's fighters have died at
   our base and none is left in sight, a look done before the raid was last here no longer
   counts as fresh, and a scout goes at once. With 43 Soldiers to their 5 after a raid of 74, the
   count still said 75, and the counterattack waited 41 ticks for the next routine look.
   **No wave without a look:** an ordinary wave only leaves within 60 ticks of a scout having got
   to its look at the target itself (within 3 tiles of it, or a Scout with it well inside its
   sight): their base, not a spot short of it. A scout that dies on the way in, or doesn't get
   there in time, having seen their fighters since it left: that is a look, and their army then
   counts for at least what their score says (the ore value of everything they have alive, less
   their buildings we know of and as many workers as we have): it only saw the nearest few. A
   look that saw nothing of them and never got there is no look (it is asked for again);
   with no scout at all the wave waits for one. A counterattack right after a beaten raid, a
   siege party and the end-of-match push go without.
   **Their army as last counted:** the most we have known of a player's army in the last 150
   ticks (less what we kill of it) counts wherever their strength is weighed, whatever is in sight
   now: a wave doesn't leave on "0 known" after a scout looked at the wrong spot, and home only
   goes out to help where it can take that whole count. While it is more than all our fighters,
   nobody escorts an outpost (until it is under 0.8 of ours): the army keeps together at home.
   A scout's look that counts less brings the count down, to no less than half of it (a scout sees
   one spot).
   **Nothing left to mine** (from tick 300), two ways, neither going by what we happen to see.
   *Mined out*, for certain: the ore the map started with (72,000 with two to four players, 14,100
   a player on a ring, scaled by our home piles), less what every player has banked (the server
   reports it for all), is under 2% of it. That count only errs one way: ore mined and never
   banked (lost over a storage cap, or with the worker carrying it) still counts as left, up to a
   sixth of the map in the games on record. So also *stalled*: we have banked nothing for 100
   ticks with 5 workers or more and none mining. Stalled, we go and find the ore: up to 4 idle
   workers walk each to its own place we haven't looked at (where the mirrored map says there is
   ore we haven't seen, and a grid over the map 12 apart; only where we may go: clear of every
   living enemy's base and towers), until we bank again or there is nowhere left to look. Ore
   found is mined, and gets its depot, as ever. Either way no more workers are trained until we
   bank again, and with no Scout alive the idle worker with the lowest id does the look before a
   wave. The last opponent's Command Center isn't spared once the map is mined out, or once we are
   stalled with them down to it and our workers have looked everywhere and found none.
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
   runs through to the target itself and doesn't step back from anything on that run (what it
   sees on the way in is worth the scout), then goes back to its post; the launch waits for the
   look (at most 40 ticks), except for a counterattack. While a wave is out, the scout watching its
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

### Reading the opponents (`Swarm.Reads`)

The leader keeps a read of each opponent, from what we remember of their units, the buildings of
theirs we know, their army as we count it and their ore banked (the scoreboard has it for
everyone), against ours. Nothing before a scout has looked at them, nor before tick 120.

| Read | What says so | What we do |
|---|---|---|
| `:boom` | an army of 3 Soldiers' worth or less (or under 0.3 of ours), and two Command Centers or more, five towers or more, or 1.25 times our ore banked | their bases without towers are gone for early (below) |
| `:flood` | an army of 6 or more and 0.7 of ours or more | as ever: held at our towers |
| `:siege` | Trebuchets seen, or a smaller army with 40% Archers or more | as ever (for now) |
| `:harass` | 6 Scouts or more seen, fewer than 6 fighters, one Command Center | as ever (for now) |
| `:unknown` | none of the above | as ever |

A read changes only once what we see has said the same thing for 30 ticks, with a line in the
decision log (`kind=read`) giving what it was read from.

**A boom's open bases.** A neighbor that reads as a boom is the opponent we go after, before the
weaker ones: by its score it is the strongest, and left alone it only gets stronger (a bot with
no fighters at all took 72% of a map's ore behind 145 towers). With 8 attackers or more at the
rally point, a wave leaves for a Command Center or Resource Depot of theirs with two finished
towers or fewer within 7 tiles, if the attackers are 1.5 times those towers and the fighters we
remember by it: no waiting for a full wave or for our own towers, and their towers elsewhere don't
count. The base gone (or towered up), it goes on to the next open one, and comes home when there
is none. Everything that calls a wave home still does.

**Never a smaller army than theirs.** The army floor (below which the Barracks train before
anything is built, any base is founded and any worker is trained; only the first research and our
first base come ahead of it: that base's 400 is kept while each Barracks keeps one Soldier in its
queue. With the floor at their army and our income theirs, nothing was ever left for a base: we
ended one game on 43 workers and one base against 64 on four) is, in every game and from tick 120, the biggest army of any opponent still in going
by the scoreboard (the same count a look falls back on; their buildings count for what ours are
worth when we know of fewer, not as army), with no limit to it. No look or read is needed. With two
neighbors that read as floods it is also the bigger of the two as we know it. What the Barracks
can't take still goes to the rest.
While our army is under that floor, another Barracks comes right after the fighters and ahead
of every other building and base, as soon as every Barracks we have is training at all, up to
the fourteen there may be; the ore for the next one is kept until it is there.
It used to hold only with two opponents or more, and up to 40 Soldiers and six Barracks (80 and
ten with three or four players): we stopped keeping up just when their army got big. One on one the floor was then 10 fighters at tick 400, and everything else
came first: our four Barracks trained nothing for 25 ticks with 500 ore in the bank, and we had 12
Soldiers to their 41.

**Inside our base, everyone fights.** A raid that would beat us is stayed out of only while it
is outside the base. Once one of them is within reach of a finished Guard Tower of ours (its range
plus one) or within 3 tiles of our Command Center, there is nowhere left to stay out of its way:
every fighter attacks, whatever the estimate (`Roles.inside?/2`). Workers fight in two cases only
(`UnitBrain.fighting/3`). With the map mined out, a worker within 20 tiles of a raider on us
attacks it: there is nothing else it is for. On the game's own engine, 73 Soldiers beat 47 with
their 67 workers standing by five times in five with 24 to 34 left; with the workers fighting the
47 won five in five and none of them died (both sides Weapons2 and Armor3: a worker hits a Soldier
for 4 and takes four hits to kill). And at our last base, with a raid we would lose to inside it
and no other base to go to: 77 and 66 workers died at the main base without a blow. While there
is ore and somewhere to go they run: 75 who were the whole economy fought at one base of several
at tick 400, and the match went with them.

**Help only under our towers, and their serum answered anywhere.** In every game the army only
goes out to help where a finished tower of ours reaches (its range plus one) or within 5 tiles of
a Command Center of ours; it was only so with two or more opponents. And when their fighters are
on the serum in a fight eight or more of our Soldiers are in, a group worth eight Soldiers or
more, ours is taken that tick, raid or not. One on one, 61 of ours went out to a depot in the
middle 20 tiles from our nearest tower; their serum went on in a fight a few tiles off it, ours
12 ticks later with 38 dead, and 87 Soldiers died for 28.

**Workers leave a base ahead of a big raid, win or lose.** When a group worth eight Soldiers or
more is within 16 tiles of a Command Center of ours that isn't the main one, or of a depot of ours
(and farther than that from the main one), every worker within 16 tiles of that group goes to the nearest Command Center
of ours the group is farther than 16 from, and the ore by the base they left isn't walked back to
while the raid is there (`Roles.evacuations/2`). Whatever the estimate says: three games went on
one raid at the base every worker mined at, 75, 61 and 60 of them, the last in a fight we won 69
Soldiers for 28. Nobody leaves the main base this way.

**Trebuchets and the towers in their way.** A wave with Trebuchets holds at a staging point nine
tiles short of its target on our side; that point is moved back toward where the wave leaves
from, a tile at a time, until it is out of every known enemy tower's reach by three tiles. And a
Trebuchet out with a wave shells a known tower within eight tiles of it before it walks anywhere,
the staging point included. Nine tiles short of a main base was inside the reach of three towers
of the base in front of it: two Trebuchets parked seven tiles from one of them walked there on a
plain move and died without a shot. A siege party only goes for a base "their army isn't at" when
the fighters of theirs we remember, wherever they are, are half their army as we count it or
more: with none remembered every base looked clear, and that party left for the base their 70
stood by.

**Behind on score with the map mined out and nobody armed, everyone goes.** The all-in (every
fighter attacks, behind on score) used to wait for the last 300 ticks. It now also starts as soon
as the map is mined out and no opponent's army by the scoreboard is more than our fighters and our
workers at 0.3 of a Soldier each; the workers go with them to the target. We stood 20,000 points
behind for 1,100 ticks with 7 Soldiers and 65 idle workers, one opponent with no Soldier and 89
workers, the other with nine. (Whether the map is mined out is worked out in the leader's plan,
after the view the units are sent: it goes to them in the strategy, `strategy.no_ore`. Read off
the view, as it first was, no worker ever fought on a mined-out map.)

**Falling back from an army starts when it is our fight.** A fighter at home falls back from a
group that would beat us, eight Soldiers' worth or more, once it is within 10 tiles, raid or not
(a smaller one at two tiles, as ever), to the nearest tower of a base of ours whether they are
near that tower yet or not: in its reach, everyone fights there. 92 came at a base where 67 of
ours stood six tiles in front of its towers; nobody moved until they were on them and on the
serum, and 66 died out there for about 25.

**A depot is not a base.** A tower counts as a base's only within 8 tiles of a finished Command
Center of ours (`Roles.base_towers/1`). A raid inside a depot's tower's reach is not "inside our
base": nobody is held there to fight it at a loss, and a fight we would lose is fallen back from
to a base's tower, never a depot's. And home only goes out to help away from every Command Center
of ours when it is clearly stronger (1.3 times what is there, and what we have known of their
army lately), not at even. 92 of ours went out at even to a depot in the middle against 94,
arrived in pieces, were told to fall back to that depot's own tower, and fought there as "inside
our base": 75 died for about 20. (Against theirs on the serum within six tiles they still stand,
depot or not: running from a Soldier twice as fast is dying with our backs turned.)

**A fixed home guard of nine.** The newest nine fighters at home guard the main base, the army
living at a forward base or not (the tests keep seven, `config/test.exs`: their fixtures count
attackers as "soldiers less seven"). With a forward base it used to be a quarter of all the
fighters at home: 27 of 111 stood at the main base, 30 tiles off, when 92 came at the forward one.
Against an army neither number holds; against a small raid nine do, and the army is called home
when more than that comes (`home_call/3`).

**An army is what we have seen of it, less what we killed.** Enemy fighters seen together
(within three tiles of each other, a chain counts) are one pack, and stay one
(`Swarm.Brain.remember_packs/2`). While any of a pack is in sight, the ones out of sight count
with them, standing for the estimate by the one in sight nearest where they were last seen
(`View.recent_enemies`, so the fight's estimate, help and the serum all see them): for 40 ticks
after they were last seen, unless we saw them die, and only if they could have walked there with
the rest (three tiles and one for every tick since; two that left their army 40 tiles back are
two). 78 came through the middle; the count in sight went 5, 12, 17, 63, 12, 11, 72 inside ten
ticks, and the call flipped with it: "gather next to them", "stay out", "go in" against 11, "go
in" against 72. 64 Soldiers became 9 in 20 ticks, for 27.

**A depot on its own calls nobody.** A wave that is out comes home only for what hits a base of
ours (within 10 of a finished Command Center, or in reach of its towers: `Roles.at_base?/2`,
`Roles.base_recall/2`) or shells our buildings; not for raiders by a depot on its own or by
workers in the field (no new wave leaves while those are there, `Roles.recall/2` as before). And
an army (eight Soldiers' worth or more) at no base of ours pulls no attacker from home into its
fight: the workers leave it (`Roles.evacuations/2`), it is for those within ten tiles of it, and
for help only where home can clearly take it. A few raiders in the field are still gathered for
and met. In that game five Soldiers by a depot in the middle called 35 home from the Economist's
base, to gather next to the 78 they were the front of.

**The serum for a raid waits for the fight.** Like the answer to theirs, ours for a raid is only
taken once eight of our Soldiers are within six tiles of that raid. It was taken with the raid
in sight and the army 20 tiles off: a third of it was spent walking.

**There is always a scout, and no ore known is a stall at once.** From tick 120, with no scout
alive or on its way and a Barracks up, one is trained ahead of the army floor, in the shortest
queue, and the ore waits for it if we are short (`first_scout/2`); the second still comes from
what is left over. And with no ore known at all, nobody mining and nothing banked for 10 ticks,
we are stalled whatever the tick (`nothing_to_mine/2`): workers go looking (`ore_search/3`)
without waiting out the hundred ticks. Among two bigger armies the floor was never met, every
Barracks was full of Soldiers all game and no scout was ever trained: the only ore we ever saw
was the home field, and when it ran out at tick 270 thirty workers stood for a hundred ticks ten
tiles from 6,000, with no base, no depot, and (no look at anyone) no wave.

**The last look.** The first scout comes ahead of research and the first base too (those hold
the ore; it is 75 once). With the map mined out, what is kept back for workers is kept for a
scout instead: no worker will be trained again. And when nobody can go and look (no scout alive
or on its way, no worker to go in its place, no Barracks we can pay for one at), the wave
doesn't wait for a look: it goes on what we know of their army or the scoreboard's count of it,
whichever is more. 120 Soldiers stood 600 ticks in front of an opponent with no army: every
scout and worker dead, 118 ore of which 100 was the workers', and "a look first" every tick.

**Out of ore we will mine, the army takes a field.** Workers only mine ore by our drop-offs, on
our side of the map, or clear of every enemy building; with all of that gone they stand under
our towers whatever is left elsewhere. After 10 ticks with nothing banked and no worker mining
or walking to ore (and ore still known: with none known they go looking, above), the leader
claims a field (`Swarm.Brain.claim/2`, `strategy.claim`): the known ore nearest a Command Center
of ours that is in no enemy tower's reach, not at an enemy's start, and that home can take.
Home's attackers go there (it is where they help when nothing else needs it), their units within
8 tiles of it are fair game, and they stay. Once five of ours are within 6 tiles of it the
workers mine it, enemy ground or not, and a depot goes up by it, in the middle too. No wave
leaves meanwhile and one that is out comes home. It holds while the field has ore; it is given
up when what is there is 1.3 times what home can bring, and then not taken again for 60 ticks.
53 workers stood for 110 ticks with 3,188 ore 12 tiles from our second base: another player's
28 workers were on it, unguarded, while 16 of our 30 Soldiers walked to the far corner.

**Between two armies no wave leaves.** With two or more opponents in, when two of those around us (below)
have an army of six Soldiers' worth or more that is over half of ours (by what we remember or
the scoreboard, whichever is more; not a neighbor a look has read as a boom), no wave leaves
(`between_armies/2`): whoever of the three fights first is finished by the one that didn't. We
had 84 Soldiers to their 81 and 75, traded 55 for 46 with one, and the other walked in with 87
against 41. It lifts when one of them has spent its army, on us or on anyone. And taking a field
(above) is for want of ore, not for hiding: it doesn't start with raiders on us or within ten
ticks of them, with home fallen back to the towers (or 25 ticks after), or with a base left by
its workers. They fell back from 69 raiders, ten ticks later that read as "nothing to mine", and
the army was sent to a field in the middle with 87 a few tiles from it.

**A field is held by a guard, and mined behind it.** Three things from a game won on a field we
took 350 ticks late (home mined out; 43 workers walked to the middle, an Archer or two came into
reach, all of them walked home, and again: nothing banked from tick 390 to 740).
*Driven off the ore* starts a claim as well as idleness does: nothing banked for 40 ticks and no
worker mining or carrying, whoever is walking where, with no enemy at a base of ours and home not
fallen back (`claim/2`). Waiting for ten quiet ticks with nobody "on the way to ore" took 200.
*The field has a guard, not the army*: three times what the enemy has had there in the last 40
ticks, ten at least, of home's attackers nearest it (`guarded/3`, `strategy.claim_guard`, the
`{:field, pos}` job in `Roles.home_roles/2`); it keeps its members, replaces its dead and grows
with what comes. Everyone else stays at the towers: a raid at a held field pulls no one from
home (`Roles.find_groups/2`), where 80 used to set out for two Archers and turn back, twenty
times, and were out on such a walk when 80 came at the base. The claim is still given up at the
old odds against all of home, and the guard fights by the same estimate as anyone: it stays out
of what would beat it.
*Workers on a held field stay on it* (`UnitBrain.claimed_ore/1`, `refuge/3`): a pile is left
only while an enemy fighter could hit a worker at it (its reach and two steps), not for one
within eight tiles; a worker in reach steps back behind the guard, or a few tiles straight back
with the guard all in the fight, and not to a tower 25 tiles away.

**Help ends with a fall-back, and between two armies it is weighed against them.** Help
committed at tick 386 sat through a 60-tick fight at our towers; the tick the fall-back lifted,
57 Soldiers set off for where it had been, 20 tiles out, stopped 12 tiles out to kill a
neighbor's workers, and its 67 Soldiers killed 54 of them (63 and four towers had just beaten 22
of the same army for 9). So: home fallen back to its towers calls help off and commits to none
(`help/3`), with the usual rest before the next. And while we are between two armies (the hold on
the wave, `between_armies/2`), help at a spot more than 12 tiles from where the army lives needs
home to be a match for the bigger of them too, whatever is at the spot, and is called off when
that one grows to 1.3 times it (`army_around/4`). A field is not claimed with nobody at home to
guard it.

**Caught in the open, an army stands; and a second push is counted like the first.** Two armies
were lost walking away from a fight the estimate said to stay out of: 57 from 67 at -0.47,
twelve tiles from a tower (54 died for 19), and 66 from 70 six tiles from one. They walk as fast
as we do. So when half or more of ours in a fight are already in the enemy's reach, there are
eight of us or more, and all of us together are no worse than -0.7, everyone in it stands and
fights (`UnitBrain.caught?/1`, `group.engaged` from `Roles.estimate/3`); not yet caught, or
hopelessly behind, they fall back as before. The second of those armies should not have been
there: the rest of an army counted behind the part in sight (above) only ever worked on a
player's first push, because "since when they have been out" was kept for as long as we
remembered any fighter of theirs, and a scout at their base remembers one all game. It is now
`{first, last}` seen out, and fifteen ticks without seeing them out makes the next coming out a
new one (`behind_since/3`): ten in sight are sixty again, eleven ticks sooner, and the fall-back
to the towers at ten tiles has time to happen.

**Research: the first tier of each, then nothing more until tick 320.** Harvesting1, Weapons1,
Armor1; everything else (`@research_late`: the second tiers, Armor3, SiegeEngineering, the Fortifys) not before tick 320
(`@research_late_from`), and their ore is not kept back meanwhile. In six four-player games we
had five upgrades done by tick 320 (850 ore) to each Formics' three or four (400 to 600), four
or five towers to their two, and 34 to 42 fighters to their 40 to 54 when the first push came
at ticks 300 to 330. Their Weapons1 was in 40 to 70 ticks before ours, and Harvesting2 had
bought nothing by then: the home field's 9,000 is mined by tick 300 with it or without.

**Figures never take the game down.** `Swarm.Metrics.record_tick/1` runs inside the leader's
tick; it had no name for the job `{:field, pos}`, and for every tick a field was held the game
loop crashed and restarted (25 times in 106 ticks in one match, lost with the workers dying and
1,136 ore unspent). Any job with something to it is named by its first part now, and whatever
else goes wrong in there is logged and the tick goes on.

**Their army by the scoreboard doesn't shrink as we build.** `army_by_score/2` is what a player
has alive less their buildings and workers, neither of which we can see; both were taken to be
what we have. With 68 workers and eight towers to a Formics' 37 and two, its 64 fighters read as
37, which was half of ours: the hold between two armies lifted, 47 left for a third player, met
82 in the middle on the way home, and 73 were 9. No more than 40 workers are taken off now, and
of our own towers no more than two (what the house bots have): the error is toward a bigger
army, against a real boomer by some twenty Soldiers.

**A player still in with nothing we know of is looked for.** We razed the last base of theirs we
knew at tick 1375, behind on score; they had another in a corner 50 tiles away, built at tick
576. The wave's target fell back to their start, one Soldier stood on it for 425 ticks with 55
idle workers at home, and they won on the clock. Now, with no building of theirs known and
their start seen empty, the wave's target is the nearest place on a six-tile grid over the whole
map that nothing of ours has seen since the looking began (`sweep/4`, `memory.sweep`); a place
not reached in 60 ticks is given up on; with the map mined out eight idle workers each take a
place too (`strategy.search`, like the search for ore); been everywhere, it starts again. What
turns up is remembered by the server and is the target the usual way.

**One on one.** Three things, from two games lost to a Formics: level at tick 300 (38 to 42,
40 to 43), then 72 workers, four Command Centers and nine towers to its 50, 3 and 2 by tick 390,
when it came with everything it had, 54 to our 51, and after that 80 workers and 33 fighters to
its 77. *The workers don't outnumber the fighters* (`lean?/1`): with 30 workers or more and as
many as we have fighters, no worker is trained, no base after the first is founded and nothing
past the first tier is researched, until the fighters have caught up. Not "below their army by
the scoreboard": against a Formics that booms, one on one, the scoreboard read 109 Soldiers'
worth when it had 58 (its ten Barracks and 86 workers are taken to be what we have), and that
would have kept us at the floor all game. *Up to 110 workers* (`@duel_max_workers`; 80 with
more players): two players share the map's 72,000, and a house bot goes to 115. *The wave is
weighed against the scoreboard* here as everywhere (`army_by_score/2` in the launch): a look at
its base counted the 10 at home, 31 left on "19 known" for 50, and 14 came back. That number
errs high one on one, as said: waves leave late or not at all against a boomer.

**The serum first, and everyone at the fight.** A Formics' 54 were seen coming for fifteen
ticks at a base of ours with three towers; we had 60 fighters and met them with 45, their serum
came on as they arrived and ours two ticks later (an order for it takes two ticks), and 46 died
for 11: those two ticks of 54 hitting twice as hard were ten of ours, and the fight. So, *first*
(`serum_moment?/3`): an army at a base of ours worth three quarters of all of home or more,
whose player we have not seen on theirs (`memory.serum_theirs`), gets ours when it is nine tiles
from eight of our Soldiers, if the fight with it on is ours. They are coming to us, so nothing
of it is spent walking; with theirs spent there is no race and the older measures hold. And
*one on one, nobody stays at a post* (`Roles.mustering?/1`): with enemy fighters worth eight
Soldiers or more within 24 tiles of a base of ours, there are no guards at the main base and no
escorts at the outposts (one opponent has one army, and it is there), and no wave leaves.

**Who is beside us, and who is around us.** Our neighbors are the two opponents nearest in
steps; from a corner all three others are as far (a diagonal step costs what a straight one
does), and of those the nearer in a straight line are the neighbors (`Roles.neighbors/1`): the
two beside us, never the one across the map. Broken by slot, the neighbors were the one across
the map and one beside us: the wave went across the map at tick 226, and the Formics beside us
was never looked at or counted. Everyone as many steps away as the farther neighbor is around us
(`Roles.around/1`), and the hold between two armies counts all of them: any two with armies
hold the wave, and the two biggest are named.

**The rest of an army is behind the part in sight.** When four or more of a player's fighters
(not Scouts) are in sight more than 15 tiles from their start, what the scoreboard says they
have (`army_by_score/2`) less every fighter of theirs we remember (in sight, or seen in the
last 40 ticks, anywhere) is taken to be with them: that many Soldiers standing by the one in
sight nearest their start, in the fight's estimate and everything else that reads
`recent_enemies` (`Swarm.Brain.behind/3`). For 15 ticks from when we first saw them out: by then
a column has walked into sight, and what we have seen is what there is. Nine Soldiers came into
sight by our base in the middle with 40 on the scoreboard; on +0.93 against nine, 29 of ours
went in, three ticks later it was 34 and 11 Archers, and the army was gone in 20 ticks. The
fight's note says how many of the count nobody has seen.

**Down to one opponent, the army is in one place.** In a game that began with three players or
more, with one opponent left (`View.last_one/1`): no guard is left at home and no escorts at the
outposts, and the army lives at our base nearest their start (the main one if that is nearest).
With 92 fighters to their 89, 22 were at home and the rest strung through the middle when the 89
came.

**A lost base is left for the next one, by its workers.** When a raid we would lose to is inside
a base of ours that isn't the main one, and another finished Command Center of ours is more than
10 tiles from it, the workers there go to the nearest such one (`Roles.retreat/2`). The fighters
fight where they are, as inside any base of ours. For a while they left too: 98 of them by a base
with towers, with 91 on the serum at hand, walked for the main base and killed about 25 for all 98.

**The serum is a fight, ours or theirs.** Ours is taken for a raid worth it that is an even
fight or worse without it and not against us with it (the fight's own estimate, worked out with
it on), or against theirs: once eight of our Soldiers are within six tiles of their fighters on
it, in a fight that is against us with theirs on (13 of theirs on it raided a base where we had
17 and were winning at +0.73: ours went on for six kills, and 400 ticks later the other house
bot's 94 came on theirs with ours gone). With ours on, nobody stays out of a fight the estimate doesn't have us losing (the usual call
waits for more than even before going back into one): it was taken with 82 coming into sight, the
call that tick was "stay out", 56 Soldiers walked back to the towers with it on, and it got 5
kills. A fight we would lose with it on is still stayed out of, and it isn't taken for one. For a
while it was taken whatever the odds once a raid was inside a base of ours, and everyone stood
with it on: inside the towers of a depot in the middle that was 61 of ours against 86 at -0.68,
and 75 died for 45. With theirs on within six tiles of a fighter of ours, that fighter stands and
fights whatever the odds: a Soldier on the serum is twice as fast as one running.

**Three or four players: the nearest field first.** The next base goes by the field worth one
nearest our own Command Center, the middle like any other, and by none farther from home than the
middle is (by 4 tiles) while every opponent is still in. It waits until a scout has seen that
field (with no scout alive, any field seen lately, as in other games). Only our first base comes
ahead of the army floor; the next ones wait until our army is theirs. A base's towers are ordered
while it is still going up, and a depot only goes to a field in the middle within 8 tiles of a
finished Command Center of ours (the base by our nearest field is just inside the middle, and "a
base of ours in the middle" let a depot go up 11 tiles past it: the army went out to it).
(The middle used to come first, its Command Center and four towers ahead of the fighters for 120
ticks, and any other base with them. Two house bots each took the field nine tiles from their
base. We took the middle 25 tiles off, then a field 41 tiles off, with the one nine tiles from
ours left to last: 30 Soldiers to their 43 and 45 at tick 300, and 34 at the middle with 22 at
home when 75 came.)

**Help under our towers only.** With two or more opponents in, the army only goes out to help
at a spot within reach of a finished Guard Tower of ours (its range plus one) or within 5 tiles of
a Command Center of ours.

**Three or four players: mining under cover, more Barracks.** Workers mine our home ore, ore
within reach of a finished Guard Tower of ours, or within 6 tiles of a Command Center of ours;
with none of that left, any ore as before. The army floor goes up to 80 Soldiers' worth there and
the Barracks that come first to ten.

**A wave against the scoreboard.** With two or more opponents in, the army a wave is weighed
against is at least theirs by the scoreboard, whatever a scout saw at their base: their army is
often out. And a fight we would lose is fallen back from to our tower nearest us, one up to 4
tiles nearer them than us included, not only those strictly on our side.

**The serum.** Taken when a raid worth it (8 Soldiers' worth or more) is inside our base, where
everyone fights it, with eight or more of our Soldiers in that fight, whatever the odds; or, with
the raid still outside, when the estimate with it has us ahead of a raid that size; or in answer
to theirs.

**Soldiers only.** The Barracks train Soldiers and no Archers (it was one Archer to two
Soldiers). Run on the game's own engine with the same ore a side, 30 Soldiers beat 20 Soldiers and
8 Archers five times in five, kiting or not, and 60 beat 40 and 16: Soldiers are the faster, and an
Archer's range is worth a few ticks of shots before they are on it. Archers only came out ahead
attacking an army that stood still. (The Archer rules stay, for any we still have.)

**No army by the scoreboard.** An opponent whose score shows 1,500 ore or less alive outside the
buildings we know of has no army: a wave of eight or more may leave at them without a look, and
their army counts for that much at most, whatever we counted last.

**Help past the towers.** With two or more opponents in, home only commits to help at an outpost
or by our workers if it can also take the army, by the scoreboard, of whoever is raiding there,
looked at or not. And help follows a fight no more than 3 tiles farther from home than where it
committed.

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
