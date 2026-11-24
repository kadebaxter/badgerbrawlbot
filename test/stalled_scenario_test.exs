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
end
