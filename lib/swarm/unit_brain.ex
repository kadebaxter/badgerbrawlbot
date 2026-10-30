defmodule Swarm.UnitBrain do
  @moduledoc """
  One unit's decision. Pure: given the view, the team strategy and this unit's own memory,
  return the command for this unit only (or `:no_change`) and its updated memory.

  Workers mine the closest ore to a drop-off that isn't crowded, never ore far from one, and
  run to the rally point when an enemy is about to hit them. A fighter first works out its role (`Swarm.Roles`), then, in order:

  1. something to fight nearby (`Swarm.Roles.target/3`: enemy fighters first, shared out so
     none is overkilled; fighters at home don't chase out of the base): attack it
  2. in the wave: attack-move to the target, or to the threat if the wave turns back
  3. an escort: fight enemies at its outpost, else stand by it
  4. guards and attackers, with enemies at the main base: attack-move to the threat
  5. an attacker, with an outpost or our workers under attack: go help (the closest)
  6. otherwise go to its spot: guards to the post, attackers to the rally point

  A scout heads for the spot (of its share of the map) it saw longest ago (the enemy base and their buildings count as
  older, so it keeps checking them). It gets as close as is safe, and runs once an enemy could
  reach it or it is taking damage; then it checks other spots before coming back. Its memory
  holds when it last saw each spot, where it is heading, and its HP last tick.

  Any unit standing on a tile where an enemy shell is about to land steps off it first: a
  Trebuchet's shell hits whatever is on the tile when it lands, and it aims at units standing
  still.

  The memory is the order the unit last gave itself. Orders persist in the game, so a unit that
  is still carrying out the same order sends nothing. Losing the memory (the process restarted)
  only means the order is sent once more.
  """

  alias Swarm.{Roles, View}

  # Where a unit steps to get off a tile: sideways first, then diagonally.
  @steps [{1, 0}, {-1, 0}, {0, 1}, {0, -1}, {1, 1}, {-1, -1}, {1, -1}, {-1, 1}]

  # Workers on one deposit before the next one over is better.
  @crowd 3
  # A scout runs from an enemy (or tower) once it is within the enemy's range plus this. The
  # scout is twice as fast as anything else, so that is enough to get away.
  @scout_margin 2
  # A scout counts a spot as seen this close (its vision is 8).
  @scout_sight 6
  # Spots near the enemy's buildings count as this many ticks older: check them more often.
  @enemy_base_bonus 200

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
  defp act(%{"type" => "Scout"} = unit, v, _strategy, memory), do: scout(unit, v, memory)
  defp act(%{"type" => "Trebuchet"} = unit, _v, strategy, memory), do: siege(unit, strategy, memory)
  defp act(unit, v, strategy, memory), do: fighter(unit, v, strategy, memory)

  # A miner about to be hit runs to the rally point, where help comes from. Once it is safe and
  # idle it goes back to mining. Builders keep building.
  defp worker(%{"activity" => activity} = unit, v, %{rally: {rx, ry}})
       when activity in ["Idle", "Gathering", "Returning"] do
    if in_danger?(unit, v),
      do: %{"type" => "Move", "unitIds" => [unit["id"]], "x" => rx, "y" => ry},
      else: worker(unit, v)
  end

  defp worker(unit, v, _strategy), do: worker(unit, v)

  defp in_danger?(unit, v) do
    Enum.any?(v.enemy_units, fn e ->
      e["type"] != "Worker" and View.dist(View.pos(e), View.pos(unit)) <= Roles.range(e) + 1
    end)
  end

  # An idle worker picks a deposit. So does one mining a deposit too far from any drop-off,
  # once there is a closer one.
  defp worker(unit, %View{deposits: [_ | _]} = v) do
    near = View.near_deposits(v)

    far_away? =
      unit["activity"] in ["Gathering", "Returning"] and near != [] and
        Enum.any?(v.deposits, &(&1["id"] == unit["targetId"])) and
        not Enum.any?(near, &(&1["id"] == unit["targetId"]))

    if unit["activity"] == "Idle" or far_away? do
      best = pick_deposit(unit, v, if(near == [], do: v.deposits, else: near))
      %{"type" => "Gather", "unitIds" => [unit["id"]], "targetId" => best["id"]}
    else
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
      enemy = Roles.target(v, s.wave, unit) -> {:attack, enemy["id"]}
      role == :wave and Roles.turn_back?(v, s) -> {:attack_move, s.threat.pos}
      role == :wave -> {:attack_move, s.target}
      match?({:escort, _}, role) -> escort(v, s, elem(role, 1))
      s.threat -> {:attack_move, s.threat.pos}
      help = role == :attacker && closest_help(v, unit) -> {:attack_move, help}
      role == :guard -> {:move, s.post}
      true -> {:move, s.rally}
    end
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

  # A Trebuchet holds the guard post (behind the front tower) and lets the game aim it: an idle
  # one fires by itself, at enemies standing still first, like a wave stopped at our tower. With
  # no base left it joins the attack.
  defp siege(unit, s, memory) do
    intent = if s.post, do: {:move, s.post}, else: {:attack_move, s.target}

    if carrying_out?(unit, intent, memory.intent),
      do: {:no_change, memory},
      else: {command(unit, intent), %{memory | intent: intent}}
  end

  defp scout(unit, v, memory) do
    here = View.pos(unit)
    spots = my_spots(v, unit)
    goal = Map.get(memory, :goal)
    seen = Map.get(memory, :seen, %{})
    seen = Enum.reduce(spots, seen, &if(View.dist(&1, here) <= @scout_sight, do: Map.put(&2, &1, v.tick), else: &2))

    # Idle short of its goal: the goal can't be reached, give up on it.
    seen =
      if goal && unit["activity"] == "Idle" && View.dist(goal, here) > @scout_sight,
        do: Map.put(seen, goal, v.tick),
        else: seen

    hurt? = unit["hp"] != nil and unit["hp"] < Map.get(memory, :hp, unit["hp"])

    {intent, goal, seen} =
      case danger(v, here, hurt?) do
        nil ->
          goal = next_spot(v, spots, seen, here)
          {{:move, goal}, goal, seen}

        from ->
          # Run, and count the goal and the area we ran from as just seen, without the enemy
          # base bonus: check other spots before coming back.
          later = v.tick + @enemy_base_bonus
          avoid = &(&1 == goal or View.dist(&1, from) <= 8)
          seen = Enum.reduce(spots, seen, &if(avoid.(&1), do: Map.put(&2, &1, later), else: &2))
          {{:move, away(v, here, from)}, nil, seen}
      end

    memory = Map.merge(memory, %{seen: seen, goal: goal, hp: unit["hp"]})

    if carrying_out?(unit, intent, memory.intent),
      do: {:no_change, memory},
      else: {command(unit, intent), %{memory | intent: intent}}
  end

  # The enemy starts and a coarse grid over the map, shared out between the scouts by id so
  # they don't follow each other: with three opponents, each scout gets one enemy start.
  defp my_spots(v, unit) do
    # Grid points right by an enemy start would just be that start again.
    grid =
      for x <- 8..(v.map_width - 1)//16,
          y <- 8..(v.map_height - 1)//16,
          not Enum.any?(v.enemy_starts, &(View.dist(&1, {x, y}) <= @scout_sight)),
          do: {x, y}

    scouts = v |> View.units_of("Scout") |> Enum.map(& &1["id"]) |> Enum.sort()
    n = length(scouts)
    me = Enum.find_index(scouts, &(&1 == unit["id"]))

    for {spot, i} <- Enum.with_index(Enum.uniq(v.enemy_starts ++ grid)), rem(i, n) == me, do: spot
  end

  # The spot seen longest ago (never seen first); closest on a tie.
  defp next_spot(v, spots, seen, here) do
    enemy = Enum.map(v.enemy_buildings ++ v.remembered, &View.pos/1) ++ v.enemy_starts

    Enum.min_by(spots, fn spot ->
      bonus = if Enum.any?(enemy, &(View.dist(&1, spot) <= 12)), do: @enemy_base_bonus, else: 0
      {Map.get(seen, spot, -1000) - bonus, View.dist(spot, here), spot}
    end)
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
