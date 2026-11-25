defmodule Swarm.StalledScenarioTest do
  @moduledoc """
  One situation, start to finish: two players on a 64x64 map (72,000 ore), everyone together has
  banked 69,000 (so the count says 3,000 may be left), we banked our last ore 150 ticks ago, 15
  workers stand idle at home, we have 20 Soldiers and no Scout, and the enemy still has an army of
  15 by their base. What do we do?
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  @built [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 11, 11), building(6, "TechLab", 9, 4)]
  @theirs [building(900, "CommandCenter", 56, 56, 1), building(901, "Barracks", 52, 52, 1), building(902, "GuardTower", 50, 54, 1)]

  defp army, do: for(i <- 1..15, do: unit(900 + i, "Soldier", 48, 48, owner: 1))
  defp idle, do: for(i <- 1..15, do: unit(100 + i, "Worker", 8, 8))

  defp tick(tick, units, deposits, mine, memory) do
    state =
      state(units: units, buildings: @built ++ @theirs, deposits: deposits, ore: 120, tick: tick)
      |> Map.update!("players", fn [me, them] ->
        [Map.put(me, "score", %{"economy" => mine, "total" => mine}), Map.put(them, "score", %{"economy" => 29_000, "total" => 29_000, "survival" => 4000})]
      end)

    {v, memory} = Brain.see(View.new(state), memory)
    {strategy, commands, memory} = Brain.plan(v, memory, terrain())
    orders = for w <- View.units_of(v, "Worker"), {cmd, _} = UnitBrain.decide(w["id"], v, strategy), is_map(cmd), into: %{}, do: {w["id"], cmd}
    %{v: v, strategy: strategy, commands: commands, memory: memory, orders: orders, log: for({:economy, text} <- strategy.why, do: text)}
  end

  defp start, do: %{Brain.new_memory() | map_ore: 72_000, income_at: {40_000, 450}}
  defp trained(t), do: for(%{"type" => "Produce", "unitType" => u} <- t.commands, do: u)

  test "stalled: no more workers, four go looking for ore where it is safe, one looks at the enemy, the army stays home" do
    t = tick(600, idle() ++ soldiers(20) ++ army(), [], 40_000, start())

    # It knows the map isn't proven empty: 3,000 may be left. It says why it is acting.
    assert t.memory.map_ore - t.v.mined_all == 3000
    assert [stalled, search] = t.log
    assert stalled =~ "banked nothing for 150 ticks" and stalled =~ "at most 3000 left"
    assert search =~ "4 worker(s) go looking for ore"

    # No more workers while nothing is coming in.
    refute "Worker" in trained(t)

    # Worker 101 stands in for the dead scouts and goes to look at the enemy; 102 to 105 each go to
    # their own place to look for ore, none of them by the enemy's base.
    assert t.strategy.worker_scout == 101
    assert Enum.sort(Map.keys(t.strategy.search)) == [102, 103, 104, 105]
    places = Map.values(t.strategy.search)
    assert length(Enum.uniq(places)) == 4
    assert Enum.all?(places, &(View.dist(&1, {56, 56}) >= 14))
    assert %{"type" => "Move", "x" => 52, "y" => 52} = t.orders[101]
    for {id, {x, y}} <- t.strategy.search, do: assert(%{"type" => "Move", "x" => ^x, "y" => ^y} = t.orders[id])

    # The army doesn't walk into fifteen Soldiers and a tower with thirteen attackers.
    assert t.strategy.wave == nil
    # Their Command Center is not finished off on a stall: they still have an army and buildings.
    assert t.memory.kill == nil
  end

  test "a searcher finds ore: everyone idle goes to mine it, and once it is banked workers are trained again" do
    t = tick(600, idle() ++ soldiers(20) ++ army(), [], 40_000, start())
    {x, y} = t.strategy.search[102]
    pile = [%{"id" => 77, "x" => x + 2, "y" => y, "remaining" => 1500}]

    # Worker 102 has walked to its place and sees a pile of 1,500 two tiles on.
    there = Enum.map(idle(), &if(&1["id"] == 102, do: %{&1 | "x" => x, "y" => y}, else: &1))
    t = tick(640, there ++ soldiers(20), pile, 40_000, t.memory)
    miners = for {id, %{"type" => "Gather", "targetId" => 77}} <- t.orders, do: id
    assert length(miners) >= 10

    # The first load is banked: the stall is over, the search stops.
    mining = Enum.map(there, &if(&1["id"] in miners, do: %{&1 | "activity" => "Gathering", "targetId" => 77}, else: &1))
    t = tick(660, mining ++ soldiers(20), pile, 40_010, t.memory)
    assert "mining again: workers are trained as usual" in t.log
    assert t.strategy.search == %{}
    refute t.memory.mined_out
  end

  test "nothing found anywhere we may go, their army still alive: said once, their Command Center still isn't finished off" do
    everywhere = for a <- 0..63//3, b <- 0..63//3, do: {a, b}
    t = tick(900, idle() ++ soldiers(20), [], 40_000, %{start() | searched: everywhere})
    assert Enum.any?(t.log, &(&1 =~ "looked for ore everywhere we may go"))
    assert t.strategy.search == %{}

    # What may be left is by their base, behind their army: no ending the match on that.
    t = tick(901, idle() ++ soldiers(20), [], 40_000, t.memory)
    assert t.memory.search_done and t.memory.mined_out
    assert t.memory.kill == nil
    refute "Worker" in trained(t)
  end

  describe "stalled, with ore left by an opponent's base" do
    # Three players: player 1 at (56, 56) and player 2 at (7, 56). 3,000 ore by player 2's base.
    @by_two for i <- 0..2, do: %{"id" => 70 + i, "x" => 10 + i, "y" => 50, "remaining" => 1000}

    defp three(units, deposits, scores, memory \\ nil) do
      {one, two} = scores
      state =
        state(units: units, buildings: @built, deposits: deposits, ore: 120, tick: 600)
        |> Map.update!("players", fn [me, them] ->
          third = %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56}}
          [Map.put(me, "score", %{"economy" => 20_000, "total" => 20_000}),
           Map.put(them, "score", %{"economy" => 20_000, "total" => 20_000, "survival" => one}),
           Map.put(third, "score", %{"economy" => 20_000, "total" => 20_000, "survival" => two})]
        end)

      {v, memory} = Brain.see(View.new(state), memory || %{Brain.new_memory() | map_ore: 72_000, income_at: {20_000, 450}})
      {strategy, _, _} = Brain.plan(v, memory, terrain())
      strategy
    end

    test "that opponent is who we go after, not the weaker neighbor" do
      # Player 1 is the weaker by score (600 alive to player 2's 900): the usual choice.
      assert %{target: {56, 56}} = three(idle() ++ soldiers(20), [], {600, 900})
      # With 3,000 ore by player 2's base and nothing else for us to mine: player 2.
      assert %{target: {7, 56}} = three(idle() ++ soldiers(20), @by_two, {600, 900})
    end

    test "not while we are still mining, and not one whose army we couldn't take" do
      mining = for i <- 1..15, do: unit(100 + i, "Worker", 8, 8, activity: "Gathering", target_id: 4)
      assert %{target: {56, 56}} = three(mining ++ soldiers(20), @by_two, {600, 900})
      # Thirty Soldiers of theirs by that ore, seen: not with our twenty.
      guard = for i <- 1..30, do: unit(900 + i, "Soldier", 9, 54, owner: 2)
      assert %{target: {56, 56}} = three(idle() ++ soldiers(20) ++ guard, @by_two, {600, 4000})
    end

    # The same game a hundred ticks on, tick by tick: what the leader plans and what each worker does.
    defp step(tick, units, deposits, two_out?, memory, buildings \\ @built) do
      state =
        state(units: units, buildings: buildings, deposits: deposits, ore: 120, tick: tick)
        |> Map.update!("players", fn [me, them] ->
          third = %{"slot" => 2, "eliminated" => two_out?, "startPosition" => %{"x" => 7, "y" => 56}}
          score = fn p, alive -> Map.put(p, "score", %{"economy" => 20_000, "total" => 20_000, "survival" => alive}) end
          [score.(me, 3000), score.(them, 600), score.(third, if(two_out?, do: 0, else: 900))]
        end)

      {v, memory} = Brain.see(View.new(state), memory)
      {strategy, commands, memory} = Brain.plan(v, memory, terrain())
      v = UnitBrain.prepare(v, strategy.wave)
      orders = for w <- View.units_of(v, "Worker"), {cmd, _} = UnitBrain.decide(w["id"], v, strategy), is_map(cmd), into: %{}, do: {w["id"], cmd}
      %{strategy: strategy, commands: commands, memory: memory, orders: orders}
    end

    test "the whole of it: we go for them, they fall, our workers go and mine that ore, and a depot goes up by it" do
      memory = %{Brain.new_memory() | map_ore: 72_000, income_at: {20_000, 450}}

      # 1. Stalled, 3,000 ore by player 2's base: player 2 is the target.
      t = step(600, idle() ++ soldiers(20), @by_two, false, memory)
      assert t.strategy.target == {7, 56}

      # 2. Player 2 is out. The ore by their start is ours to take: the idle workers are sent to it.
      t = step(700, idle() ++ soldiers(20), @by_two, true, t.memory)
      going = for {_id, %{"type" => "Gather", "targetId" => d}} <- t.orders, d in 70..72, do: d
      assert length(going) >= 10

      # 3. They are mining it, 45 tiles from our nearest drop-off: a depot is ordered by it, with
      # three builders or more, though the ore we have (120) is short of everything else.
      miners = for i <- 1..15, do: unit(100 + i, "Worker", 11, 51, activity: "Gathering", target_id: 70)
      t = step(760, miners ++ soldiers(20), @by_two, true, t.memory)
      assert [%{"x" => x, "y" => y, "unitIds" => builders}] = for(%{"type" => "Build", "buildingType" => "ResourceDepot"} = c <- t.commands, do: c)
      assert View.dist({x, y}, {11, 50}) <= 3
      assert length(builders) >= 3

      # 4. With the depot up by it, they mine on with no walk: nobody is told to go anywhere else.
      depot = building(80, "ResourceDepot", x, y)
      t = step(790, miners ++ soldiers(20), @by_two, true, t.memory, [depot | @built])
      assert for({_id, %{"type" => type}} <- t.orders, type in ["Move", "Gather"], do: type) == []
    end
  end

  describe "the map mined out, behind on score" do
    # Two players, 72,000 ore on the map and 71,500 of it banked. We have 7 Soldiers and 15 idle
    # workers and 20,000 points to their 30,000; `alive` is the ore value of all they have alive.
    defp late(alive, tick \\ 800) do
      state =
        state(units: idle() ++ soldiers(7), buildings: @built ++ @theirs, deposits: [], ore: 120, tick: tick)
        |> Map.update!("players", fn [me, them] ->
          [Map.put(me, "score", %{"economy" => 35_500, "total" => 20_000}),
           Map.put(them, "score", %{"economy" => 36_000, "total" => 30_000, "survival" => alive})]
        end)

      {v, memory} = Brain.see(View.new(state), %{Brain.new_memory() | map_ore: 72_000, income_at: {35_500, 450}})
      {strategy, _commands, _memory} = Brain.plan(v, memory, terrain())
      v = UnitBrain.prepare(v, strategy.wave)
      orders = for w <- View.units_of(v, "Worker"), {cmd, _} = UnitBrain.decide(w["id"], v, strategy), is_map(cmd), into: %{}, do: {w["id"], cmd}
      %{strategy: strategy, orders: orders, log: for({:all_in, text} <- strategy.why, do: text)}
    end

    test "with nobody left who has an army we couldn't take, everyone goes now, the workers too" do
      # 1,500 alive: their buildings and workers, no army to speak of.
      t = late(1500)
      assert %{all_in: true, members: members} = t.strategy.wave
      assert length(members) == 7
      assert [why] = t.log
      assert why =~ "the map mined out and nobody with an army" and why =~ "15 workers"
      {tx, ty} = t.strategy.target
      assert map_size(t.orders) == 15
      for {_id, cmd} <- t.orders, do: assert(%{"type" => "Attack", "x" => ^tx, "y" => ^ty} = cmd)
    end

    test "a raid on our base then: the workers by it attack it, through the leader's plan and all" do
      # The same, with ten of theirs at our Command Center (and an army's worth alive: nobody is sent out).
      raid = for i <- 1..10, do: unit(900 + i, "Soldier", 9, 9, owner: 1)
      state =
        state(units: idle() ++ soldiers(7) ++ raid, buildings: @built ++ @theirs, deposits: [], ore: 120, tick: 800)
        |> Map.update!("players", fn [me, them] ->
          [Map.put(me, "score", %{"economy" => 35_500, "total" => 20_000}), Map.put(them, "score", %{"economy" => 36_000, "total" => 30_000, "survival" => 8000})]
        end)

      {v, memory} = Brain.see(View.new(state), %{Brain.new_memory() | map_ore: 72_000, income_at: {35_500, 450}})
      {strategy, _commands, _memory} = Brain.plan(v, memory, terrain())
      assert strategy.no_ore == :mined_out
      # The view the units get is the one from before the plan: the strategy is what tells them.
      assert v.no_ore == false
      v = UnitBrain.prepare(v, strategy.wave)
      orders = for w <- View.units_of(v, "Worker"), {cmd, _} = UnitBrain.decide(w["id"], v, strategy), is_map(cmd), do: cmd
      assert length(orders) == 15
      for cmd <- orders, do: assert(%{"type" => "Attack", "x" => 9, "y" => 9} = cmd)
    end

    test "not while they still have an army: forty Soldiers' worth alive beyond their buildings and workers" do
      t = late(8000)
      assert t.strategy.wave == nil or not Map.get(t.strategy.wave, :all_in, false)
      assert t.log == []
      refute Enum.any?(t.orders, fn {_id, cmd} -> cmd["type"] == "Attack" end)
    end
  end

end
