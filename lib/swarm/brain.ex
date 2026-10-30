defmodule Swarm.Brain do
  @moduledoc """
  The leader's team-level decisions. Pure: view + memory in, strategy + commands + memory out.

  - The **strategy** is broadcast to every unit, and each unit interprets it for itself
    (`Swarm.UnitBrain`).
  - The **commands** are the ones no single unit owns: buildings, training and research.
  - The **memory** is the little the leader remembers between ticks. It is replicated through
    `ra`, so a new leader picks up where the old one stopped.

  Economy: grow to ~20 workers while following `@build_order` (Barracks, a Resource Depot by the
  ore, Guard Towers toward the enemy, a TechLab, ...), research upgrades, and train soldiers and
  archers with what is left. Ore for the next building is set aside first, so the rest of the
  spending never makes it late.

  Army: fighters work out their own roles (`Swarm.Roles`). A Scout per opponent explores. The leader
  remembers every enemy fighter it has seen, and launches a wave once the attackers waiting at
  the rally point are `@margin` times as strong as the enemy army and towers we know of (at
  least `@min_wave` of them; `@first_wave` while we know nothing). Only those go; later ones
  wait for the next wave. The wave is recalled when it meets a stronger force or fewer than
  `@recall_below` are left. In the last `@all_in_ticks` ticks, if we are behind on score,
  every fighter attacks: sitting still would lose on time anyway.
  """

  alias Swarm.{Roles, View}

  @target_workers 20
  # One scout per opponent still in, up to this many.
  # One scout per neighbor, plus one for everyone else.
  @max_scouts 3
  @first_wave 15
  @min_wave 8
  @margin 1.5
  @recall_below 5
  @all_in_ticks 300
  # An enemy fighter not seen for this long is forgotten: we can't trust where it was.
  @forget_after 300
  # How far from the wave's center enemies count when deciding to pull back.
  @wave_sight 8
  # How close to the rally point an attacker must be to leave with a wave.
  @staged_radius 3
  # An ordered building that hasn't appeared by then is ordered again.
  @build_timeout_ticks 60
  # A worker sent to finish an abandoned site gets this long to show up before we send another.
  @help_wait_ticks 10

  @costs %{
    "Worker" => 50,
    "Soldier" => 100,
    "Archer" => 125,
    "Scout" => 75,
    "Barracks" => 150,
    "ResourceDepot" => 100,
    "GuardTower" => 125,
    "TechLab" => 150,
    "Harvesting1" => 100,
    "Weapons1" => 150,
    "Armor1" => 150,
    "Harvesting2" => 200,
    "Weapons2" => 250,
    "Armor2" => 250,
    "SiegeEngineering" => 200,
    "SiegeWorkshop" => 250,
    "Trebuchet" => 350
  }

  # Ore on hand that counts as rich, once the first Barracks is up (the 500 we start with doesn't
  # count): then the build order stops waiting for workers (except for depots), more gets built
  # (`@extras`), each building gets two builders, and Barracks queue up to five.
  @rich 500

  # The fewest fighters to have before ore goes to anything else: this many, plus one per
  # `@army_floor_ticks` ticks. Below it, the Barracks train first.
  @army_floor 6
  @army_floor_ticks 100

  # Built once the build order is done and only while rich, one at a time, in this order.
  @extras [
    {"Barracks", 3, :base},
    {"GuardTower", 3, :front},
    {"Barracks", 4, :base},
    {"GuardTower", 4, :front},
    {"GuardTower", 5, :front}
  ]

  # Defensive Trebuchets kept at home (see `Swarm.UnitBrain`). Siege only once the army can
  # hold the base without it: SiegeEngineering, the SiegeWorkshop and so the Trebuchets wait for
  # this many fighters (and the build order to be done).
  @trebuchets 2
  @siege_after_fighters 15

  # {building, how many we want, workers we need first, where it goes}, built one at a time.
  @build_order [
    {"Barracks", 1, 7, :base},
    {"ResourceDepot", 1, 9, :ore},
    {"GuardTower", 1, 11, :front},
    {"TechLab", 1, 13, :base},
    {"Barracks", 2, 15, :base},
    {"GuardTower", 2, 17, :front}
  ]

  @needs_barracks ["GuardTower", "TechLab"]

  # Home is short of ore when the ore left near our drop-offs is under `@low_home_ore`, or there are
  # more workers than `@workers_per_deposit` per nearby deposit. Short for `@short_for_ticks` in a
  # row, a Resource Depot goes by the closest other ore, ahead of the build order.
  @low_home_ore 1500
  # A Guard Tower this close to an outpost counts as its tower.
  @outpost_tower_reach 6
  # Where we lost a building, no new depot for this long: it was a contested spot.
  @avoid_lost_ticks 300
  @workers_per_deposit 3
  @short_for_ticks 30

  # Each tier 2 comes after its tier 1, and a TechLab researches one at a time.
  @research ["Harvesting1", "Weapons1", "Armor1", "SiegeEngineering", "Harvesting2", "Weapons2", "Armor2"]

  @type pos :: {integer, integer}

  # `mode` is only a summary for the logs; units go by the rest. `why` explains this tick's army
  # decisions, [{kind, text}], for the decision log (`Swarm.Decisions`); units ignore it.
  @type strategy :: %{
          mode: :gather | :attack | :defend,
          target: pos() | nil,
          rally: pos() | nil,
          post: pos() | nil,
          threat: Roles.threat(),
          wave: Roles.wave(),
          why: [{atom(), String.t()}]
        }

  # `wave` is the wave that is out: %{id, members}. `next_wave` is the next one's id.
  # `enemies` is enemy fighter id => how it looked when last seen (with "seen", the tick).
  # `pending` is the building we ordered and are waiting to see: %{type, builder, at, had}.
  # `helpers` is building id => {worker id, tick} for workers sent to finish abandoned sites.
  # `ore_short_since` is the tick home has been short of ore since, or nil.
  # `buildings` is our building id => where it stands; `lost` is spot => tick, for buildings that
  # went missing (destroyed) in the last `@avoid_lost_ticks`.
  def new_memory do
    %{
      wave: nil,
      next_wave: 1,
      enemies: %{},
      pending: nil,
      helpers: %{},
      ore_short_since: nil,
      buildings: %{},
      lost: %{}
    }
  end

  @spec plan(View.t(), map(), [String.t()]) :: {strategy(), [map()], map()}
  def plan(%View{} = v, memory, terrain) do
    # Memory from an older version may have other keys: keep only the ones we know.
    memory = new_memory() |> Map.merge(memory || %{}) |> Map.take(Map.keys(new_memory()))
    memory = %{memory | enemies: remember_enemies(memory.enemies, v)}
    {strategy, memory} = strategy(v, memory)
    memory = %{memory | pending: still_pending(memory.pending, v), ore_short_since: short_since(memory, v)}
    memory = remember_losses(memory, v)

    {commands, memory, _ore} =
      {[], memory, v.ore}
      |> finish_sites(v)
      |> army_floor(v)
      |> build(v, terrain)
      |> train_workers(v)
      |> research(v)
      |> train_scout(v)
      |> train_siege(v)
      |> train_army(v)

    {strategy, Enum.reverse(commands), memory}
  end

  # No base left: everyone attacks.
  defp strategy(%View{cc: nil} = v, memory) do
    target = target_of(v, opponent(v, memory))
    {%{mode: :attack, target: target, rally: nil, post: nil, threat: nil, wave: nil, why: []}, memory}
  end

  defp strategy(%View{} = v, memory) do
    rally = rally(v)
    threat = Roles.threat(v)
    # Any base under attack, outposts included, or our workers out in the field.
    attacked? = threat != nil or Roles.help_wanted(v) != []
    owner = opponent(v, memory)
    target = target_of(v, owner)
    {wave, next_wave, why} = wave(v, memory, rally, attacked?, owner)

    mode =
      cond do
        attacked? -> :defend
        wave -> :attack
        true -> :gather
      end

    strategy = %{
      mode: mode,
      target: target,
      rally: rally,
      post: post(v, rally, target),
      threat: threat,
      wave: wave,
      why: why
    }

    {strategy, %{memory | wave: wave, next_wave: next_wave}}
  end

  # Enemy fighters as last seen. Ones we killed or haven't seen in a while are dropped.
  defp remember_enemies(enemies, %View{} = v) do
    killed = for e <- v.events, e["kind"] == "UnitKilled", do: e["entityId"]

    seen =
      for u <- v.enemy_units, u["type"] != "Worker", into: %{} do
        {u["id"], u |> Map.take(["id", "owner", "type", "hp", "x", "y"]) |> Map.put("seen", v.tick)}
      end

    enemies
    |> Map.merge(seen)
    |> Map.drop(killed)
    |> Map.reject(fn {_id, e} -> v.tick - e["seen"] > @forget_after end)
  end

  defp wave(v, memory, rally, attacked?, owner) do
    cond do
      all_in?(v) -> all_in(v, memory, owner)
      memory.wave -> keep_wave(v, memory)
      true -> launch(v, memory, rally, attacked?, owner)
    end
  end

  # Near the end and behind on score: every fighter goes, including new ones.
  defp all_in?(v), do: v.tick >= v.max_ticks - @all_in_ticks and v.my_score < v.enemy_score

  # Each returns {wave, next wave id, why}.
  defp all_in(v, memory, owner) do
    members = v |> Roles.fighters() |> Enum.map(& &1["id"]) |> Enum.sort()

    case memory.wave do
      %{all_in: true} = wave ->
        {%{wave | members: members}, memory.next_wave, []}

      _ ->
        why =
          "behind on score (#{v.my_score} vs #{v.enemy_score}) with #{v.max_ticks - v.tick} ticks left: " <>
            "all #{length(members)} fighters attack"

        {%{id: memory.next_wave, members: members, all_in: true, owner: owner}, memory.next_wave + 1, [{:all_in, why}]}
    end
  end

  # Keep the wave that is out (minus its dead), unless too few are left or what it is facing
  # is stronger than it is.
  defp keep_wave(v, %{wave: wave} = memory) do
    alive = Enum.filter(v.my_units, &(&1["id"] in wave.members))

    cond do
      length(alive) < @recall_below ->
        {nil, memory.next_wave, [{:wave_recalled, "wave #{wave.id}: only #{length(alive)} left"}]}

      facing = outmatched(v, alive) ->
        why = "wave #{wave.id}: outmatched, strength #{round(Roles.strength(alive))} vs #{round(facing)} nearby"
        {nil, memory.next_wave, [{:wave_recalled, why}]}

      true ->
        {%{wave | members: Enum.map(alive, & &1["id"])}, memory.next_wave, []}
    end
  end

  # The strength of what the wave is facing if it is more than the wave's own, else nil.
  defp outmatched(v, alive) do
    n = length(alive)
    center = {div(Enum.sum_by(alive, & &1["x"]), n), div(Enum.sum_by(alive, & &1["y"]), n)}
    near? = &(View.dist(View.pos(&1), center) <= @wave_sight)

    facing =
      Enum.filter(v.enemy_units, &(&1["type"] != "Worker" and near?.(&1))) ++
        Enum.filter(v.enemy_buildings, &(&1["type"] == "GuardTower" and &1["completed"] and near?.(&1)))

    if Roles.strength(alive) < Roles.strength(facing), do: Roles.strength(facing)
  end

  # With no base under attack, send the attackers waiting at the rally point once they are
  # strong enough. Knowing nothing about the enemy yet, wait for `@first_wave` of them.
  defp launch(v, memory, rally, attacked?, owner) do
    roles = Roles.home_roles(v, nil)

    staged =
      for u <- Roles.home(v, nil),
          roles[u["id"]] == :attacker,
          View.dist(View.pos(u), rally) <= @staged_radius,
          do: u

    scouted? = memory.enemies != %{} or v.enemy_buildings != [] or v.remembered != []

    ours = Roles.strength(staged)
    theirs = enemy_strength(v, memory, owner)

    ready? =
      if scouted?,
        do: length(staged) >= @min_wave and ours >= @margin * theirs,
        else: length(staged) >= @first_wave

    if not attacked? and ready? do
      why =
        if scouted?,
          do: "wave #{memory.next_wave} at player #{owner}: #{length(staged)} attackers, strength #{round(ours)} vs #{round(theirs)} known",
          else: "wave #{memory.next_wave} at player #{owner}: #{length(staged)} attackers, nothing scouted yet"

      wave = %{id: memory.next_wave, members: staged |> Enum.map(& &1["id"]) |> Enum.sort(), owner: owner}
      {wave, memory.next_wave + 1, [{:wave_launched, why}]}
    else
      {nil, memory.next_wave, []}
    end
  end

  @doc """
  The army we remember of player `owner` (all opponents if nil), plus their finished towers we
  know of. An enemy remembered without an owner counts against everyone.
  """
  def enemy_strength(%View{} = v, memory, owner \\ nil) do
    theirs? = &(owner == nil or &1["owner"] in [owner, nil])

    towers =
      (v.enemy_buildings ++ v.remembered)
      |> Enum.filter(&(&1["type"] == "GuardTower" and &1["completed"] != false and theirs?.(&1)))
      |> Enum.uniq_by(& &1["id"])

    army = memory.enemies |> Map.values() |> Enum.filter(theirs?)
    Roles.strength(army) + Roles.strength(towers)
  end

  # Who we go after: the opponent the wave out is after, while they are still in; otherwise the
  # weaker of our neighbors (`Swarm.Roles.neighbors/1`; never one across the map). Weaker by survival
  # score, the ore value of everything they have alive, which the server reports for everyone.
  defp opponent(v, memory) do
    case memory.wave do
      %{owner: owner} when owner != nil and is_map_key(v.enemy_survival, owner) ->
        owner

      _ ->
        from = if v.cc, do: View.pos(v.cc), else: center(v)

        v
        |> Roles.neighbors()
        |> Enum.min_by(fn {start, slot} -> {Map.get(v.enemy_survival, slot, 0), View.dist(start, from)} end, fn -> nil end)
        |> case do
          {_start, slot} -> slot
          nil -> nil
        end
    end
  end

  # Where to attack `owner`: their building nearest us (seen now, else remembered), else their start.
  defp target_of(v, owner) do
    from = if v.cc, do: View.pos(v.cc), else: center(v)
    theirs = Enum.filter(v.enemy_buildings ++ v.remembered, &(&1["owner"] == owner))
    start = Enum.find_value(v.start_owner, fn {pos, slot} -> if slot == owner, do: pos end)

    case theirs do
      [] -> start || center(v)
      _ -> theirs |> Enum.map(&View.pos/1) |> Enum.min_by(&View.dist(&1, from))
    end
  end

  # Where guards stand: behind the Guard Tower closest to the enemy, else the rally point.
  defp post(v, rally, enemy) do
    case Enum.filter(View.buildings_of(v, "GuardTower"), & &1["completed"]) do
      [] ->
        rally

      towers ->
        {x, y} = towers |> Enum.map(&View.pos/1) |> Enum.min_by(&View.dist(&1, enemy))
        {cx, cy} = View.pos(v.cc)
        {x + sign(cx - x), y + sign(cy - y)}
    end
  end

  # Three tiles from the Command Center toward the middle of the map.
  defp rally(%View{cc: cc} = v) do
    {x, y} = View.pos(cc)
    {cx, cy} = center(v)
    {x + 3 * sign(cx - x), y + 3 * sign(cy - y)}
  end

  defp center(%View{} = v), do: {div(v.map_width, 2), div(v.map_height, 2)}

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  ## Buildings

  # Forget the pending building once it is up, or if it isn't coming: the builder died, its
  # order failed, or it is taking too long.
  defp still_pending(nil, _v), do: nil

  defp still_pending(p, %View{} = v) do
    failed? =
      Enum.any?(v.events, fn e ->
        e["kind"] == "CommandFailed" and e["entityId"] == p.builder and (e["tick"] || 0) >= p.at
      end)

    cond do
      count(v, p.type) > p.had -> nil
      View.my_unit(v, p.builder) == nil -> nil
      failed? -> nil
      v.tick - p.at > @build_timeout_ticks -> nil
      true -> p
    end
  end

  # A site nobody is working on (its builder died or was called away) gets the closest free
  # worker. Its cost was paid when it was started, so this needs no ore.
  defp finish_sites({cmds, mem, ore}, v) do
    unfinished = Enum.reject(v.my_buildings, & &1["completed"])
    worked_on = MapSet.new(View.units_of(v, "Worker"), & &1["targetId"])
    # Forget sites that are finished or gone.
    helpers = Map.take(mem.helpers, Enum.map(unfinished, & &1["id"]))

    {cmds, helpers} =
      Enum.reduce(unfinished, {cmds, helpers}, fn b, {cmds, helpers} ->
        sent_recently? =
          case helpers[b["id"]] do
            {_worker, at} -> v.tick - at <= @help_wait_ticks
            nil -> false
          end

        free = free_workers(v, %{mem | helpers: helpers})

        if MapSet.member?(worked_on, b["id"]) or sent_recently? or free == [] do
          {cmds, helpers}
        else
          worker = closest(free, View.pos(b))
          {[build_cmd([worker], b["type"], View.pos(b)) | cmds], Map.put(helpers, b["id"], {worker["id"], v.tick})}
        end
      end)

    {cmds, %{mem | helpers: helpers}, ore}
  end

  # Waiting on a building: keep its ore aside. Otherwise order the next one in the build order,
  # or start saving for it.
  defp build({cmds, %{pending: %{type: type}} = mem, ore}, _v, _terrain),
    do: {cmds, mem, ore - @costs[type]}

  defp build({cmds, mem, ore} = acc, v, terrain) do
    case next_build(v, terrain, mem) do
      nil -> acc
      {type, site} -> if ore >= @costs[type], do: order(acc, v, type, site), else: {cmds, mem, ore - @costs[type]}
    end
  end

  # The closest free worker goes (the two closest when rich, to build it twice as fast); we
  # remember the first so we can tell if the order fails. With no free worker, keep the ore aside
  # and try again next tick.
  defp order({cmds, mem, ore}, v, type, site) do
    case free_workers(v, mem) do
      [] ->
        {cmds, mem, ore - @costs[type]}

      free ->
        builders = free |> Enum.sort_by(&{View.dist(View.pos(&1), site), &1["id"]}) |> Enum.take(if rich?(v), do: 2, else: 1)
        pending = %{type: type, builder: hd(builders)["id"], at: v.tick, had: count(v, type)}
        {[build_cmd(builders, type, site) | cmds], %{mem | pending: pending}, ore - @costs[type]}
    end
  end

  defp rich?(v), do: v.ore >= @rich and Enum.any?(View.buildings_of(v, "Barracks"), & &1["completed"])

  # Workers we can pull off mining: not building, not on their way to a site, and not already
  # sent somewhere by us. Taking a builder would leave its building unfinished.
  defp free_workers(v, mem) do
    sites = for b <- v.my_buildings, not b["completed"], into: MapSet.new(), do: b["id"]
    sent = for {_site, {worker, _at}} <- mem.helpers, into: MapSet.new(), do: worker
    sent = if mem.pending, do: MapSet.put(sent, mem.pending.builder), else: sent

    Enum.reject(View.units_of(v, "Worker"), fn w ->
      w["activity"] == "Building" or MapSet.member?(sites, w["targetId"]) or MapSet.member?(sent, w["id"])
    end)
  end

  defp closest(units, pos), do: Enum.min_by(units, &{View.dist(View.pos(&1), pos), &1["id"]})

  defp build_cmd(workers, type, {x, y}),
    do: %{"type" => "Build", "unitIds" => Enum.map(workers, & &1["id"]), "buildingType" => type, "x" => x, "y" => y}

  # A new drop-off if our ore is running out, else the first building we are short of, once we
  # have the workers and prerequisites for it. One we can't find room for is skipped so it
  # doesn't hold up the rest.
  defp next_build(%View{cc: nil}, _terrain, _mem), do: nil

  defp next_build(%View{} = v, terrain, mem) do
    case expansion(v, terrain, mem) do
      nil ->
        from_build_order(v, terrain, Map.keys(mem.lost)) || outpost_tower(v, terrain) ||
          siege_workshop(v, terrain) || extra(v, terrain)

      site -> {"ResourceDepot", site}
    end
  end

  # Home has been short of ore for a while: a depot by the closest other ore.
  defp expansion(v, terrain, mem) do
    building_one? = Enum.any?(View.buildings_of(v, "ResourceDepot"), &(not &1["completed"]))
    short_long_enough? = mem.ore_short_since != nil and v.tick - mem.ore_short_since >= @short_for_ticks

    if short_long_enough? and not building_one?, do: site(terrain, v, :expansion, Map.keys(mem.lost))
  end

  # A building of ours that was there last tick and isn't now was destroyed: remember the spot.
  defp remember_losses(memory, v) do
    now = Map.new(v.my_buildings, &{&1["id"], View.pos(&1)})
    gone = memory.buildings |> Map.drop(Map.keys(now)) |> Map.values()

    lost =
      memory.lost
      |> Map.merge(Map.new(gone, &{&1, v.tick}))
      |> Map.reject(fn {_spot, at} -> v.tick - at > @avoid_lost_ticks end)

    %{memory | buildings: now, lost: lost}
  end

  # Since when home has been short of ore (see `@low_home_ore`), or nil if it isn't.
  defp short_since(_memory, %View{cc: nil}), do: nil

  defp short_since(memory, v) do
    near = View.near_deposits(v)
    ore_left = Enum.sum_by(near, &(&1["remaining"] || 0))
    workers = length(View.units_of(v, "Worker"))

    if ore_left < @low_home_ore or workers > @workers_per_deposit * length(near),
      do: memory.ore_short_since || v.tick,
      else: nil
  end

  # Below the floor, the Barracks train before anything is built or researched.
  defp army_floor(acc, v) do
    if length(Roles.fighters(v)) < @army_floor + div(v.tick, @army_floor_ticks),
      do: train_army(acc, v),
      else: acc
  end

  defp from_build_order(v, terrain, avoid) do
    workers = length(View.units_of(v, "Worker"))

    @build_order
    |> Enum.filter(fn {type, wanted, _, _} -> count(v, type) < wanted end)
    |> Enum.reduce_while(nil, fn {type, _wanted, min_workers, where}, nil ->
      gated? = workers < min_workers

      cond do
        not prerequisites?(v, type) -> {:halt, nil}
        gated? and not rich?(v) -> {:halt, nil}
        # Rich, a depot still waits for its workers; the rest of the order goes on.
        gated? and type == "ResourceDepot" -> {:cont, nil}
        site = site(terrain, v, where, avoid) -> {:halt, {type, site}}
        true -> {:cont, nil}
      end
    end)
  end

  # An outpost without a Guard Tower (finished or not) near it gets one. Needs a finished
  # Barracks, like every tower; doesn't need us to be rich.
  defp outpost_tower(v, terrain) do
    towers = Enum.map(View.buildings_of(v, "GuardTower"), &View.pos/1)

    if prerequisites?(v, "GuardTower") do
      Roles.outposts(v)
      |> Enum.reject(fn o -> Enum.any?(towers, &(View.dist(&1, o) <= @outpost_tower_reach)) end)
      |> Enum.find_value(fn o ->
        site = site(terrain, v, {:outpost, o})
        site && {"GuardTower", site}
      end)
    end
  end

  # The army is big enough and SiegeEngineering is done: a SiegeWorkshop, if we have none.
  defp siege_workshop(v, terrain) do
    if count(v, "SiegeWorkshop") == 0 and siege_time?(v) and prerequisites?(v, "SiegeWorkshop") do
      site = site(terrain, v, :base)
      site && {"SiegeWorkshop", site}
    end
  end

  defp siege_time?(v) do
    build_order_done? = Enum.all?(@build_order, fn {type, wanted, _, _} -> count(v, type) >= wanted end)
    build_order_done? and length(Roles.fighters(v)) >= @siege_after_fighters
  end

  # Rich, with the build order done: the first extra we are short of and have room for.
  defp extra(v, terrain) do
    done? = Enum.all?(@build_order, fn {type, wanted, _, _} -> count(v, type) >= wanted end)

    if rich?(v) and done? do
      Enum.find_value(@extras, fn {type, wanted, where} ->
        if count(v, type) < wanted and prerequisites?(v, type) do
          site = site(terrain, v, where)
          site && {type, site}
        end
      end)
    end
  end

  # Finished or not: a site under construction counts.
  defp count(v, type), do: length(View.buildings_of(v, type))

  defp prerequisites?(v, type) when type in @needs_barracks,
    do: Enum.any?(View.buildings_of(v, "Barracks"), & &1["completed"])

  defp prerequisites?(v, "SiegeWorkshop"),
    do: "SiegeEngineering" in v.upgrades and Enum.any?(View.buildings_of(v, "TechLab"), & &1["completed"])

  defp prerequisites?(_v, _type), do: true

  ## Spending what is left

  defp train_workers({cmds, mem, ore} = acc, v) do
    with %{"completed" => true} = cc <- v.cc,
         queued = length(cc["production"]),
         true <- length(View.units_of(v, "Worker")) + queued < @target_workers and queued < 2,
         true <- ore >= @costs["Worker"] do
      cmd = %{"type" => "Produce", "buildingId" => cc["id"], "unitType" => "Worker"}
      {[cmd | cmds], mem, ore - @costs["Worker"]}
    else
      _ -> acc
    end
  end

  defp research({cmds, mem, ore} = acc, v) do
    lab = Enum.find(View.buildings_of(v, "TechLab"), &(&1["completed"] and &1["research"] == nil))
    upgrade =
      Enum.find(@research, fn u ->
        u not in v.upgrades and u not in v.researching and (u != "SiegeEngineering" or siege_time?(v))
      end)

    if lab && upgrade && ore >= @costs[upgrade] do
      cmd = %{"type" => "Research", "buildingId" => lab["id"], "upgrade" => upgrade}
      {[cmd | cmds], mem, ore - @costs[upgrade]}
    else
      acc
    end
  end

  # A scout per neighbor and one more (at most `@max_scouts`), counting ones being trained. From
  # the first free Barracks, one a tick.
  defp train_scout({cmds, mem, ore} = acc, v) do
    barracks = Enum.filter(View.buildings_of(v, "Barracks"), & &1["completed"])
    queued = for b <- barracks, p <- b["production"], p["unitType"] == "Scout", do: p
    free = Enum.find(barracks, &(length(&1["production"]) < 2))

    wanted = min(length(Roles.neighbors(v)) + 1, @max_scouts)

    if length(View.units_of(v, "Scout")) + length(queued) < wanted and free != nil and ore >= @costs["Scout"] do
      cmd = %{"type" => "Produce", "buildingId" => free["id"], "unitType" => "Scout"}
      {[cmd | cmds], mem, ore - @costs["Scout"]}
    else
      acc
    end
  end

  # Keep `@trebuchets` (counting ones being trained) from a finished SiegeWorkshop. Short of
  # the ore, set it aside like a building's, so soldiers don't spend it tick after tick and a
  # Trebuchet never comes. (The army floor trains first, so the base is never left bare for it.)
  defp train_siege({cmds, mem, ore} = acc, v) do
    workshops = Enum.filter(View.buildings_of(v, "SiegeWorkshop"), & &1["completed"])
    queued = for w <- workshops, p <- w["production"], p["unitType"] == "Trebuchet", do: p
    free = Enum.find(workshops, &(length(&1["production"]) < 2))
    cost = @costs["Trebuchet"]

    cond do
      free == nil or length(View.units_of(v, "Trebuchet")) + length(queued) >= @trebuchets ->
        acc

      ore >= cost ->
        cmd = %{"type" => "Produce", "buildingId" => free["id"], "unitType" => "Trebuchet"}
        {[cmd | cmds], mem, ore - cost}

      true ->
        {cmds, mem, ore - cost}
    end
  end

  # Every finished Barracks trains non-stop: two soldiers for each archer.
  defp train_army(acc, v) do
    soldiers = length(View.units_of(v, "Soldier"))
    archers = length(View.units_of(v, "Archer"))
    kind = if archers * 2 < soldiers, do: "Archer", else: "Soldier"

    # Rich: fill the queues (the game takes five) so the ore turns into units, not waste.
    queue = if rich?(v), do: 5, else: 2

    Enum.reduce(View.buildings_of(v, "Barracks"), acc, fn b, {cmds, mem, ore} = acc ->
      if b["completed"] and length(b["production"]) < queue and ore >= @costs[kind] do
        cmd = %{"type" => "Produce", "buildingId" => b["id"], "unitType" => kind}
        {[cmd | cmds], mem, ore - @costs[kind]}
      else
        acc
      end
    end)
  end

  ## Sites

  @doc """
  Where to put a building, or nil if there is no room:

  - `:base`: 3–6 tiles from the Command Center, away from the ore so the miners aren't blocked
  - `{:outpost, pos}`: 2–4 tiles from that outpost, toward the middle of the map
  - `:front`: 4–8 tiles from the Command Center, toward the middle of the map: enemies from
    every side come through there, and with two players the enemy is that way too
  - `:ore`: next to the ore deposit farthest from any drop-off (Command Center or Resource Depot),
    so its miners walk less. Nil if every deposit already has a drop-off close by.
  - `:expansion`: next to the closest ore that is too far from every drop-off to mine. Nil if
    there is none in sight.

  Depots (`:ore`, `:expansion`) only go by ore on our side, closer to our Command Center than to
  any enemy's start, and not within 4 tiles of a spot in `avoid` (where we lost a building).
  """
  def site(terrain, view, where, avoid \\ [])

  def site(terrain, %View{cc: cc} = v, :base, _avoid) do
    {mx, my} = center(v)

    best_site(terrain, v, View.pos(cc), 3..6, fn {x, y} = tile, d ->
      near_ore = v.deposits |> Enum.map(&View.dist(View.pos(&1), tile)) |> Enum.min(fn -> 99 end)
      # On a tie, the side facing the middle rather than whichever tile was scanned first.
      {d - min(near_ore, 4), (x - mx) ** 2 + (y - my) ** 2}
    end)
  end

  # By an outpost, on the side facing the middle of the map, like `:front`.
  def site(terrain, %View{} = v, {:outpost, {ox, oy}}, _avoid) do
    {mx, my} = center(v)
    best_site(terrain, v, {ox, oy}, 2..4, fn {x, y}, _d -> (x - mx) ** 2 + (y - my) ** 2 end)
  end

  def site(terrain, %View{cc: cc} = v, :front, _avoid) do
    {mx, my} = center(v)

    # Straight-line distance: with the game's distance, a whole row of tiles is equally far from
    # a point straight ahead, and the tie went to the map edge.
    best_site(terrain, v, View.pos(cc), 4..8, fn {x, y}, _d -> (x - mx) ** 2 + (y - my) ** 2 end)
  end

  def site(terrain, %View{cc: cc} = v, :ore, avoid) do
    drop_offs = Enum.map([cc | View.buildings_of(v, "ResourceDepot")], &View.pos/1)
    from_drop_off = fn d -> drop_offs |> Enum.map(&View.dist(&1, View.pos(d))) |> Enum.min() end

    target =
      v.deposits
      |> Enum.filter(&(View.dist(View.pos(&1), View.pos(cc)) <= 15 and from_drop_off.(&1) >= 4))
      |> Enum.filter(&safe_ore?(v, &1, avoid))
      |> Enum.max_by(from_drop_off, fn -> nil end)

    if target, do: by_field(terrain, v, target)
  end

  def site(terrain, %View{cc: cc} = v, :expansion, avoid) do
    near = View.near_deposits(v)

    target =
      v.deposits
      |> Enum.reject(&(&1 in near))
      |> Enum.filter(&safe_ore?(v, &1, avoid))
      |> Enum.min_by(&{View.dist(View.pos(&1), View.pos(cc)), &1["id"]}, fn -> nil end)

    if target, do: by_field(terrain, v, target)
  end

  # Ore worth a depot: on our side (closer to our Command Center than to any enemy's start, so
  # never a contested deposit between two players), and not where we just lost a building.
  defp safe_ore?(%View{cc: cc} = v, deposit, avoid) do
    pos = View.pos(deposit)
    ours = View.dist(pos, View.pos(cc))

    Enum.all?(v.enemy_starts, &(ours < View.dist(pos, &1))) and
      not Enum.any?(avoid, &(View.dist(&1, pos) <= 4))
  end

  # Close to the whole field around `target`; on our side of it when that's a tie.
  defp by_field(terrain, %View{cc: cc} = v, target) do
    field = Enum.filter(v.deposits, &(View.dist(View.pos(&1), View.pos(target)) <= 4))

    best_site(terrain, v, View.pos(target), 2..3, fn tile, _d ->
      {Enum.sum_by(field, &View.dist(View.pos(&1), tile)), View.dist(tile, View.pos(cc))}
    end)
  end

  # The open tile `ring` tiles from `{cx, cy}` with the lowest `score.(tile, distance)`: on the map, open ground, not on or
  # next to the ore, and not touching another
  # building (so nothing gets walled in).
  defp best_site(terrain, %View{} = v, {cx, cy}, ring, score) do
    height = length(terrain)
    width = if height > 0, do: String.length(hd(terrain)), else: 0
    buildings = Enum.map(v.my_buildings ++ v.enemy_buildings, &View.pos/1)
    ore = Enum.map(v.deposits, &View.pos/1)

    candidates =
      for y <- (cy - ring.last)..(cy + ring.last),
          x <- (cx - ring.last)..(cx + ring.last),
          d = View.dist({x, y}, {cx, cy}),
          d in ring,
          x in 0..(width - 1)//1 and y in 0..(height - 1)//1,
          String.at(Enum.at(terrain, y), x) == ".",
          not Enum.any?(buildings, &(View.dist(&1, {x, y}) <= 1)),
          not Enum.any?(ore, &(View.dist(&1, {x, y}) <= 1)) do
        {score.({x, y}, d), {x, y}}
      end

    case Enum.min_by(candidates, &elem(&1, 0), fn -> nil end) do
      nil -> nil
      {_score, site} -> site
    end
  end
end
