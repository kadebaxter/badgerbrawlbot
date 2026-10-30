defmodule Swarm.Roles do
  @moduledoc """
  Who does what, worked out from the view and the strategy alone. Pure and deterministic, so
  the leader and every unit get the same answer without messaging each other.

  A fighter is one of:

  - `:wave`: it left with the current wave (its id is in `strategy.wave.members`)
  - `:guard`: one of the newest fighters at home; holds the main base. At least `@min_guards`,
    or a quarter of the army.
  - `{:escort, outpost}`: holds an outpost (a Resource Depot more than `@outpost_distance` from
    the Command Center) while workers mine there, as a group of `@escort_group` (at least
    `@min_escort_group`, or none: one fighter alone stops nobody). Fighters already there keep
    the job; a gap goes to the closest free fighter.
  - `:attacker`: everyone else at home; waits at the rally point for the next wave, and goes to
    help wherever a base or our workers are attacked

  Scouts are none of these (`:scout`): they explore and never fight on purpose. Our Trebuchets
  are their own: the `@home_siege` oldest hold the base from the guard post (`:siege`); the rest
  (`:siege_out`) wait at the rally point and go out with a wave (`:wave`).

  It also decides who fights whom (`target/3`), the same way on every node.
  """

  alias Swarm.View

  @min_guards 3
  # Trebuchets that always stay home.
  @home_siege 2
  # Our neighbors: the opponents nearest us, whom we attack and watch most closely.
  @neighbors 2
  # Enemy fighters this close to one of our workers are attacking our economy.
  @worker_cover 5
  @escort_group 5
  @min_escort_group 3
  # A depot farther than this from the Command Center is an outpost.
  @outpost_distance 6
  # The base is everything this close to the Command Center. Fighters at home don't chase
  # enemies out of it.
  @base_radius 10
  # A finished Guard Tower defends about as well as this many fighters.
  @tower_worth 2
  # How far a fighter looks for something to fight; farther for a Trebuchet, which shells us from
  # 7 tiles away.
  @engage_radius 6
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

  @type role :: :wave | :guard | {:escort, View.pos()} | :attacker | :scout | :siege | :siege_out

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
    {guards, pool} = Enum.split(pool, max(@min_guards, div(length(fighters(v)), 4)))

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

  defp siege_role(v, wave, id) do
    cond do
      id in members(wave) -> :wave
      id in home_siege(v) -> :siege
      true -> :siege_out
    end
  end

  @doc "The Trebuchets that stay home: the `@home_siege` oldest (they were there first)."
  def home_siege(%View{} = v) do
    v |> View.units_of("Trebuchet") |> Enum.map(& &1["id"]) |> Enum.sort() |> Enum.take(@home_siege)
  end

  @doc "Ids of the guards."
  def guards(%View{} = v, wave) do
    for {id, :guard} <- home_roles(v, wave), into: MapSet.new(), do: id
  end

  @doc "Finished Resource Depots away from the Command Center: each is a base of its own."
  def outposts(%View{cc: nil}), do: []

  def outposts(%View{cc: cc} = v) do
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
  def bases(%View{cc: cc} = v), do: [View.pos(cc) | outposts(v)]

  defp miners(v, outpost),
    do: Enum.count(View.units_of(v, "Worker"), &(View.dist(View.pos(&1), outpost) <= @base_radius))

  @doc "Where an outpost's escorts stand: two tiles out from it, toward `toward` (the enemy)."
  def escort_post({x, y}, {tx, ty}), do: {x + 2 * sign(tx - x), y + 2 * sign(ty - y)}

  @doc "Our soldiers and archers: everything that fights in the line (not workers, scouts or siege)."
  def fighters(%View{} = v), do: Enum.reject(View.military(v), &(&1["type"] in ["Scout", "Trebuchet"]))

  @doc "Fighters that aren't away with the wave."
  def home(%View{} = v, wave), do: Enum.reject(fighters(v), &(&1["id"] in members(wave)))

  @doc """
  How much fight a group has: the sum of HP × damage per tick. Rough, but it ranks a Soldier,
  an Archer and a Tower sensibly against each other. Takes units or buildings, ours or theirs.
  """
  def strength(units) do
    Enum.sum_by(units, fn u -> hp(u) * stats(u).damage / stats(u).cooldown end)
  end

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
    Enum.map(Map.values(outpost_threats(v)), & &1.pos) ++ worker_threats(v) ++ siege_threats(v)
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

  @doc "What is defending the base without the wave: fighters at home, plus the towers."
  def home_defense(%View{} = v, wave) do
    towers = Enum.count(View.buildings_of(v, "GuardTower"), & &1["completed"])
    length(home(v, wave)) + @tower_worth * towers
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
  Should the wave come home? Whenever home can't hold on its own: we only attack a neighbor, so
  home is never far. Every member gets the same answer.
  """
  def turn_back?(%View{} = v, %{wave: wave, threat: threat, rally: rally})
      when wave != nil and threat != nil and rally != nil do
    threat.size > home_defense(v, wave)
  end

  def turn_back?(_v, _strategy), do: false

  @doc """
  What `unit` should attack, or nil.

  Enemy fighters come first, shared out so none is overkilled: those where the enemy can already
  hit us before anything else, then Trebuchets (expensive, and helpless up close), then a pair
  keeps going if our unit is already on that enemy, then the closest. An enemy takes attackers until their damage covers its current HP,
  and at most `@melee_slots` melee ones. A fighter left without one hits towers, then workers,
  then other buildings.

  Fighters at home only go after enemies inside one of our bases or by our workers, so they
  can't be lured away, and fight back against any enemy fighter that can hit them. They never
  stay to hit a building outside: a recalled wave walks home. Wave members fight anything.
  """
  def target(%View{} = v, wave, unit) do
    case Map.get(assignments(v, wave), unit["id"]) do
      nil -> leftover_target(v, wave, unit)
      id -> Enum.find(v.enemy_units, &(&1["id"] == id))
    end
  end

  @doc "Our fighter id => the enemy fighter id it goes after."
  def assignments(%View{} = v, wave) do
    enemies = Enum.reject(v.enemy_units, &(&1["type"] == "Worker"))
    extra_armor = if enemy_tech_lab?(v), do: 1, else: 0
    weapons = 2 * Enum.count(v.upgrades, &(&1 in ["Weapons1", "Weapons2"]))

    pairs =
      for o <- fighters(v),
          e <- enemies,
          d = View.dist(View.pos(o), View.pos(e)),
          d <= if(e["type"] == "Trebuchet", do: @siege_engage_radius, else: @engage_radius),
          may_chase?(v, wave, o, e) or fight_back?(e, o) do
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

  # Nothing to fight among the enemy fighters: towers (they shoot back), then workers, then
  # the rest. Stay on what we are already hitting.
  defp leftover_target(v, wave, unit) do
    here = View.pos(unit)

    (Enum.filter(v.enemy_units, &(&1["type"] == "Worker")) ++ v.enemy_buildings)
    |> Enum.filter(&(View.dist(View.pos(&1), here) <= @engage_radius and may_chase?(v, wave, unit, &1)))
    |> Enum.min_by(
      fn t ->
        kind =
          case t["type"] do
            "GuardTower" -> 0
            "Worker" -> 1
            _ -> 2
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
    ours["id"] in members(wave) or
      Enum.any?(bases(v), &(View.dist(View.pos(enemy), &1) <= @base_radius)) or
      Enum.any?(View.units_of(v, "Worker"), &(View.dist(View.pos(&1), View.pos(enemy)) <= @worker_cover)) or
      siege_on_us?(v, enemy)
  end

  # An enemy fighter in range either way (it can hit us, or we can hit it where we stand): anyone
  # may fight it, leash or not. Only fighters: a building next to a unit walking home is no
  # reason to stay.
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
