defmodule Swarm.EconomyTest do
  @moduledoc """
  Keeping the economy alive: remembering ore, looking for it, workers taking cover, ore kept back
  for workers, and home falling back to the towers when a raid is too strong for it.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, UnitBrain, View}

  # Us at (7, 7), the enemy at (56, 56), on an open 64x64 map.
  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
  @south %{"id" => 9, "x" => 7, "y" => 30, "remaining" => 800}
  @home %{"id" => 4, "x" => 2, "y" => 7, "remaining" => 900}
  # A Guard Tower of ours, and where it shelters from (7, 7)'s side.
  @tower building(5, "GuardTower", 12, 12)
  @by_tower {11, 11}

  defp see(units, deposits, tick, memory \\ nil),
    do: Brain.see(View.new(state(units: units, deposits: deposits, tick: tick)), memory)

  defp decide(unit, others, opts, strategy \\ @gather) do
    state = state(Keyword.merge([units: [unit | others]], opts))
    elem(UnitBrain.decide(unit["id"], View.new(state), strategy), 0)
  end

  describe "remembering ore" do
    test "a deposit a scout saw stays known once it is out of sight" do
      {_, memory} = see([unit(300, "Scout", 7, 26)], [@south], 100)
      # The scout has moved on: the server doesn't send the deposit any more.
      {v, memory} = see([unit(300, "Scout", 7, 12)], [], 110, memory)

      assert [%{"id" => 9, "seen" => 100}] = v.deposits
      assert View.deposits_in_sight(v) == []
      assert Map.has_key?(memory.ore, 9)
    end

    test "one we should see where it was and don't is mined out: forgotten" do
      {_, memory} = see([unit(300, "Scout", 7, 26)], [@south], 100)
      {v, memory} = see([unit(300, "Scout", 7, 29)], [], 120, memory)
      assert v.deposits == [] and memory.ore == %{}
    end

    test "one the server says is gone (mined out in the fog) is forgotten, and workers move on" do
      far = %{"id" => 10, "x" => 7, "y" => 34, "remaining" => 800}
      {_, memory} = see([unit(300, "Scout", 7, 30)], [@south, far], 100)
      # Out of sight now; a Gather on deposit 10 came back RESOURCE_NOT_FOUND.
      memory = Brain.forget_ore(memory, [10])
      {v, _} = see([unit(300, "Scout", 7, 12)], [], 110, memory)
      assert [%{"id" => 9}] = v.deposits

      worker = unit(1, "Worker", 7, 20)
      assert {%{"type" => "Gather", "targetId" => 9}, _} = UnitBrain.decide(1, %{v | my_units: [worker]}, @gather)
    end

    test "deposits in sight are the server's, not doubled" do
      {_, memory} = see([unit(300, "Scout", 7, 26)], [@south], 100)
      {v, _} = see([unit(300, "Scout", 7, 26)], [@south], 101, memory)
      assert v.deposits == [@south]
    end
  end

  describe "a worker" do
    # An enemy soldier sits on the ore by our Command Center (unsafe), too far to come at the worker.
    @squatter unit(900, "Soldier", 1, 3, owner: 1)
    @remembered %{"id" => 9, "x" => 20, "y" => 25, "remaining" => 800, "seen" => 50}

    test "with the ore by our drop-offs unsafe, goes to safe ore farther away we remember" do
      worker = unit(1, "Worker", 8, 8)
      assert %{"type" => "Gather", "targetId" => 9} = decide(worker, [@squatter], deposits: [@home, @remembered])
    end

    test "never to far ore on the enemy's side" do
      theirs = %{@remembered | "x" => 45, "y" => 45}
      assert decide(unit(1, "Worker", 8, 8), [@squatter], deposits: [@home, theirs]) != %{"type" => "Gather", "unitIds" => [1], "targetId" => 9}
    end

    test "with no safe ore at all, waits by our closest tower" do
      assert %{"type" => "Move", "x" => 11, "y" => 11} =
               decide(unit(1, "Worker", 8, 8), [@squatter], deposits: [@home], buildings: [@tower])
    end

    test "already by the tower, it stays" do
      assert :no_change = decide(unit(1, "Worker", 11, 10), [@squatter], deposits: [@home], buildings: [@tower])
    end

    test "out of the towers' reach, runs to a tower when a stronger raid comes at it" do
      miner = unit(1, "Worker", 20, 7, activity: "Gathering", target_id: 8)
      ore = %{"id" => 8, "x" => 19, "y" => 7, "remaining" => 500}
      raid = for i <- 1..3, do: unit(900 + i, "Soldier", 26, 7, owner: 1)
      {x, y} = @by_tower
      assert %{"type" => "Move", "x" => ^x, "y" => ^y} = decide(miner, raid, deposits: [ore], buildings: [@tower])
    end

    test "with our fighters stronger there, keeps mining" do
      miner = unit(1, "Worker", 20, 7, activity: "Gathering", target_id: 8)
      ore = %{"id" => 8, "x" => 19, "y" => 7, "remaining" => 500}
      ours = for i <- 1..5, do: unit(200 + i, "Soldier", 21, 8)
      assert :no_change = decide(miner, [unit(901, "Soldier", 26, 7, owner: 1) | ours], deposits: [ore], buildings: [@tower])
    end

    test "home falling back, it runs even from a raid it might match" do
      miner = unit(1, "Worker", 20, 7, activity: "Gathering", target_id: 8)
      ore = %{"id" => 8, "x" => 19, "y" => 7, "remaining" => 500}
      others = [unit(901, "Soldier", 26, 7, owner: 1), unit(201, "Soldier", 21, 8)]
      strategy = Map.put(@gather, :fall_back, true)
      assert %{"type" => "Move"} = decide(miner, others, [deposits: [ore], buildings: [@tower]], strategy)
    end
  end

  describe "ore kept for workers" do
    test "once a Barracks is up, 100 ore stays back from the army" do
      {_, commands, _} = plan(units: workers(20), buildings: [building(2, "Barracks", 11, 7)], ore: 150)
      refute Enum.any?(commands, &(&1["type"] == "Produce" and &1["unitType"] in ["Soldier", "Archer"]))

      {_, commands, _} = plan(units: workers(20), buildings: [building(2, "Barracks", 11, 7)], ore: 200)
      assert Enum.any?(commands, &(&1["unitType"] == "Soldier"))
    end

    test "down to a few workers, workers come first, out of the reserve" do
      {_, commands, _} = plan(units: workers(2), buildings: [building(2, "Barracks", 11, 7)], ore: 100, tick: 600)
      assert [%{"type" => "Produce", "unitType" => "Worker"} | _] = commands
      refute Enum.any?(commands, &(&1["unitType"] == "Soldier"))
    end

    test "not in the opening: the first Barracks gets the ore" do
      {_, commands, _} = plan(units: workers(7), ore: 150)
      assert [%{"buildingType" => "Barracks"}] = commands
    end
  end

  describe "falling back to the towers" do
    # Workers mining east of the base, out of the tower's reach, and a raid on them.
    defp miners, do: for(i <- 1..4, do: unit(100 + i, "Worker", 25, 7, activity: "Gathering"))
    defp raid(n), do: for(i <- 1..n, do: unit(900 + i, "Soldier", 27, 7, owner: 1))
    defp home(n, x \\ 10, y \\ 10), do: for(i <- 1..n, do: unit(200 + i, "Soldier", x, y))

    test "when the raid out of the towers' reach is stronger than home" do
      assert Roles.fall_back?(View.new(state(units: miners() ++ raid(5) ++ home(2), buildings: [@tower])), nil)
      refute Roles.fall_back?(View.new(state(units: miners() ++ raid(2) ++ home(8, 24, 8), buildings: [@tower])), nil)
    end

    test "not for one raider just because home's fighters are back at the rally point" do
      # One soldier by the workers, 15+ tiles from home's eight: all of home can meet it.
      refute Roles.fall_back?(View.new(state(units: miners() ++ raid(1) ++ home(8), buildings: [@tower])), nil)
    end

    test "not for raiders our towers reach: there the towers fight with us" do
      tower = building(5, "GuardTower", 24, 9)
      refute Roles.fall_back?(View.new(state(units: miners() ++ raid(3) ++ home(2), buildings: [tower])), nil)
    end

    test "an attacker goes to the tower by the workers, not into the raid" do
      # Eight at home: the oldest (201) is an attacker, the rest guards.
      units = miners() ++ raid(8) ++ home(8, 5, 5)
      strategy = @gather |> Map.put(:fall_back, true) |> Map.put(:help, {27, 7})
      v = View.new(state(units: units, buildings: [@tower]))
      {x, y} = @by_tower
      assert {%{"type" => "Attack", "x" => ^x, "y" => ^y}, _} = UnitBrain.decide(201, v, strategy)

      # Holding, it goes to help where the leader says.
      assert {%{"type" => "Attack", "x" => 27, "y" => 7}, _} = UnitBrain.decide(201, v, Map.put(@gather, :help, {27, 7}))
    end

    test "a defender out there doesn't take on the raid, only fights back" do
      ours = unit(201, "Soldier", 22, 7)
      v = View.new(state(units: [ours | miners() ++ raid(5)], buildings: [@tower]))
      assert Roles.target(v, nil, ours) == nil

      # One within reach of it: it hits back.
      close = unit(950, "Soldier", 23, 7, owner: 1)
      v = View.new(state(units: [ours, close | miners() ++ raid(5)], buildings: [@tower]))
      assert %{"id" => 950} = Roles.target(v, nil, ours)
    end

    test "the brain says so, once, in the decision log" do
      opts = [units: miners() ++ raid(5) ++ home(2), buildings: [@tower]]
      {strategy, _, memory} = plan(opts)
      assert strategy.fall_back
      assert Enum.any?(strategy.why, &match?({:fall_back, _}, &1))

      {strategy, _, _} = plan(opts, memory)
      refute Enum.any?(strategy.why, &match?({:fall_back, _}, &1))
    end
  end

  describe "the survey for ore" do
    test "with a scout, the leader sends it round our side, spot by spot" do
      scout = unit(300, "Scout", 7, 7)
      {strategy, _, memory} = plan(units: [scout | workers(5)], tick: 200)
      assert {x, y} = strategy.survey
      assert View.dist({x, y}, {7, 7}) < View.dist({x, y}, {56, 56})
      assert Enum.any?(strategy.why, &match?({:survey, _}, &1))

      # There: that spot is done, and it goes on to the next.
      {strategy, _, memory} = plan([units: [%{scout | "x" => x, "y" => y} | workers(5)], tick: 210], memory)
      assert {x, y} in memory.surveyed
      assert strategy.survey != {x, y}
    end

    test "gives up on a spot it can't reach" do
      scout = unit(300, "Scout", 7, 7)
      {%{survey: spot}, _, memory} = plan(units: [scout | workers(5)], tick: 200)
      {%{survey: next}, _, memory} = plan([units: [scout | workers(5)], tick: 300], memory)
      assert spot in memory.surveyed and next != spot
    end

    test "nothing to survey without a scout" do
      assert {%{survey: nil}, _, _} = plan(units: workers(5), tick: 200)
    end

    test "the first scout goes; the other keeps its post" do
      strategy = Map.put(@gather, :survey, {20, 20})
      v = View.new(state(units: [unit(300, "Scout", 7, 7), unit(301, "Scout", 7, 7)]))
      assert {%{"type" => "Move", "x" => 20, "y" => 20}, _} = UnitBrain.decide(300, v, strategy)
      assert {%{"type" => "Move"} = post, _} = UnitBrain.decide(301, v, strategy)
      refute {post["x"], post["y"]} == {20, 20}
    end
  end

  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())
end
