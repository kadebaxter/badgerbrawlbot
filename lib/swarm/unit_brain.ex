defmodule Swarm.UnitBrain do
  @moduledoc """
  One unit's decision. Pure: given the view, the team strategy and this unit's own memory,
  return the command for this unit only (or `:no_change`) and its updated memory.

  Workers mine the closest ore to a drop-off that isn't crowded, never ore far from one, and
  run to the rally point when an enemy is about to hit them. A fighter first works out its role (`Swarm.Roles`), then, in order:

  0. an archer losing the fight around it (the enemy fighters near it are stronger than ours) with
     an enemy soldier or scout about to reach it: step back toward home, then shoot again from
     range (kiting). Winning, it stands and shoots: archers are slower than soldiers, so backing
     off from one they could kill only stops them shooting.
  1. something to fight nearby (`Swarm.Roles.target/3`: enemy fighters first, shared out so
     none is overkilled; fighters at home don't chase out of the base): attack it
  2. in the wave: attack-move to the target, or to the threat if the wave turns back
  3. an escort: fight enemies at its outpost, else stand by it
  4. guards and attackers, with enemies at the main base: attack-move to the threat
  5. an attacker, with an outpost or our workers under attack: go help (the closest)
  6. otherwise go to its spot: guards to the post, attackers to the rally point

  Scouts watch, one per neighbor (the two nearest opponents): each waits halfway between our
  Command Center and its neighbor's start, where an attack from them comes through. When the leader
  wants a look at a target before attacking (`strategy.look`), the scout watching that side goes
  there, then comes back to its post; the other stays. A scout runs toward home once an enemy could reach it or it is taking
  damage, and waits `@scout_rest` ticks before going back. Its memory holds its HP last tick and
  when it last ran.

  Any unit standing on a tile where an enemy shell is about to land steps off it first: a
  Trebuchet's shell hits whatever is on the tile when it lands, and it aims at units standing
  still.

  The memory is the order the unit last gave itself. Orders persist in the game, so a unit that
  is still carrying out the same order sends nothing. Losing the memory (the process restarted)
  only means the order is sent once more.
  """

  alias Swarm.{Roles, View}

  # Archers losing the fight around them step back once an enemy soldier or scout is this close,
  # `@kite_step` tiles at a time. Within `@kite_home` of the rally point they stand and fight:
  # help is there.
  @kite_distance 3
  @kite_step 3
  @kite_home 2
  @melee ["Soldier", "Scout"]
  # A Trebuchet can't hit anything this close: it steps back instead.
  @siege_blind_spot 3

  # Where a unit steps to get off a tile: sideways first, then diagonally.
  @steps [{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1}]

  # Workers on one deposit before the next one over is better.
  @crowd 3
  # Ore with an enemy fighter this close is unsafe to mine.
  @unsafe_ore 5
  # A scout runs from an enemy (or tower) once it is within the enemy's range plus this. The
  # scout is twice as fast as anything else, so that is enough to get away.
  @scout_margin 2
  # How long a scout that ran stays back before returning to its post.
  @scout_rest 15

  def new_memory, do: %{intent: nil}

  @spec decide(integer(), View.t(), Swarm.Brain.strategy(), map()) :: {map() | :no_change, map()}
  def decide(unit_id, %View{} = v, strategy, memory \\ new_memory()) do
    unit = View.my_unit(v, unit_id)
    step = unit && dodge(unit, v)

    cond do
      unit == nil -> {:no_change, memory}
      step -> {command(unit, {:move, step}), %{memory | intent: {:move, step}}}
      true -> act(unit, v, strategy, memory)
    end
  end

  # A shell lands on a tile; a unit already on the move is gone by then.
  defp dodge(%{"activity" => "Moving"}, _v), do: nil

  defp dodge(unit, v) do
    landing = for s <- v.shells, s["owner"] != v.me, s["landsTick"] >= v.tick, into: MapSet.new(), do: {s["x"], s["y"]}
    {x, y} = View.pos(unit)

    if MapSet.member?(landing, {x, y}) do
      Enum.find(for({dx, dy} <- @steps, do: {x + dx, y + dy}), fn {nx, ny} = tile ->
        nx in 0..(v.map_width - 1)//1 and ny in 0..(v.map_height - 1)//1 and not MapSet.member?(landing, tile)
      end)
    end
  end

  defp act(%{"type" => "Worker"} = unit, v, strategy, memory), do: {worker(unit, v, strategy), memory}
  defp act(%{"type" => "Scout"} = unit, v, strategy, memory), do: scout(unit, v, strategy, memory)
  defp act(%{"type" => "Trebuchet"} = unit, v, strategy, memory), do: siege(unit, v, strategy, memory)
  defp act(unit, v, strategy, memory), do: fighter(unit, v, strategy, memory)

  # A miner about to be hit runs toward help. Once it is safe and idle it goes back to mining,
  # but not to ore with enemies by it. Builders keep building.
  defp worker(%{"activity" => activity} = unit, v, %{rally: rally})
       when activity in ["Idle", "Gathering", "Returning"] and rally != nil do
    case danger(unit, v) do
      nil ->
        worker(unit, v)

      enemy ->
        {x, y} = refuge(unit, v, enemy) || rally
        %{"type" => "Move", "unitIds" => [unit["id"]], "x" => x, "y" => y}
    end
  end

  defp worker(unit, v, _strategy), do: worker(unit, v)

  # The closest enemy fighter that is about to reach this worker, or nil.
  defp danger(unit, v) do
    here = View.pos(unit)

    v.enemy_units
    |> Enum.filter(&(&1["type"] != "Worker" and View.dist(View.pos(&1), here) <= Roles.range(&1) + 1))
    |> Enum.min_by(&View.dist(View.pos(&1), here), fn -> nil end)
  end

  # The closest of our fighters or drop-offs that is on our side of the enemy (closer to this
  # worker than to it, so the way there doesn't go past it): help, or at least a place to drop
  # ore. Nil if there is none.
  defp refuge(unit, v, enemy) do
    here = View.pos(unit)
    there = View.pos(enemy)

    (Enum.map(Roles.fighters(v), &View.pos/1) ++ View.drop_offs(v))
    |> Enum.filter(&(View.dist(&1, here) < View.dist(&1, there)))
    |> Enum.min_by(&{View.dist(&1, here), &1}, fn -> nil end)
  end

  # Ore with an enemy fighter this close isn't worth walking into.
  defp unsafe?(deposit, v) do
    Enum.any?(v.enemy_units, &(&1["type"] != "Worker" and View.dist(View.pos(&1), View.pos(deposit)) <= @unsafe_ore))
  end

  # An idle worker picks a deposit. So does one mining a deposit too far from any drop-off (once
  # there is a closer one), or one with enemies by it. With only unsafe ore left, it waits. With
  # no ore by a drop-off, ore by a depot being built comes first: the brain put it by the field
  # it expects miners at, so they don't scatter to another far one.
  defp worker(unit, %View{deposits: [_ | _]} = v) do
    near =
      case View.near_deposits(v) do
        [] -> View.soon_near_deposits(v)
        near -> near
      end

    current = Enum.find(v.deposits, &(&1["id"] == unit["targetId"]))
    mining? = unit["activity"] in ["Gathering", "Returning"] and current != nil

    move? =
      unit["activity"] == "Idle" or
        (mining? and near != [] and current not in near) or
        (mining? and unsafe?(current, v))

    choices = Enum.reject(if(near == [], do: v.deposits, else: near), &unsafe?(&1, v))

    case move? && choices do
      [_ | _] ->
        best = pick_deposit(unit, v, choices)
        if best["id"] == unit["targetId"], do: :no_change, else: %{"type" => "Gather", "unitIds" => [unit["id"]], "targetId" => best["id"]}

      _ ->
        :no_change
    end
  end

  defp worker(_unit, _view), do: :no_change

  # The shortest trip to a drop-off (closest to the worker on a tie) that has room; if every
  # one is crowded, the shortest anyway. Crowding a close field beats walking far.
  defp pick_deposit(unit, v, deposits) do
    here = View.pos(unit)

    load =
      for w <- View.units_of(v, "Worker"), w["id"] != unit["id"], reduce: %{} do
        acc -> Map.update(acc, w["targetId"], 1, &(&1 + 1))
      end

    ranked =
      Enum.sort_by(deposits, fn d ->
        {View.trip(v, d) || View.dist(here, View.pos(d)), View.dist(here, View.pos(d)), d["id"]}
      end)

    Enum.find(ranked, hd(ranked), &(Map.get(load, &1["id"], 0) < @crowd))
  end

  defp fighter(unit, v, strategy, memory) do
    intent = intent(unit, v, strategy)

    if carrying_out?(unit, intent, memory.intent),
      do: {:no_change, memory},
      else: {command(unit, intent), %{memory | intent: intent}}
  end

  defp intent(unit, v, s) do
    role = if s.rally, do: Roles.role(v, s.wave, unit["id"]), else: :wave

    cond do
      back = unit["type"] == "Archer" && outnumbered?(v, View.pos(unit)) && kite(unit, v, s, @melee, @kite_distance) -> {:move, back}
      enemy = Roles.target(v, s.wave, unit) -> {:attack, enemy["id"]}
      role == :wave and holding?(s) -> {:attack_move, s.wave.staging}
      role == :wave -> {:attack_move, s.target}
      match?({:escort, _}, role) -> escort(v, s, elem(role, 1))
      s.threat -> {:attack_move, s.threat.pos}
      help = role == :attacker && closest_help(v, unit) -> {:attack_move, help}
      role == :guard -> {:move, s.post}
      true -> {:move, s.rally}
    end
  end

  # Where an archer steps back to, or nil to stand and shoot. Of the steps that take it farther
  # from the closest enemy soldier or scout, the one closest to the rally point: so it backs off
  # toward home, around an enemy in the way, and never just into a corner.
  # Everything but workers, for a Trebuchet: it can't hit anything inside 3 tiles.
  defp kite(unit, v, s, types, near) do
    here = View.pos(unit)
    melee = Enum.filter(v.enemy_units, &(if types == :fighters, do: &1["type"] != "Worker", else: &1["type"] in types))
    home = s.rally

    with [_ | _] <- melee,
         true <- home != nil and View.dist(here, home) > @kite_home,
         closest = Enum.min_by(melee, &View.dist(View.pos(&1), here)),
         now = View.dist(View.pos(closest), here),
         true <- now <= near do
      {x, y} = here

      for({dx, dy} <- @steps, do: {x + dx * @kite_step, y + dy * @kite_step})
      |> Enum.filter(fn {nx, ny} = spot ->
        nx in 0..(v.map_width - 1)//1 and ny in 0..(v.map_height - 1)//1 and
          View.dist(spot, View.pos(closest)) > now
      end)
      |> Enum.min_by(&{View.dist(&1, home), &1}, fn -> nil end)
    else
      _ -> nil
    end
  end

  # The enemy fighters within 6 tiles are stronger than ours there.
  defp outnumbered?(v, here) do
    near? = &(View.dist(View.pos(&1), here) <= 6)
    theirs = Enum.filter(v.enemy_units, &(&1["type"] != "Worker" and near?.(&1)))
    ours = Enum.filter(Roles.fighters(v), near?)
    Roles.strength(theirs) > Roles.strength(ours)
  end

  defp escort(v, s, outpost) do
    case Roles.threat_at(v, outpost) do
      nil -> {:move, Roles.escort_post(outpost, s.target)}
      threat -> {:attack_move, threat.pos}
    end
  end

  defp closest_help(v, unit) do
    case Roles.help_wanted(v) do
      [] -> nil
      spots -> Enum.min_by(spots, &View.dist(&1, View.pos(unit)))
    end
  end

  # A Trebuchet waits at the rally point for a wave (with no base left it joins the attack);
  # with one, it goes to the wave's staging point, then attack-move to the target (the game fires them at
  # whatever they reach), stepping back from anything inside their blind spot.
  defp siege(unit, v, s, memory) do
    role = if s.rally, do: Roles.role(v, s.wave, unit["id"]), else: :wave

    intent =
      cond do
        s.rally == nil -> {:attack_move, s.target}
        role == :siege_out -> {:move, s.rally}
        back = kite(unit, v, s, :fighters, @siege_blind_spot) -> {:move, back}
        holding?(s) -> {:move, s.wave.staging}
        true -> {:attack_move, s.target}
      end

    if carrying_out?(unit, intent, memory.intent),
      do: {:no_change, memory},
      else: {command(unit, intent), %{memory | intent: intent}}
  end

  # The wave waits at its staging point for its Trebuchets.
  defp holding?(%{wave: %{released: false, staging: {_, _}}}), do: true
  defp holding?(_strategy), do: false

  defp scout(unit, v, s, memory) do
    here = View.pos(unit)
    hurt? = unit["hp"] != nil and unit["hp"] < Map.get(memory, :hp, unit["hp"])
    fled_at = Map.get(memory, :fled_at)

    {intent, fled_at} =
      cond do
        from = danger(v, here, hurt?) -> {{:move, flee(v, here, from)}, v.tick}
        fled_at != nil and v.tick - fled_at < @scout_rest -> {memory.intent || {:move, here}, fled_at}
        true -> {{:move, scout_post(v, s, unit)}, nil}
      end

    memory = Map.merge(memory, %{hp: unit["hp"], fled_at: fled_at})

    if carrying_out?(unit, intent, memory.intent),
      do: {:no_change, memory},
      else: {command(unit, intent), %{memory | intent: intent}}
  end

  # The spot the leader wants looked at, for the scout watching that side; otherwise halfway to
  # our neighbor.
  defp scout_post(v, s, unit) do
    spot = Map.get(s, :look)
    if spot && looker(v, spot) == unit["id"], do: spot, else: watch_post(v, unit)
  end

  # Scouts share the neighbors by id: the first watches the nearest, the next the other one (with
  # one neighbor, both watch it). {scout id, the start it watches} for each.
  defp watched(%View{} = v) do
    scouts = v |> View.units_of("Scout") |> Enum.map(& &1["id"]) |> Enum.sort()

    case Roles.neighbors(v) do
      [] -> Enum.map(scouts, &{&1, nil})
      neighbors -> scouts |> Enum.with_index() |> Enum.map(fn {id, i} -> {id, elem(Enum.at(neighbors, rem(i, length(neighbors))), 0)} end)
    end
  end

  # The scout that goes to look at `spot`: the one watching the start nearest it (the first, on a tie).
  defp looker(v, spot) do
    case watched(v) do
      [] -> nil
      scouts -> scouts |> Enum.min_by(fn {id, start} -> {if(start, do: View.dist(start, spot), else: 0), id} end) |> elem(0)
    end
  end

  defp watch_post(%View{cc: nil} = v, _unit), do: {div(v.map_width, 2), div(v.map_height, 2)}

  defp watch_post(%View{cc: cc} = v, unit) do
    case List.keyfind(watched(v), unit["id"], 0) do
      {_id, {sx, sy}} ->
        {cx, cy} = View.pos(cc)
        {div(sx + cx, 2), div(sy + cy, 2)}

      _ ->
        {div(v.map_width, 2), div(v.map_height, 2)}
    end
  end

  # `n` tiles from `from` toward `to` (or `to` itself, if it is closer).
  defp toward({fx, fy} = from, {tx, ty} = to, n) do
    d = View.dist(from, to)
    if d <= n, do: to, else: {fx + div((tx - fx) * n, d), fy + div((ty - fy) * n, d)}
  end

  # Six tiles toward home, or straight away from the threat when it is closer to home than we are
  # (between us and home), or we have no home left.
  defp flee(%View{cc: nil} = v, here, from), do: away(v, here, from)

  defp flee(%View{cc: cc} = v, here, from) do
    home = View.pos(cc)
    if View.dist(here, home) <= View.dist(from, home), do: toward(here, home, 6), else: away(v, here, from)
  end

  # The closest enemy fighter or tower that could reach us. Taking damage, the closest one we
  # can see at all: something is hitting us.
  defp danger(v, here, hurt?) do
    threats =
      Enum.filter(v.enemy_units, &(&1["type"] != "Worker")) ++
        Enum.filter(v.enemy_buildings, &(&1["type"] == "GuardTower"))

    close =
      Enum.filter(threats, fn t ->
        d = View.dist(View.pos(t), here)
        d <= Roles.range(t) + @scout_margin or (hurt? and d <= 8)
      end)

    case close do
      [] -> nil
      near -> near |> Enum.min_by(&View.dist(View.pos(&1), here)) |> View.pos()
    end
  end

  # Six tiles straight away from `from`, kept on the map. Home if it is right on top of us.
  defp away(v, {x, y} = here, {fx, fy}) do
    case {sign(x - fx), sign(y - fy)} do
      {0, 0} -> if v.cc, do: View.pos(v.cc), else: here
      {dx, dy} -> {clamp(x + 6 * dx, v.map_width), clamp(y + 6 * dy, v.map_height)}
    end
  end

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  defp clamp(n, size), do: n |> max(0) |> min(size - 1)

  # Nothing to send: an idle unit that has arrived, or a busy one still on the same order. A
  # moving target (a threat walking around) counts as the same order until it moves 3 tiles.
  defp carrying_out?(unit, intent, last) do
    if unit["activity"] == "Idle", do: arrived?(unit, intent), else: same?(intent, last)
  end

  defp arrived?(unit, {:move, pos}), do: View.dist(View.pos(unit), pos) <= 2
  defp arrived?(unit, {:attack_move, pos}), do: View.dist(View.pos(unit), pos) <= 1
  defp arrived?(_unit, {:attack, _id}), do: false

  defp same?({kind, a}, {kind, b}) when kind in [:move, :attack_move], do: View.dist(a, b) <= 3
  defp same?(intent, last), do: intent == last

  defp command(unit, {:attack, id}), do: %{"type" => "Attack", "unitIds" => [unit["id"]], "targetId" => id}
  defp command(unit, {:attack_move, {x, y}}), do: %{"type" => "Attack", "unitIds" => [unit["id"]], "x" => x, "y" => y}
  defp command(unit, {:move, {x, y}}), do: %{"type" => "Move", "unitIds" => [unit["id"]], "x" => x, "y" => y}
end
