defmodule Swarm.TurnaroundTest do
  @moduledoc """
  Fixes from the first game against the Formics: a Command Center away from an opponent's start
  isn't their last while the start may still have one; the serum is only taken when it turns the
  fight, and then the Soldiers go in; and more Barracks go up while the ore piles up.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  describe "the last opponent's Command Center" do
    # The enemy started at (56, 56).
    test "one in the middle of the map isn't it: their start may still have one" do
      middle = building(900, "CommandCenter", 33, 33, 1)
      {strategy, _, memory} = plan(units: soldiers(5), buildings: [middle])
      assert strategy.spare == nil and memory.kill == nil
    end

    test "it is, once we have seen their start with none on it" do
      middle = building(900, "CommandCenter", 33, 33, 1)
      # A scout stands by their start and sees no Command Center there.
      {_, _, memory} = plan(units: [unit(300, "Scout", 54, 54)], buildings: [middle])
      assert memory.empty_starts == [{56, 56}]

      {strategy, _, _} = plan([units: soldiers(5), buildings: [middle]], memory)
      assert %{id: 900} = strategy.spare
    end

    test "the one they started with is, as before" do
      {strategy, _, _} = plan(units: soldiers(5), buildings: [building(900, "CommandCenter", 56, 56, 1)])
      assert %{id: 900} = strategy.spare
    end
  end

  describe "the serum" do
    defp raiders(n), do: for(i <- 1..n, do: unit(900 + i, "Soldier", 9, 9, owner: 1))

    test "taken when doubling our Soldiers turns the fight; not against a raid it can't beat" do
      # Ten Soldiers at home: with the serum they are worth twenty.
      assert {%{serum: :take, serum_on: true}, _, _} = plan(units: soldiers(10) ++ raiders(16))
      assert {%{serum: nil, serum_on: false}, _, _} = plan(units: soldiers(10) ++ raiders(30))
    end

    test "while it lasts, a Soldier at home goes in on a raid the estimate says to stay out of" do
      # Eight raiders in the base, four tiles from our four Soldiers at (10, 10).
      units = soldiers(4) ++ for(i <- 1..8, do: unit(900 + i, "Soldier", 14, 14, owner: 1))
      strategy = %{mode: :defend, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
      v = View.new(state(units: units))

      {before, _} = UnitBrain.decide(201, v, strategy)
      refute match?(%{"type" => "Attack"}, before)
      assert {%{"type" => "Attack"}, _} = UnitBrain.decide(201, v, Map.put(strategy, :serum_on, true))
    end
  end

  describe "more Barracks" do
    @built [
      building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 12, 12),
      building(6, "TechLab", 7, 12), building(7, "Barracks", 12, 3), building(8, "GuardTower", 14, 9),
      building(9, "CommandCenter", 40, 4), building(20, "Barracks", 3, 3), building(21, "Barracks", 3, 11),
      building(22, "GuardTower", 10, 13), building(23, "GuardTower", 13, 6), building(24, "GuardTower", 4, 13)
    ]
    defp busy(buildings), do: for(b <- buildings, do: if(b["type"] == "Barracks", do: %{b | "production" => [%{"unitType" => "Soldier"}, %{"unitType" => "Soldier"}]}, else: b))
    defp builds(commands), do: for(%{"type" => "Build", "buildingType" => t} <- commands, do: t)

    test "a fifth when we are rich and all four are busy" do
      {_, commands, _} = plan(units: workers(20) ++ soldiers(12), buildings: busy(@built), ore: 1500)
      assert builds(commands) == ["Barracks"]
    end

    test "not while one has room in its queue, and not without the ore" do
      {_, commands, _} = plan(units: workers(20) ++ soldiers(12), buildings: @built, ore: 1500)
      assert builds(commands) == []

      {_, commands, _} = plan(units: workers(20) ++ soldiers(12), buildings: busy(@built), ore: 300)
      assert builds(commands) == []
    end
  end
end
