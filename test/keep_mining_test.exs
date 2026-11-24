defmodule Swarm.KeepMiningTest do
  @moduledoc """
  Mining past the home field: ore off our side but clear of every enemy base is taken, a depot
  goes up with home short even without an army, the workforce grows with the ore there is, and a
  spot where building keeps failing is left alone for a while.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  # Us at (7, 7), the enemy at (56, 56), on an open 64x64 map.
  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}

  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  # A six-player game: a big one.
  defp big(state) do
    more = for {{x, y}, slot} <- Enum.with_index([{56, 7}, {7, 56}, {32, 60}, {60, 32}], 2),
               do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}}

    Map.update!(state, "players", &(&1 ++ more))
  end

  defp big_plan(opts, memory),
    do: Brain.plan(View.new(big(state(opts))), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  defp ore(id, x, y, remaining \\ 900), do: %{"id" => id, "x" => x, "y" => y, "remaining" => remaining}
  defp depots(commands), do: for(%{"type" => "Build", "buildingType" => "ResourceDepot"} = c <- commands, do: c)

  describe "ore off our side" do
    test "clear of every enemy base, it is free to take; by one, it isn't" do
      v = View.new(state())
      # (30, 35) is 28 from us and 26 from the enemy: not on our side, but nobody's base.
      refute View.ours?(v, {30, 35})
      assert View.claimable?(v, {30, 35})
      refute View.claimable?(v, {45, 45})

      # Nor by an enemy building we know of, far from their start as it may be.
      v = View.new(state(buildings: [building(70, "GuardTower", 32, 40, 1)]))
      refute View.claimable?(v, {30, 35})
    end

    test "an idle worker with no ore on our side walks to it, remembered or not" do
      far = Map.put(ore(9, 30, 35), "seen", 50)
      state = state(units: [unit(1, "Worker", 8, 8)], deposits: [far])
      assert {%{"type" => "Gather", "targetId" => 9}, _} = UnitBrain.decide(1, View.new(state), @gather)
    end

    test "ore on our side comes first" do
      state = state(units: [unit(1, "Worker", 8, 8)], deposits: [ore(9, 30, 35), ore(10, 25, 8)])
      assert {%{"type" => "Gather", "targetId" => 10}, _} = UnitBrain.decide(1, View.new(state), @gather)
    end

    test "home short of ore: the depot goes by it when there is none on our side" do
      field = [ore(30, 30, 35), ore(31, 31, 35), ore(32, 30, 36)]
      {_, _, memory} = plan(units: workers(5), deposits: field, ore: 100, tick: 100)
      {_, commands, _} = plan([units: workers(5), deposits: field, ore: 100, tick: 130], memory)
      assert [%{"x" => x, "y" => y}] = depots(commands)
      assert View.dist({x, y}, {30, 35}) in 2..3
    end

    test "not by a field with next to nothing left" do
      {_, _, memory} = plan(units: workers(5), deposits: [ore(30, 30, 35, 200)], ore: 100, tick: 100)
      {_, commands, _} = plan([units: workers(5), deposits: [ore(30, 30, 35, 200)], ore: 100, tick: 130], memory)
      assert depots(commands) == []
    end
  end

  describe "a big game with home out of ore" do
    test "the depot doesn't wait for fifteen fighters" do
      field = [ore(30, 20, 20), ore(31, 21, 20), ore(32, 20, 21)]
      home = [building(3, "ResourceDepot", 4, 9)]
      {_, commands, memory} = big_plan([units: workers(5), buildings: home, deposits: field, ore: 100, tick: 100], Brain.new_memory())
      assert depots(commands) == []

      {_, commands, _} = big_plan([units: workers(5), buildings: home, deposits: field, ore: 100, tick: 130], memory)
      assert [_] = depots(commands)
    end
  end

  describe "how many workers" do
    defp trains_worker?(commands), do: Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Worker"}, &1))
    # Nine piles of 1000 by the Command Center, like a real start.
    @home for i <- 0..8, do: %{"id" => 40 + i, "x" => 2, "y" => 3 + i, "remaining" => 1000}

    test "more than twenty while there is the ore for them: one for every 150 left" do
      barracks = building(2, "Barracks", 11, 7)
      {_, commands, _} = plan(units: workers(20), buildings: [barracks], deposits: @home, ore: 2000)
      assert trains_worker?(commands)

      # 9000 ore: sixty. Never more.
      {_, commands, _} = plan(units: workers(59), buildings: [barracks], deposits: @home, ore: 2000)
      assert trains_worker?(commands)
      {_, commands, _} = plan(units: workers(60), buildings: [barracks], deposits: @home, ore: 2000)
      refute trains_worker?(commands)

      # Half of it mined: thirty.
      half = for d <- @home, do: %{d | "remaining" => 500}
      {_, commands, _} = plan(units: workers(30), buildings: [barracks], deposits: half, ore: 2000)
      refute trains_worker?(commands)
    end

    test "ore by an enemy base doesn't count" do
      theirs = for i <- 0..8, do: ore(60 + i, 50, 45 + i, 1000)
      {_, commands, _} = plan(units: workers(20), buildings: [building(2, "Barracks", 11, 7)], deposits: theirs, ore: 2000)
      refute trains_worker?(commands)
    end

    test "home is short sooner with more workers: under 150 ore each" do
      {_, _, memory} = plan(units: workers(26), deposits: Enum.take(@home, 4), ore: 0, tick: 100)
      assert memory.ore_short_since == nil

      {_, _, memory} = plan(units: workers(27), deposits: Enum.take(@home, 4), ore: 0, tick: 100)
      assert memory.ore_short_since == 100
    end
  end

  describe "a spot where building keeps failing" do
    @field [%{"id" => 30, "x" => 30, "y" => 8, "remaining" => 900}, %{"id" => 31, "x" => 31, "y" => 8, "remaining" => 900}]
    @other [%{"id" => 35, "x" => 8, "y" => 30, "remaining" => 900}, %{"id" => 36, "x" => 9, "y" => 30, "remaining" => 900}]

    test "a depot destroyed there twice: the next one goes by another field" do
      opts = [units: workers(5), deposits: @field ++ @other, ore: 100]
      {_, _, memory} = plan(opts ++ [tick: 100])
      {strategy, [%{"x" => x, "y" => y}], memory} = plan(opts ++ [tick: 130], memory)
      assert View.dist({x, y}, {30, 8}) <= 3
      refute Enum.any?(strategy.why, &match?({:site_blocked, _}, &1))

      # It goes up and is destroyed, and again.
      site = %{building(50, "ResourceDepot", x, y) | "completed" => false}
      builder = fn id -> [unit(150, "Worker", x + 1, y, activity: "Building", target_id: id) | workers(5)] end
      {_, _, memory} = plan(Keyword.merge(opts, tick: 135, buildings: [site], units: builder.(50)), memory)
      {_, [%{"x" => ^x, "y" => ^y}], memory} = plan(opts ++ [tick: 140], memory)
      {_, _, memory} = plan(Keyword.merge(opts, tick: 145, buildings: [%{site | "id" => 51}], units: builder.(51)), memory)

      {strategy, commands, memory} = plan(opts ++ [tick: 150], memory)
      assert [{:site_blocked, _}] = Enum.filter(strategy.why, &match?({:site_blocked, _}, &1))
      assert [%{"x" => x2, "y" => y2}] = depots(commands)
      assert View.dist({x2, y2}, {8, 30}) <= 3

      # After 300 ticks it may be tried again.
      {_, _, memory} = plan([units: workers(5), deposits: @field, ore: 0, tick: 460], %{memory | pending: nil})
      assert memory.strikes == %{}
    end

    test "an abandoned site there stops getting workers after three" do
      site = %{building(50, "CommandCenter", 40, 8) | "completed" => false}
      opts = [units: workers(5), buildings: [site], ore: 0]
      sends = fn commands -> for %{"type" => "Build", "buildingType" => "CommandCenter"} = c <- commands, do: c end

      memory =
        Enum.reduce([100, 111, 122], Brain.new_memory(), fn tick, memory ->
          {_, commands, memory} = plan(opts ++ [tick: tick], memory)
          assert [_] = sends.(commands)
          memory
        end)

      {strategy, commands, _} = plan(opts ++ [tick: 133], memory)
      assert sends.(commands) == []
      assert [{:site_blocked, text}] = Enum.filter(strategy.why, &match?({:site_blocked, _}, &1))
      assert text =~ "(40,8)"
    end

    test "not at home: a raid on the base is no reason to build elsewhere" do
      site = %{building(50, "Barracks", 11, 7) | "completed" => false}
      opts = [units: workers(5), buildings: [site], ore: 0]

      memory =
        Enum.reduce([100, 111, 122], Brain.new_memory(), fn tick, memory ->
          elem(plan(opts ++ [tick: tick], memory), 2)
        end)

      assert memory.strikes == %{}
      {_, commands, _} = plan(opts ++ [tick: 133], memory)
      assert [%{"type" => "Build", "buildingType" => "Barracks"}] = commands
    end
  end
end
