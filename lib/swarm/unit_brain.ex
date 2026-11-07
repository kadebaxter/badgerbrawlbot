defmodule Swarm.UnitBrain do
  @moduledoc """
  One unit's decision. Pure: given the view, the team strategy and this unit's own memory,
  return the command for this unit only (or `:no_change`) and its updated memory.

  Workers mine the closest ore to a drop-off that isn't crowded, and ore farther away on our side
  (remembered deposits too) only when that is all unsafe. They run for cover by our towers when an
  enemy is about to hit them, or is coming at them out of our towers' reach while we are losing
  there or home is falling back; with nothing safe to mine they wait by a tower. A fighter first works out its role (`Swarm.Roles`), then, in order:

  0. an archer losing the fight around it (the enemy fighters near it are stronger than ours) with
     an enemy soldier or scout about to reach it: step back toward home, then shoot again from
     range (kiting). Winning, it stands and shoots: archers are slower than soldiers, so backing
     off from one they could kill only stops them shooting.
  1. something to fight nearby (`Swarm.Roles.target/3`: enemy fighters first, shared out so
     none is overkilled; fighters at home don't chase out of the base): attack it
  2. in the wave: attack-move to the target, or to the threat if the wave turns back
  3. an escort: fight enemies at its outpost, else stand by it (a checker, sent to look around a
     building of ours hit by something we can't see, goes to its spot first)
  4. guards and attackers, with an enemy building going up by one of our bases: kill the site
  5. guards and attackers, with enemies at the main base: attack-move to the threat, unless it
     is under an enemy tower (a strike deals with that, not one unit at a time)
  6. an attacker, with an outpost or our workers under attack: go help (the closest)
  7. otherwise go to its spot: guards to the post, attackers to the rally point

  Scouts watch, one per neighbor (the two nearest opponents): each waits halfway between our
  Command Center and its neighbor's start, where an attack from them comes through. When the leader
  wants a look at a target before attacking (`strategy.look`), the scout watching that side goes
  there, then comes back to its post; the other stays. While a wave is out, the scout watching
  the side of its target works in front of it: `@scout_ahead` tiles ahead of its lead unit for up
  to `@ahead_ticks` ticks, then `@scout_behind` tiles behind it for `@behind_ticks`, out of the
  fight, and again; the wave doesn't wait for it. A scout steps back once an enemy could reach it
  or it is taking damage: just out of reach, straight away from it (with the wave, behind the
  wave), not all the way home, and waits `@scout_rest` ticks before going back. A post or a spot to
  look from that an enemy we can see covers is pulled back out of its reach first. Its memory holds
  its HP last tick and when it last stepped back.

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
  # Units this close to a spot where we were hit by something we can't see step this far from it.
  @hidden_clear 7
  # An enemy fighter this close to a miner out of our towers' reach, when we are losing there or
  # falling back, sends it to cover.
  @worker_alarm 6
  # A scout runs from an enemy (or tower) once it is within the enemy's range plus this. The
  # scout is twice as fast as anything else, so that is enough to get away.
  @scout_margin 2
  # How far past a threat's reach a scout steps back to.
  @scout_clear 2
  # How long a scout that stepped back stays there before returning to its job.
  @scout_rest 6
  # A scout with the wave: this far ahead of its lead unit, for at most this long (less once it is
  # there), then this far behind its middle, for this long.
  @scout_ahead 6
  @ahead_ticks 8
  @scout_behind 5
  @behind_ticks 10

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

  # A miner in danger runs to cover: to the closest of our Guard Towers on our side of the enemy
  # (else help or a drop-off). Once it is safe and idle it goes back to mining, but not to ore
  # with enemies by it. Builders keep building.
  defp worker(%{"activity" => activity} = unit, v, %{rally: rally} = s)
       when activity in ["Idle", "Gathering", "Returning"] and rally != nil do
    case worker_danger(unit, v, s) || hidden_near(unit, s) do
      nil ->
        worker(unit, v)

      enemy ->
        {x, y} = spot = refuge(unit, v, enemy) || rally

        # Already there: it may mine ore safe from here (`unsafe?/2`), or stays.
        if View.dist(View.pos(unit), spot) <= 1,
          do: worker(unit, v),
          else: %{"type" => "Move", "unitIds" => [unit["id"]], "x" => x, "y" => y}
    end
  end

  defp worker(unit, v, _strategy), do: worker(unit, v)

  # The closest enemy fighter this worker should run from, or nil: one about to hit it, or, out of
  # our towers' reach, one coming at it (within `@worker_alarm`) while home is falling back or the
  # enemies around it are stronger than our fighters there. A miner doesn't wait to be hit.
  defp worker_danger(unit, v, s) do
    here = View.pos(unit)
    enemies = Enum.filter(v.enemy_units, &(&1["type"] != "Worker" and View.dist(View.pos(&1), here) <= @worker_alarm))
    closest = Enum.min_by(enemies, &{View.dist(View.pos(&1), here), &1["id"]}, fn -> nil end)

    cond do
      closest == nil -> nil
      View.dist(View.pos(closest), here) <= Roles.range(closest) + 1 -> closest
      Roles.sheltered?(v, here) -> nil
      Map.get(s, :fall_back, false) or Roles.losing_at?(v, here, @worker_alarm) -> closest
      true -> nil
    end
  end

  # A spot near this worker where we were hit by something we can't see (as a position to run
  # from), or nil.
  defp hidden_near(unit, s) do
    here = View.pos(unit)

    Enum.find_value(Map.get(s, :hidden, []), fn %{pos: {x, y} = pos} ->
      if View.dist(here, pos) < @hidden_clear, do: %{"x" => x, "y" => y}
    end)
  end

  # Where to run: by the closest of our towers on our side of the enemy (`Roles.shelter/3`); else
  # the closest of our fighters or drop-offs on our side of it (closer to this worker than to it,
  # so the way there doesn't go past it). Nil if there is none.
  defp refuge(unit, v, enemy) do
    here = View.pos(unit)
    there = View.pos(enemy)

    tower = if v.cc && Enum.any?(View.buildings_of(v, "GuardTower"), & &1["completed"]), do: Roles.shelter(v, here, there)

    tower ||
      (Enum.map(Roles.fighters(v), &View.pos/1) ++ View.drop_offs(v))
      |> Enum.filter(&(View.dist(&1, here) < View.dist(&1, there)))
      |> Enum.min_by(&{View.dist(&1, here), &1}, fn -> nil end)
  end

  # Ore with an enemy fighter this close isn't worth walking into.
  defp unsafe?(deposit, v) do
    Enum.any?(v.enemy_units, &(&1["type"] != "Worker" and View.dist(View.pos(&1), View.pos(deposit)) <= @unsafe_ore))
  end

  # An idle worker picks a deposit. So does one mining a deposit too far from any drop-off (once
  # there is a closer one), or one with enemies by it. With no ore by a drop-off, ore by a depot
  # being built comes first: the brain put it by the field it expects miners at, so they don't
  # scatter to another far one. With all of that unsafe, safe ore farther away on our side
  # (deposits we remember count: a Gather may name one in the fog), where the brain puts a depot
  # once miners are there. With no safe ore at all, an idle worker waits under our towers.
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

    choices =
      case Enum.reject(near, &unsafe?(&1, v)) do
        [] -> far_ore(v, near)
        safe -> safe
      end

    case move? && choices do
      [_ | _] ->
        best = pick_deposit(unit, v, choices)
        if best["id"] == unit["targetId"], do: :no_change, else: %{"type" => "Gather", "unitIds" => [unit["id"]], "targetId" => best["id"]}

      [] ->
        take_cover(unit, v)

      _ ->
        :no_change
    end
  end

  defp worker(unit, v), do: take_cover(unit, v)

  # Safe ore away from our drop-offs: on our side of the map; with none there and none by a
  # drop-off at all, any we can see (as before we remembered ore).
  defp far_ore(v, near) do
    far = Enum.reject(v.deposits, &(&1 in near or unsafe?(&1, v)))

    case Enum.filter(far, &View.ours?(v, View.pos(&1))) do
      [] when near == [] -> Enum.filter(far, &(not Map.has_key?(&1, "seen")))
      ours -> ours
    end
  end

  # An idle worker with nothing safe to do stands by the tower closest to it, not out in the open.
  defp take_cover(%{"activity" => "Idle"} = unit, v) do
    here = View.pos(unit)

    case Roles.shelter(v, here) do
      {x, y} = spot -> if View.dist(here, spot) > 2, do: %{"type" => "Move", "unitIds" => [unit["id"]], "x" => x, "y" => y}, else: :no_change
      nil -> :no_change
    end
  end

  defp take_cover(_unit, _v), do: :no_change

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

  # The tick the leader takes the serum, every Soldier sends its order again, so that it goes out
  # with the serum key: the serum only boosts Soldiers a command with the key reaches.
  defp fighter(unit, v, strategy, memory) do
    intent = intent(unit, v, strategy)
    serum? = Map.get(strategy, :serum) == :take and unit["type"] == "Soldier"

    if carrying_out?(unit, intent, memory.intent) and not serum?,
      do: {:no_change, memory},
      else: {command(unit, intent), %{memory | intent: intent}}
  end

  defp intent(unit, v, s) do
    role = if s.rally, do: Roles.role(v, s.wave, unit["id"]), else: :wave

    cond do
      back = unit["type"] == "Archer" && outnumbered?(v, View.pos(unit)) && kite(unit, v, s, @melee, @kite_distance) -> {:move, back}
      enemy = Roles.fighter_target(v, s.wave, unit) -> {:attack, enemy["id"]}
      job = Roles.tower_job(v, s.wave, unit) -> tower_intent(v, job)
      look = looking(s, unit) -> {:move, look}
      away = clear_of_hidden(unit, s) -> {:move, away}
      enemy = Roles.leftover_target(v, s.wave, unit) -> {:attack, enemy["id"]}
      spot = s |> Map.get(:check, %{}) |> Map.get(unit["id"]) -> {:attack_move, spot}
      role == :wave and holding?(s) -> {:attack_move, s.wave.staging}
      role == :wave -> {:attack_move, s.target}
      match?({:escort, _}, role) -> escort(v, s, elem(role, 1))
      raze = role in [:attacker, :guard] && Map.get(s, :raze) -> {:attack, raze}
      s.threat && not Roles.covered?(v, s.threat.pos) -> {:attack_move, cover(v, s, s.threat.pos)}
      help = role == :attacker && closest_help(v, unit) -> {:attack_move, cover(v, s, help)}
      role == :guard -> {:move, s.post}
      true -> {:move, s.rally}
    end
  end

  # A tower shooting at the wave (`Roles.tower_job/3`): attack it if we can see it, else walk at it
  # until we do (the server lets us attack only what we see, and our Soldiers often can't see a
  # tower that reaches them); or step out of its reach.
  defp tower_intent(v, {:hit, tower}) do
    if Enum.any?(v.enemy_buildings, &(&1["id"] == tower["id"])),
      do: {:attack, tower["id"]},
      else: {:move, View.pos(tower)}
  end

  defp tower_intent(_v, {:back_off, spot}), do: {:move, spot}

  # This unit is the one sent to look where we were hit by something we can't see
  # (`strategy.hidden`): where it goes, or nil.
  defp looking(s, unit) do
    Enum.find_value(Map.get(s, :hidden, []), fn h -> if h.by == unit["id"], do: h.look end)
  end

  # Near a spot where we were hit by something we can't see (and not the one looking): out of the
  # area, `@hidden_clear` tiles from the spot toward home, until the look finds it. Nil otherwise.
  defp clear_of_hidden(unit, s) do
    here = View.pos(unit)
    home = s.rally

    Enum.find_value(Map.get(s, :hidden, []), fn h ->
      if home && View.dist(here, h.pos) < @hidden_clear and h.by != unit["id"],
        do: toward(h.pos, home, @hidden_clear)
    end)
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
      threat -> {:attack_move, cover(v, s, threat.pos)}
    end
  end

  # Where to meet an attack at `pos`: there, unless home is falling back (`Roles.fall_back?/2`) and
  # none of our towers reaches it. Then by the tower closest to it, where the workers run to: we
  # cover them there, and whatever follows them fights the towers too.
  defp cover(v, s, pos) do
    if Map.get(s, :fall_back, false) and not Roles.sheltered?(v, pos),
      do: Roles.shelter(v, pos) || pos,
      else: pos
  end

  # Not under an enemy tower: a strike goes there, not one unit at a time.
  defp closest_help(v, unit) do
    case Enum.reject(Roles.help_wanted(v), &Roles.covered?(v, &1)) do
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

    job = scout_job(v, s, unit)

    {intent, fled_at, phase} =
      cond do
        threat = danger(v, here, hurt?) -> run(v, s, here, threat, hurt?, job)
        fled_at != nil and v.tick - fled_at < @scout_rest -> {memory.intent || {:move, here}, fled_at, Map.get(memory, :phase)}
        true -> scout_post(v, s, here, job, Map.get(memory, :phase))
      end

    memory = Map.merge(memory, %{hp: unit["hp"], fled_at: fled_at, phase: phase})

    if carrying_out?(unit, intent, memory.intent),
      do: {:no_change, memory},
      else: {command(unit, intent), %{memory | intent: intent}}
  end

  @doc """
  What each of our scouts is doing, for the leader's log: [{id, job, position}], where the job is
  `:look` (looking at a target before a wave leaves), `:wave` (working in front of the wave out),
  `:reveal` (looking for what hit us that we couldn't see), `:survey` (looking round our side for
  ore) or `:post` (watching its side from halfway).
  """
  def scout_jobs(%View{} = v, strategy) do
    for u <- View.units_of(v, "Scout"), do: {u["id"], elem(scout_job(v, strategy, u), 0), View.pos(u)}
  end

  # The spot the leader wants looked at, for the scout watching that side; with a wave out, the
  # wave, for the scout watching its target's side; otherwise its post halfway to our neighbor.
  defp scout_job(v, s, unit) do
    spot = Map.get(s, :look)
    front = s.wave && s.target && s.rally && wave_front(v, s.wave, s.target)

    survey = Map.get(s, :survey)
    reveal = looking(s, unit)

    cond do
      reveal -> {:reveal, reveal}
      spot && looker(v, spot) == unit["id"] -> {:look, spot}
      front && looker(v, s.target) == unit["id"] -> {:wave, front}
      survey && surveyor?(v, unit) -> {:survey, survey}
      true -> {:post, watch_post(v, unit)}
    end
  end

  # The scout that looks for ore when the leader asks (`strategy.survey`): the first by id.
  defp surveyor?(v, unit), do: unit["id"] == v |> View.units_of("Scout") |> Enum.map(& &1["id"]) |> Enum.min()

  # A threatened scout steps back: with the wave, behind it (and stays behind it a while), if that
  # takes it away from the threat; otherwise just out of the threat's reach (`step_back/4`).
  defp run(v, s, here, threat, hurt?, {:wave, {_lead, middle}}) do
    from = View.pos(threat)
    behind = toward(middle, s.rally, @scout_behind)

    if View.dist(behind, from) > View.dist(here, from),
      do: {{:move, behind}, v.tick, {:behind, v.tick}},
      else: {{:move, step_back(v, here, threat, hurt?)}, v.tick, {:behind, v.tick}}
  end

  defp run(v, _s, here, threat, hurt?, _job), do: {{:move, step_back(v, here, threat, hurt?)}, v.tick, nil}

  # Returns {intent, nil, its phase with the wave}. A post or a spot to look from that an enemy we
  # can see covers is pulled back out of its reach, or the scout would walk into it again.
  defp scout_post(v, _s, _here, {:look, spot}, _phase), do: {{:move, safe_spot(v, spot)}, nil, nil}
  defp scout_post(v, s, here, {:wave, front}, phase), do: with_wave(v, s, here, front, phase)
  defp scout_post(v, _s, _here, {:post, spot}, _phase), do: {{:move, safe_spot(v, spot)}, nil, nil}
  defp scout_post(v, _s, _here, {:survey, spot}, _phase), do: {{:move, safe_spot(v, spot)}, nil, nil}
  # Straight there: the point is to see what we can't (it backs off once it does, `danger/3`).
  defp scout_post(_v, _s, _here, {:reveal, spot}, _phase), do: {{:move, spot}, nil, nil}

  # A little past the threat's reach (`@scout_clear` tiles), straight away from it: the scout keeps
  # watching, not running home. Taking damage, at least 3 tiles farther than now (something we
  # may not even see is hitting us). Toward home only if the threat is right on top of us.
  defp step_back(v, {x, y} = here, threat, hurt?) do
    {fx, fy} = from = View.pos(threat)
    d = View.dist(here, from)
    clear = if hurt?, do: max(reach(threat) + @scout_clear, d + 3), else: reach(threat) + @scout_clear

    if d == 0,
      do: flee(v, here, from),
      else: {clamp(fx + div((x - fx) * clear, d), v.map_width), clamp(fy + div((y - fy) * clear, d), v.map_height)}
  end

  # How close a threat may come before a scout steps back: its range plus `@scout_margin`, plus one.
  defp reach(threat), do: Roles.range(threat) + @scout_margin + 1

  # `spot`, or, if an enemy we can see covers it, back toward home (2 tiles at a time) until none does.
  defp safe_spot(%View{cc: nil}, spot), do: spot

  defp safe_spot(%View{cc: cc} = v, spot) do
    covered? = fn tile -> Enum.any?(threats(v), &(View.dist(View.pos(&1), tile) <= reach(&1))) end

    Stream.iterate(spot, &toward(&1, View.pos(cc), 2))
    |> Stream.take(15)
    |> Enum.find(spot, &(not covered?.(&1)))
  end

  # Ahead of the wave's lead unit for a while (or until it is there), then behind the wave's
  # middle for a while, and again. `phase` is {:ahead | :behind, since tick}. Not ahead into a
  # fight: with enemies already by the spot ahead, the wave is at them and there is nothing left
  # to see, so the scout stays behind.
  defp with_wave(v, s, here, {lead, middle}, phase) do
    ahead = toward(lead, s.target, @scout_ahead)
    behind = toward(middle, s.rally, @scout_behind)
    fight? = Enum.any?(threats(v), &(View.dist(View.pos(&1), ahead) <= Roles.range(&1) + @scout_margin + 1))

    phase =
      case phase do
        {:ahead, since} ->
          if v.tick - since >= @ahead_ticks or View.dist(here, ahead) <= 2, do: {:behind, v.tick}, else: phase

        {:behind, since} ->
          if v.tick - since >= @behind_ticks, do: {:ahead, v.tick}, else: phase

        nil ->
          {:ahead, v.tick}
      end

    spot = if elem(phase, 0) == :ahead and not fight?, do: ahead, else: behind
    {{:move, spot}, nil, phase}
  end

  # {the wave member nearest its target, the middle of the wave}, or nil with none of it left.
  defp wave_front(v, %{members: members} = wave, target) do
    case Enum.filter(v.my_units, &(&1["id"] in members)) do
      [] ->
        nil

      alive ->
        lead = Enum.min_by(alive, &{View.dist(View.pos(&1), target), &1["id"]})
        {View.pos(lead), Roles.wave_center(v, wave)}
    end
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

  # What can hurt a scout: enemy fighters and towers.
  defp threats(v),
    do: Enum.filter(v.enemy_units, &(&1["type"] != "Worker")) ++ Enum.filter(v.enemy_buildings, &(&1["type"] == "GuardTower"))

  # Six tiles toward home, or straight away from the threat when it is closer to home than we are
  # (between us and home), or we have no home left.
  defp flee(%View{cc: nil} = v, here, from), do: away(v, here, from)

  defp flee(%View{cc: cc} = v, here, from) do
    home = View.pos(cc)
    if View.dist(here, home) <= View.dist(from, home), do: toward(here, home, 6), else: away(v, here, from)
  end

  # The closest enemy fighter or tower that could reach us. Taking damage, the closest one we
  # can see at all: something is hitting us. The unit or tower itself.
  defp danger(v, here, hurt?) do
    close =
      Enum.filter(threats(v), fn t ->
        d = View.dist(View.pos(t), here)
        d <= Roles.range(t) + @scout_margin or (hurt? and d <= 8)
      end)

    case close do
      [] -> nil
      near -> Enum.min_by(near, &View.dist(View.pos(&1), here))
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
