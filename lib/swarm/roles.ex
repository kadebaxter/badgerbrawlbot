defmodule Swarm.Roles do
  @moduledoc """
  Who does what, worked out from the view and the strategy alone. Pure and deterministic, so
  the leader and every unit get the same answer without messaging each other.

  A fighter is one of:

  - `:wave`: it left with the current wave (its id is in `strategy.wave.members`)
  - `:guard`: one of the `@guards` newest fighters at home; holds the main base.
  - `{:escort, outpost}`: holds an outpost (a Resource Depot more than `@outpost_distance` from
    the Command Center) while workers mine there, as a group of `@escort_group` (the outpost's
    towers do the rest), or none if that many can't be spared. Fighters already there keep
    the job; a gap goes to the closest free fighter.
  - `:attacker`: everyone else at home; waits at the rally point for the next wave, and goes to
    help wherever a base or our workers are attacked

  Scouts are none of these (`:scout`): they explore and never fight on purpose. Our Trebuchets
  are their own: they wait at the rally point (`:siege_out`) and go out with a wave (`:wave`).
  None stay home: for the ore, Soldiers and towers defend far better.

  It also decides who fights whom (`target/3`), the same way on every node.
  """

  alias Swarm.View

  @guards 7
  # Our neighbors: the opponents nearest us, whom we attack and watch most closely.
  @neighbors 2
  # Enemy fighters this close to one of our workers are attacking our economy.
  @worker_cover 5
  @escort_group 3
  @min_escort_group 3
  # A depot farther than this from the Command Center is an outpost.
  @outpost_distance 6
  # The base is everything this close to the Command Center. Fighters at home don't chase
  # enemies out of it.
  @base_radius 10
  # Enemy buildings this close to one of our bases are at our door: a tower there gets a strike,
  # a site gets razed.
  @home_reach 12
  # Defenders this close to a raider can meet it; a finished tower is worth this many Soldiers.
  @defend_reach 12
  # A Guard Tower in Soldiers (see `strength/2`): ours low, theirs high.
  @own_tower_worth 3
  @enemy_tower_worth 4
  # How far a fighter looks for something to fight; farther for a Trebuchet, which shells us from
  # 7 tiles away.
  @engage_radius 6
  # A Command Center our fighters by it can bring down in this many ticks is finished first.
  @finish_ticks 5
  @siege_engage_radius 10
  # A Trebuchet this close to one of our buildings is attacking it (its range is 7).
  @siege_reach 9
  # Tiles next to a unit: at most this many melee attackers fit around one target.
  @melee_slots 8

  # From the bot guide's unit table. The tower's cooldown isn't listed; 1 is a guess. A
  # Trebuchet can't hit anything closer than `min_range`.
  @stats %{
    "Trebuchet" => %{hp: 150, damage: 40, armor: 0, range: 7, min_range: 3, cooldown: 8},
    "Worker" => %{hp: 40, damage: 4, armor: 0, range: 1, cooldown: 1},
    "Soldier" => %{hp: 110, damage: 9, armor: 1, range: 1, cooldown: 1},
    "Archer" => %{hp: 60, damage: 12, armor: 0, range: 4, cooldown: 2},
    "Scout" => %{hp: 55, damage: 5, armor: 0, range: 1, cooldown: 1},
    "GuardTower" => %{hp: 500, damage: 10, armor: 2, range: 5, cooldown: 1}
  }

  # A full-HP Soldier's strength (its HP x damage per tick, the old measure, so numbers stay where
  # they were), and every unit's cost (the bot guide's table): see `strength/2`.
  @soldier 990
  @cost %{"Worker" => 50, "Soldier" => 100, "Archer" => 125, "Scout" => 75, "Trebuchet" => 350}

  # The lists `share/2` works with but leaves out of what it hands on (`localize/1`).
  @local_lists [:fighters, :enemy_fighters, :enemy_towers, :our_towers]

  # `all_in` is set on the end-of-match push that takes every fighter.
  # `owner` is the opponent (player slot) it is after. A wave with Trebuchets holds at `staging`
  # until `released` (set when they arrive); `at` is the tick it launched.
  @type wave ::
          %{
            required(:id) => pos_integer(),
            required(:members) => [integer()],
            optional(:owner) => non_neg_integer() | nil,
            optional(:all_in) => true,
            optional(:staging) => View.pos() | nil,
            optional(:released) => boolean(),
            optional(:at) => non_neg_integer()
          }
          | nil
  @type threat :: %{pos: {integer, integer}, size: non_neg_integer()} | nil

  @type role :: :wave | :guard | {:escort, View.pos()} | :attacker | :scout | :siege_out

  @spec role(View.t(), wave(), integer()) :: role()
  def role(%View{} = v, wave, id) do
    cond do
      match?(%{"type" => "Scout"}, View.my_unit(v, id)) -> :scout
      match?(%{"type" => "Trebuchet"}, View.my_unit(v, id)) -> siege_role(v, wave, id)
      id in members(wave) -> :wave
      true -> Map.get(home_roles(v, wave), id, :attacker)
    end
  end

  @doc """
  The job of each fighter at home. Sticky, so nobody walks across the map when a new unit is
  trained:

  1. fighters already at an outpost escort it, up to what it needs
  2. the newest of the rest guard the main base (new units appear there anyway)
  3. an outpost still short gets the closest of the rest
  4. everyone else attacks
  """
  def home_roles(%View{shared: %{wave: wave, home_roles: roles}}, wave), do: roles

  def home_roles(%View{} = v, wave) do
    newest_first = &Enum.sort_by(&1, fn u -> u["id"] end, :desc)
    manned = Enum.filter(outposts(v), &(miners(v, &1) > 0))

    # 1. Fighters already at an outpost (with miners) stay, up to a full group.
    {groups, pool} =
      Enum.reduce(manned, {%{}, newest_first.(home(v, wave))}, fn o, {groups, pool} ->
        {here, away} = Enum.split_with(pool, &(View.dist(View.pos(&1), o) <= @base_radius))
        {taken, extra} = Enum.split(here, @escort_group)
        {Map.put(groups, o, taken), newest_first.(away ++ extra)}
      end)

    # 2. The newest of the rest guard the main base.
    {guards, pool} = Enum.split(pool, @guards)

    # 3. Each group is filled up from the closest of the rest. One that can't reach
    #    `@min_escort_group` isn't worth having: those fighters attack instead.
    {groups, attackers} =
      Enum.reduce(manned, {groups, pool}, fn o, {groups, pool} ->
        by_distance = Enum.sort_by(pool, &{View.dist(View.pos(&1), o), -&1["id"]})
        {taken, rest} = Enum.split(by_distance, @escort_group - length(groups[o]))
        group = groups[o] ++ taken

        if length(group) >= @min_escort_group,
          do: {Map.put(groups, o, group), rest},
          else: {Map.delete(groups, o), rest ++ group}
      end)

    escorts = for {o, group} <- groups, u <- group, do: {u["id"], {:escort, o}}
    Map.new(Enum.map(guards, &{&1["id"], :guard}) ++ escorts ++ Enum.map(attackers, &{&1["id"], :attacker}))
  end

  defp siege_role(_v, wave, id), do: if(id in members(wave), do: :wave, else: :siege_out)

  @doc """
  The view with the team-wide answers worked out once (`View.shared`): every fighter's job at home
  (`home_roles/2`) and who fights whom (`assignments/2`), for this tick's wave. Every unit on a
  node reads its own part instead of each working out the whole team again (`Swarm.Relay`). The
  answers are the same either way; this is only so they are computed once.
  """
  def share(%View{} = v, wave) do
    v = View.share_economy(%{v | shared: nil})
    v = put_shared(v, %{fighters: fighters(v), enemy_fighters: enemy_fighters(v), enemy_towers: enemy_towers(v), our_towers: our_towers(v)})
    v = put_shared(v, %{outposts: outposts(v)})
    v = put_shared(v, %{bases: bases(v)})
    v = put_shared(v, %{raiders: raiders(v), help_wanted: help_wanted(v), finishable_ccs: finishable_ccs(v)})
    v = put_shared(v, %{wave: wave, home_roles: home_roles(v, wave)})
    v = put_shared(v, %{assignments: assignments(v, wave), home_strength: strength(home(v, wave), v.me)})
    # The lists of units and towers only helped work the rest out: the view already carries them,
    # and it is copied to every unit. Each unit lists them again for itself (`localize/1`).
    %{v | shared: Map.drop(v.shared, @local_lists)}
  end


  @doc """
  On a unit, once its tick arrives: the lists `share/2` leaves out (our fighters, theirs, the
  towers both sides) worked out once for this unit's whole decision, without copying them to it.
  """
  def localize(%View{shared: nil} = v), do: v

  def localize(%View{} = v) do
    put_shared(v, %{fighters: fighters(v), enemy_fighters: enemy_fighters(v), enemy_towers: enemy_towers(v), our_towers: our_towers(v)})
  end

  defp put_shared(v, answers), do: %{v | shared: Map.merge(v.shared || %{}, answers)}

  @doc """
  Enemy Command Centers nearly dead: our fighters within `@engage_radius` of one can bring it down
  in `@finish_ticks` ticks (their hits, its armor of 2 taken off, over that many ticks, are at
  least its HP). A player is eliminated with their last one, and everything they had goes with
  it: finishing one comes before anything else, including calling a wave off.
  """
  def finishable_ccs(%View{} = v) do
    View.cached(v, :finishable_ccs, fn ->
      weapons = 2 * Enum.count(v.upgrades, &(&1 in ["Weapons1", "Weapons2"]))

      for b <- v.enemy_buildings,
          b["type"] == "CommandCenter",
          by = Enum.filter(fighters(v), &(View.dist(View.pos(&1), View.pos(b)) <= @engage_radius)),
          by != [],
          per_tick = Enum.sum_by(by, &(max(1, stats(&1).damage + weapons - 2) / stats(&1).cooldown)),
          (b["hp"] || 1500) <= per_tick * @finish_ticks,
          do: b
    end)
  end

  @doc "A nearly dead enemy Command Center (`finishable_ccs/1`) within `@engage_radius` of `unit`, or nil."
  def finish_target(%View{} = v, unit) do
    Enum.find(finishable_ccs(v), &(View.dist(View.pos(&1), View.pos(unit)) <= @engage_radius))
  end

  @doc "Enemy fighters we can see (not workers)."
  def enemy_fighters(%View{} = v), do: View.cached(v, :enemy_fighters, fn -> Enum.reject(v.enemy_units, &(&1["type"] == "Worker")) end)

  @doc "Our finished Guard Towers."
  def our_towers(%View{} = v), do: View.cached(v, :our_towers, fn -> Enum.filter(View.buildings_of(v, "GuardTower"), & &1["completed"]) end)

  @doc "Ids of the guards."
  def guards(%View{} = v, wave) do
    for {id, :guard} <- home_roles(v, wave), into: MapSet.new(), do: id
  end

  @doc "Finished Resource Depots away from the Command Center: each is a base of its own."
  def outposts(%View{cc: nil}), do: []

  def outposts(%View{cc: cc} = v) do
    View.cached(v, :outposts, fn -> outposts(v, cc) end)
  end

  defp outposts(v, cc) do
    for d <- View.buildings_of(v, "ResourceDepot"),
        d["completed"],
        View.dist(View.pos(d), View.pos(cc)) > @outpost_distance,
        do: View.pos(d)
  end

  @doc """
  Our neighbors: the `@neighbors` opponents still in whose starts are nearest our Command Center
  (the map's middle without one), nearest first, as `{start, slot}`. Waves only go after these,
  and scouts watch them most.
  """
  def neighbors(%View{} = v) do
    from = if v.cc, do: View.pos(v.cc), else: {div(v.map_width, 2), div(v.map_height, 2)}

    v.start_owner
    |> Enum.sort_by(fn {start, slot} -> {View.dist(start, from), slot} end)
    |> Enum.take(@neighbors)
  end

  @doc "Every base: the Command Center and the outposts."
  def bases(%View{cc: nil} = v), do: outposts(v)
  def bases(%View{cc: cc} = v), do: View.cached(v, :bases, fn -> [View.pos(cc) | outposts(v)] end)

  defp miners(v, outpost),
    do: Enum.count(View.units_of(v, "Worker"), &(View.dist(View.pos(&1), outpost) <= @base_radius))

  @doc "Where an outpost's escorts stand: two tiles out from it, toward `toward` (the enemy)."
  def escort_post({x, y}, {tx, ty}), do: {x + 2 * sign(tx - x), y + 2 * sign(ty - y)}

  @doc "Our soldiers and archers: everything that fights in the line (not workers, scouts or siege)."
  def fighters(%View{} = v),
    do: View.cached(v, :fighters, fn -> Enum.reject(View.military(v), &(&1["type"] in ["Scout", "Trebuchet"])) end)

  @doc "Fighters that aren't away with the wave."
  def home(%View{} = v, wave), do: Enum.reject(fighters(v), &(&1["id"] in members(wave)))

  @doc """
  How much fight a group has: the one measure every comparison uses (launching, recalling, strikes,
  sorties, the serum, home's defense), so they always agree. A unit is worth its cost in Soldiers
  (a full Soldier is 990), less as it is hurt: an Archer is 1.25 Soldiers, a Trebuchet 3.5.
  A Guard Tower at full HP, less as it is hurt, is worth some Soldiers: in a straight fight it
  takes about three and a half (four kill it and lose one or two; three lose). We count it on the
  safe side both ways: ours (owner `me`) as `@own_tower_worth`, so we never trust home's defense too
  much, and the enemy's as `@enemy_tower_worth`, so we never go at one too light. Whose it is, not
  who asks, decides: a strike's launch and its recall both see an enemy tower and agree.
  Takes units or buildings, ours or theirs; pass `me` (our slot) when ours may be among them.
  """
  def strength(units, me \\ nil), do: Enum.sum_by(units, &strength_of(&1, me))

  defp strength_of(%{"type" => "GuardTower"} = tower, me) do
    worth = if me != nil and tower["owner"] == me, do: @own_tower_worth, else: @enemy_tower_worth
    worth * @soldier * hp(tower) / stats(tower).hp
  end

  # A unit is worth its cost, in Soldiers (a Soldier is `@soldier`), less as it is hurt. Cost is
  # what the game itself prices them at, and it rates a ranged unit far better than HP x damage
  # per tick did: that made an Archer a third of a Soldier, and a pack of them shreds everything.
  defp strength_of(u, _me), do: @soldier * Map.get(@cost, u["type"], 100) / 100 * hp(u) / stats(u).hp

  @doc """
  Enemies near the Command Center: where the closest one is, and how many fighters (not
  workers) are there. Nil if there are none, or no Command Center.
  """
  @spec threat(View.t()) :: threat()
  def threat(%View{cc: nil}), do: nil
  def threat(%View{cc: cc} = v), do: threat_at(v, View.pos(cc))

  @doc "Like `threat/1`, for the outposts: outpost => its threat, only those under attack."
  def outpost_threats(%View{} = v) do
    for o <- outposts(v), t = threat_at(v, o), into: %{}, do: {o, t}
  end

  @doc """
  Enemy fighters near our workers outside every base (inside one, `threat_at/2` covers it):
  where they are. These are attacks on our economy.
  """
  def worker_threats(%View{} = v) do
    bases = bases(v)
    workers = View.units_of(v, "Worker")

    for e <- v.enemy_units,
        e["type"] != "Worker",
        not Enum.any?(bases, &(View.dist(View.pos(e), &1) <= @base_radius)),
        Enum.any?(workers, &(View.dist(View.pos(&1), View.pos(e)) <= @worker_cover)),
        do: View.pos(e)
  end

  @doc "Enemy Trebuchets within range of our buildings: where they are."
  def siege_threats(%View{} = v) do
    for e <- v.enemy_units, siege_on_us?(v, e), do: View.pos(e)
  end

  defp siege_on_us?(v, enemy) do
    enemy["type"] == "Trebuchet" and
      Enum.any?(v.my_buildings, &(View.dist(View.pos(&1), View.pos(enemy)) <= @siege_reach))
  end

  @doc """
  Every place a home attacker should go help: attacked outposts, attacked workers, and
  Trebuchets shelling our buildings.
  """
  def help_wanted(%View{} = v) do
    View.cached(v, :help_wanted, fn ->
      Enum.map(Map.values(outpost_threats(v)), & &1.pos) ++ worker_threats(v) ++ siege_threats(v)
    end)
  end

  @doc "Enemies near the base at `base`, as `threat/1` describes them."
  def threat_at(%View{} = v, base) do
    near = Enum.filter(v.enemy_units, &(View.dist(View.pos(&1), base) <= @base_radius))

    case near do
      [] ->
        nil

      _ ->
        closest = Enum.min_by(near, &{View.dist(View.pos(&1), base), &1["id"]})
        %{pos: View.pos(closest), size: Enum.count(near, &(&1["type"] != "Worker"))}
    end
  end

  @doc """
  Enemy fighters hitting anything of ours: inside a base (the Command Center's or an outpost's),
  by our workers, or Trebuchets shelling our buildings.
  """
  def raiders(%View{} = v), do: View.cached(v, :raiders, fn -> find_raiders(v) end)

  defp find_raiders(v) do
    bases = bases(v)
    workers = View.units_of(v, "Worker")

    for e <- enemy_fighters(v),
        Enum.any?(bases, &(View.dist(View.pos(e), &1) <= @base_radius)) or
          Enum.any?(workers, &(View.dist(View.pos(&1), View.pos(e)) <= @worker_cover)) or
          siege_on_us?(v, e),
        do: e
  end

  @doc "Whether `pos` is somewhere we defend: in a base (the Command Center's or an outpost's), or by our workers."
  def at_home?(%View{} = v, pos) do
    Enum.any?(bases(v), &(View.dist(pos, &1) <= @base_radius)) or
      Enum.any?(View.units_of(v, "Worker"), &(View.dist(View.pos(&1), pos) <= @worker_cover))
  end

  @doc """
  What can meet `raiders` without the wave: our fighters and Trebuchets not in it within
  `@defend_reach` of a raider, and our finished towers that can reach one (by `strength/1`, like
  everything). Defenders elsewhere, at another base, don't count.
  """
  def home_strength(%View{} = v, wave, raiders) do
    near? = fn pos, reach -> Enum.any?(raiders, &(View.dist(View.pos(&1), pos) <= reach)) end
    siege = Enum.reject(View.units_of(v, "Trebuchet"), &(&1["id"] in members(wave)))
    units = Enum.filter(home(v, wave) ++ siege, &near?.(View.pos(&1), @defend_reach))

    towers = Enum.filter(View.buildings_of(v, "GuardTower"), &(&1["completed"] and near?.(View.pos(&1), range(&1) + 1)))
    strength(units ++ towers, v.me)
  end

  @doc """
  Should the wave come home? When what is hitting us, anywhere (the main base, an outpost, our
  workers), is stronger than what is home to meet it. We only attack a neighbor, so home is never
  far. `{raiders' strength, home's strength}` if so, else nil.
  """
  def recall(%View{} = v, wave) when wave != nil do
    case raiders(v) do
      [] ->
        nil

      raiders ->
        {theirs, ours} = {strength(raiders), home_strength(v, wave, raiders)}
        if theirs > ours, do: {theirs, ours}
    end
  end

  def recall(_v, nil), do: nil

  @doc """
  Raiders (`raiders/1`) that none of our finished Guard Towers reaches, Trebuchets aside (a sortie
  goes for those): where defenders fight without the towers' help.
  """
  def exposed_raiders(%View{} = v) do
    Enum.reject(raiders(v), &(&1["type"] == "Trebuchet" or sheltered?(v, View.pos(&1))))
  end

  @doc """
  Should home fall back to the towers? When the raiders out of our towers' reach are stronger than
  everything at home (`all_home_strength/3`). Then fighters at home don't go out to them: they
  go to the towers by the workers and cover them (`shelter/2`), and fight what follows them there.
  """
  def fall_back?(%View{cc: nil}, _wave), do: false

  def fall_back?(%View{} = v, wave) do
    case exposed_raiders(v) do
      [] -> false
      exposed -> strength(exposed) > all_home_strength(v, wave, exposed)
    end
  end

  @doc """
  Like `home_strength/3`, but every fighter and Trebuchet at home counts, wherever it is: all we
  could send at these raiders. For calls about home as a whole (falling back, the serum), so one
  raider out of sight of the rally point doesn't look like a raid nobody can meet.
  """
  def all_home_strength(%View{} = v, wave, raiders) do
    siege = Enum.reject(View.units_of(v, "Trebuchet"), &(&1["id"] in members(wave)))
    near? = fn pos, reach -> Enum.any?(raiders, &(View.dist(View.pos(&1), pos) <= reach)) end
    towers = Enum.filter(View.buildings_of(v, "GuardTower"), &(&1["completed"] and near?.(View.pos(&1), range(&1) + 1)))
    strength(home(v, wave) ++ siege ++ towers, v.me)
  end

  @doc "Whether one of our finished Guard Towers reaches `pos`."
  def sheltered?(%View{} = v, pos) do
    Enum.any?(View.buildings_of(v, "GuardTower"), &(&1["completed"] and View.dist(View.pos(&1), pos) <= range(&1)))
  end

  @doc """
  Where to take cover from `from`: next to our finished Guard Tower closest to it, on the Command
  Center's side of the tower. With `away_from` (an enemy's position), only towers on our side of
  it (closer to `from` than to the enemy), so the way there doesn't go past it. The Command Center
  with no such tower; nil without one.
  """
  def shelter(%View{} = v, from, away_from \\ nil) do
    towers =
      for t <- View.buildings_of(v, "GuardTower"),
          t["completed"],
          pos = View.pos(t),
          away_from == nil or View.dist(pos, from) < View.dist(pos, away_from),
          do: pos

    case {towers, v.cc} do
      {[_ | _], cc} ->
        {tx, ty} = Enum.min_by(towers, &{View.dist(&1, from), &1})
        {cx, cy} = if cc, do: View.pos(cc), else: {tx, ty}
        {tx + sign(cx - tx), ty + sign(cy - ty)}

      {[], nil} ->
        nil

      {[], cc} ->
        View.pos(cc)
    end
  end

  @doc """
  Whether the enemy fighters within `radius` of `pos` are stronger than our fighters there and
  our towers that reach it.
  """
  def losing_at?(%View{} = v, pos, radius) do
    near? = &(View.dist(View.pos(&1), pos) <= radius)
    theirs = Enum.filter(enemy_fighters(v), near?)
    towers = Enum.filter(our_towers(v), &(View.dist(View.pos(&1), pos) <= range(&1)))
    theirs != [] and strength(theirs) > strength(Enum.filter(fighters(v), near?) ++ towers, v.me)
  end

  @doc "The average position of the wave's living members, or nil."
  def wave_center(%View{} = v, wave) do
    case Enum.filter(v.my_units, &(&1["id"] in members(wave))) do
      [] ->
        nil

      alive ->
        n = length(alive)
        {div(Enum.sum_by(alive, & &1["x"]), n), div(Enum.sum_by(alive, & &1["y"]), n)}
    end
  end

  @doc """
  What `unit` should attack, or nil.

  Enemy fighters come first, shared out so none is overkilled: those where the enemy can already
  hit us before anything else, then Trebuchets (expensive, and helpless up close), then a pair
  keeps going if our unit is already on that enemy, then the closest. An enemy takes attackers until their damage covers its current HP,
  and at most `@melee_slots` melee ones. A fighter left without one hits a tower shooting at it (it
  shoots back), then construction sites (worth their full cost to us at a tenth of the HP and no
  armor), then workers and other buildings (half of us, by id, workers first, the other half
  buildings first, so building and producing both stop), and Command Centers last: a player is eliminated
  with their last one, and everything they had left goes with no score for anyone.

  Fighters at home only go after enemies inside one of our bases or by our workers, so they
  can't be lured away, and fight back against any enemy fighter that can hit them. They never
  stay to hit a building outside: a recalled wave walks home. Wave members fight anything.
  """
  def target(%View{} = v, wave, unit), do: fighter_target(v, wave, unit) || leftover_target(v, wave, unit)

  @doc "The enemy fighter `unit` goes after (`assignments/2`), or nil."
  def fighter_target(%View{} = v, wave, unit) do
    case Map.get(assignments(v, wave), unit["id"]) do
      nil -> nil
      id -> Enum.find(v.enemy_units, &(&1["id"] == id))
    end
  end

  @doc """
  Finished enemy Guard Towers we know of: those in sight, and those the server remembers for us
  (`rememberedBuildings`: seen before, hidden by fog now, where we last saw them).
  """
  def enemy_towers(%View{} = v), do: View.cached(v, :enemy_towers, fn -> known_towers(v) end)

  defp known_towers(v) do
    tower? = &(&1["type"] == "GuardTower" and &1["completed"] != false)
    seen = Enum.filter(v.enemy_buildings, tower?)
    ids = MapSet.new(seen, & &1["id"])
    seen ++ Enum.filter(v.remembered, &(tower?.(&1) and not MapSet.member?(ids, &1["id"])))
  end

  @doc """
  For a unit in the wave: the known enemy tower (`enemy_towers/1`) shooting at it, the closest if
  more than one has it in reach, or nil. A tower fires at whatever enemy is in its reach, so being
  in it is being shot. Only the unit being shot goes after it (once it has no enemy fighter to
  fight); the rest of the wave carries on. At home, nil: the leash and strikes deal with towers.
  """
  def tower_hitting(%View{} = v, wave, unit) do
    here = View.pos(unit)

    if unit["id"] in members(wave) do
      v
      |> enemy_towers()
      |> Enum.filter(&(View.dist(View.pos(&1), here) <= range(&1)))
      |> Enum.min_by(&{View.dist(View.pos(&1), here), &1["id"]}, fn -> nil end)
    end
  end

  @doc """
  Our fighter id => the enemy fighter id it goes after. Falling back (`fall_back?/2`), home
  fighters don't go after raiders out of our towers' reach: only fight back.
  """
  def assignments(%View{shared: %{wave: wave, assignments: assigned}}, wave), do: assigned

  def assignments(%View{} = v, wave) do
    held_back = if fall_back?(v, wave), do: MapSet.new(exposed_raiders(v), & &1["id"]), else: MapSet.new()
    enemies = Enum.reject(v.enemy_units, &(&1["type"] == "Worker"))
    # Where we may go after an enemy: where our side (with the one going) is at least as strong as
    # theirs (`safe_at?/2`).
    odds = Map.new(enemies, &{&1["id"], {support_at(v, View.pos(&1)), danger_at(v, View.pos(&1))}})
    # The group around each of ours: they go in together, so they count, not only those already by
    # the enemy (counting only those, a group standing a few tiles back never went in at all).
    groups = Map.new(fighters(v), &{&1["id"], group_strength(v, &1)})

    safe? = fn o, e ->
      {ours, theirs} = odds[e["id"]]
      going = if View.dist(View.pos(o), View.pos(e)) > @engage_radius, do: strength([o], v.me), else: 0
      max(ours + going, groups[o["id"]]) >= theirs
    end
    extra_armor = if enemy_tech_lab?(v), do: 1, else: 0
    weapons = 2 * Enum.count(v.upgrades, &(&1 in ["Weapons1", "Weapons2"]))

    pairs =
      for o <- fighters(v),
          e <- enemies,
          d = View.dist(View.pos(o), View.pos(e)),
          d <= if(e["type"] == "Trebuchet", do: @siege_engage_radius, else: @engage_radius),
          hits_now?(e, o) or
            (safe?.(o, e) and
               ((may_chase?(v, wave, o, e) and (o["id"] in members(wave) or not MapSet.member?(held_back, e["id"]))) or
                  fight_back?(e, o))) do
        can_hit_us = if d in Map.get(stats(e), :min_range, 0)..stats(e).range//1, do: 0, else: 1
        siege = if e["type"] == "Trebuchet", do: 0, else: 1
        already_on_it = if o["targetId"] == e["id"], do: 0, else: 1
        {{can_hit_us, siege, already_on_it, d, o["id"], e["id"]}, o, e}
      end

    {assigned, _load} =
      pairs
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce({%{}, %{}}, fn {_key, o, e}, {assigned, load} ->
        {damage, melee} = Map.get(load, e["id"], {0, 0})
        melee? = stats(o).range == 1

        if Map.has_key?(assigned, o["id"]) or damage >= hp(e) or (melee? and melee >= @melee_slots) do
          {assigned, load}
        else
          hit = max(1, stats(o).damage + weapons - (stats(e).armor + extra_armor))
          load = Map.put(load, e["id"], {damage + hit, melee + if(melee?, do: 1, else: 0)})
          {Map.put(assigned, o["id"], e["id"]), load}
        end
      end)

    assigned
  end

  @doc """
  Nothing to fight among the enemy fighters: the tower shooting at this unit, then sites, then
  workers and buildings, Command Centers last. Stay on what we are already hitting. A tower that
  isn't shooting at it is a building like the rest: we don't all go for every tower we see.
  """
  def leftover_target(v, wave, unit) do
    here = View.pos(unit)

    (Enum.filter(v.enemy_units, &(&1["type"] == "Worker")) ++ v.enemy_buildings)
    |> Enum.filter(fn t ->
      d = View.dist(View.pos(t), here)
      d <= @engage_radius and may_chase?(v, wave, unit, t) and (d <= stats(unit).range or safe_for?(v, unit, View.pos(t)))
    end)
    |> Enum.min_by(
      fn t ->
        # After towers and sites, half of us (by id) take workers first and half buildings first:
        # the builders stop building and the buildings stop making things, at the same time.
        workers_first? = rem(unit["id"], 2) == 0

        kind =
          cond do
            t["type"] == "Worker" -> if workers_first?, do: 2, else: 3
            t["completed"] == false -> 1
            t["type"] == "GuardTower" and View.dist(View.pos(t), here) <= range(t) -> 0
            t["type"] == "CommandCenter" -> 4
            true -> if workers_first?, do: 3, else: 2
          end

        {kind, if(unit["targetId"] == t["id"], do: 0, else: 1), View.dist(View.pos(t), here), t["id"]}
      end,
      fn -> nil end
    )
  end

  # The leash: away from our bases and our workers only the wave chases, except after a
  # Trebuchet shelling our buildings. (Fighting back is separate: see `fight_back?/2`.)
  defp may_chase?(%View{cc: nil}, _wave, _ours, _enemy), do: true

  defp may_chase?(%View{} = v, wave, ours, enemy) do
    in_wave? = ours["id"] in members(wave)

    # Not into an enemy tower's reach, one by one: only the wave goes there (a strike at that
    # tower is a wave). Fighting back is still allowed (`fight_back?/2`).
    # Buildings only by the main base: by an outpost, a building is the enemy's own base next door,
    # and chasing into it drags home after it. Enemy units by an outpost or our workers are fair game.
    building? = Map.has_key?(enemy, "completed")
    places = if building?, do: [View.pos(v.cc)], else: bases(v)

    (in_wave? or not covered?(v, View.pos(enemy))) and
      (in_wave? or
         Enum.any?(places, &(View.dist(View.pos(enemy), &1) <= @base_radius)) or
         (not building? and Enum.any?(View.units_of(v, "Worker"), &(View.dist(View.pos(&1), View.pos(enemy)) <= @worker_cover))) or
         siege_on_us?(v, enemy))
  end

  @doc """
  Whether `pos` is within reach of a finished enemy Guard Tower (its range plus one: a unit
  stepping up to hit something there is shot). Home units don't go there on their own.
  """
  def covered?(%View{} = v, pos) do
    Enum.any?(v.enemy_buildings, fn b ->
      b["type"] == "GuardTower" and b["completed"] != false and View.dist(View.pos(b), pos) <= range(b) + 1
    end)
  end

  @doc """
  Finished enemy Guard Towers within `@home_reach` of our Command Center (not of an outpost: one
  by an outpost is usually the enemy's own base next door, and a strike there drags the army out):
  the closest first.
  """
  def towers_near_home(%View{cc: nil}), do: []

  def towers_near_home(%View{cc: cc} = v) do
    home = View.pos(cc)

    v.enemy_buildings
    |> Enum.filter(&(&1["type"] == "GuardTower" and &1["completed"] != false and View.dist(View.pos(&1), home) <= @home_reach))
    |> Enum.sort_by(&{View.dist(View.pos(&1), home), &1["id"]})
  end

  @doc """
  Enemy buildings going up within `@home_reach` of one of our bases, the closest first: a tower
  or anything else built at our door. Killed while they are sites: a tenth of the HP, no armor,
  and worth their full cost to us.
  """
  def sites_near_home(%View{} = v, reach \\ @home_reach), do: near_home(v, &(&1["completed"] == false), reach)

  @doc """
  Finished enemy buildings within `@home_reach` of one of our bases other than towers (a strike
  deals with those): a Barracks or a Command Center built at our door. The closest first.
  """
  def buildings_near_home(%View{} = v),
    do: near_home(v, &(&1["completed"] != false and &1["type"] != "GuardTower"), @home_reach)

  defp near_home(v, pick?, reach) do
    bases = bases(v)
    from_home = fn b -> bases |> Enum.map(&View.dist(&1, View.pos(b))) |> Enum.min(fn -> 99 end) end

    v.enemy_buildings
    |> Enum.filter(&(pick?.(&1) and from_home.(&1) <= reach))
    |> Enum.sort_by(&{from_home.(&1), &1["id"]})
  end

  # An enemy fighter in range either way (it can hit us, or we can hit it where we stand): anyone
  # may fight it, leash or not. Only fighters: a building next to a unit walking home is no
  # reason to stay.
  # We can hit it from where we stand: no chasing, so always allowed.
  defp hits_now?(enemy, ours), do: View.dist(View.pos(enemy), View.pos(ours)) <= stats(ours).range

  @doc """
  What the enemy has at `pos`: its fighters within `@engage_radius`, and its towers we know of
  (`enemy_towers/1`) that reach it (range plus one). A Trebuchet counts as one Soldier here.
  """
  def danger_at(%View{} = v, pos) do
    fighters = Enum.filter(enemy_fighters(v), &(View.dist(View.pos(&1), pos) <= @engage_radius))
    towers = Enum.filter(enemy_towers(v), &(View.dist(View.pos(&1), pos) <= range(&1) + 1))
    # A Trebuchet can't hit anything close: walking up to one is a Soldier's worth of danger, not
    # its cost.
    {siege, rest} = Enum.split_with(fighters, &(&1["type"] == "Trebuchet"))
    strength(rest ++ towers) + length(siege) * @soldier
  end

  @doc "What we have at `pos`: our fighters within `@engage_radius`, and our finished towers that reach it."
  def support_at(%View{} = v, pos) do
    ours = Enum.filter(fighters(v), &(View.dist(View.pos(&1), pos) <= @engage_radius))
    towers = Enum.filter(our_towers(v), &(View.dist(View.pos(&1), pos) <= range(&1)))
    strength(ours ++ towers, v.me)
  end

  @doc """
  Whether we may go fight at `pos`: what we have there is at least what they have (`support_at/2`
  against `danger_at/2`). Nobody chases an enemy into more danger: an archer backing off under
  its towers, or into its friends, is left alone until we are there in strength.
  """
  def safe_at?(%View{} = v, pos), do: support_at(v, pos) >= danger_at(v, pos)

  @doc """
  Our fighters within `@engage_radius` of `unit`, itself included: the group that goes in with it.
  """
  def group_strength(%View{} = v, unit) do
    here = View.pos(unit)
    strength(Enum.filter(fighters(v), &(View.dist(View.pos(&1), here) <= @engage_radius)), v.me)
  end

  @doc """
  Whether `unit` may go fight at `pos`: what we have there (`support_at/2`), or the group around
  it that goes in with it (`group_strength/2`), whichever is more, is at least what they have
  (`danger_at/2`). A lone fighter still holds back from a pack; a group goes in together.
  """
  def safe_for?(%View{} = v, unit, pos), do: max(support_at(v, pos), group_strength(v, unit)) >= danger_at(v, pos)

  @doc """
  Whether home can take on what is at `pos`: everything at home (not in `wave`), and our towers
  that reach it, against `danger_at/2`. Attackers only go to help once that holds, and go together.
  """
  def can_take?(%View{} = v, wave, pos) do
    {ours, theirs} = help_odds(v, wave, pos)
    ours >= theirs
  end

  @doc """
  The one measure for helping at `pos`, `{ours, theirs}`: everything at home (not in `wave`) and
  our towers that reach it, against what the enemy has there (`danger_at/2`). Committing to help
  (`can_take?/3`) and calling it off both use it, so they never disagree about what counts.
  """
  def help_odds(%View{} = v, wave, pos) do
    towers = Enum.filter(our_towers(v), &(View.dist(View.pos(&1), pos) <= range(&1)))
    {home_strength(v, wave) + strength(towers, v.me), danger_at(v, pos)}
  end

  # Everything at home, not in `wave` (worked out once with the rest of `share/2`).
  defp home_strength(%View{shared: %{wave: wave, home_strength: hs}}, wave), do: hs
  defp home_strength(v, wave), do: strength(home(v, wave), v.me)

  @doc """
  Whether an outpost's escorts (all of them, wherever they stand), with our fighters and towers at
  `pos`, are at least as strong as what the enemy has there (`danger_at/2`).
  """
  def escorts_hold?(%View{} = v, wave, outpost, pos) do
    roles = home_roles(v, wave)
    escorts = Enum.filter(fighters(v), &(roles[&1["id"]] == {:escort, outpost}))
    near = Enum.filter(fighters(v), &(View.dist(View.pos(&1), pos) <= @engage_radius and &1 not in escorts))
    towers = Enum.filter(our_towers(v), &(View.dist(View.pos(&1), pos) <= range(&1)))
    strength(escorts ++ near ++ towers, v.me) >= danger_at(v, pos)
  end

  defp fight_back?(enemy, ours) do
    d = View.dist(View.pos(enemy), View.pos(ours))
    d in Map.get(stats(enemy), :min_range, 0)..stats(enemy).range//1 or d <= stats(ours).range
  end

  # The enemy's research is hidden, but without a TechLab they can't have Armor upgrades.
  defp enemy_tech_lab?(v), do: Enum.any?(v.enemy_buildings ++ v.remembered, &(&1["type"] == "TechLab"))

  @doc "How far a unit or tower can hit."
  def range(unit), do: stats(unit).range

  defp stats(unit), do: Map.get(@stats, unit["type"], @stats["Soldier"])
  defp hp(unit), do: unit["hp"] || stats(unit).hp

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  defp members(nil), do: []
  defp members(%{members: members}), do: members
end
