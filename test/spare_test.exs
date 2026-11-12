defmodule Swarm.SpareTest do
  @moduledoc """
  The last opponent's last Command Center stays up: killing it ends the match and our score with
  it. The wave takes everything else, camps out of its reach and farms until the end, unless their
  army comes back (then it comes down after all).
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  # Player 1's Command Center at (56, 56); we are at (7, 7). The army camps six tiles out of it
  # toward us, Trebuchets nine.
  @their_cc building(900, "CommandCenter", 56, 56, 1)
  @camp {50, 50}
  @siege_camp {47, 47}

  defp players(survival) do
    [
      %{"slot" => 0, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 7}, "score" => %{"survival" => 5000}},
      %{"slot" => 1, "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 56}, "score" => %{"survival" => survival}}
    ]
  end

  defp view(opts, survival, extra_players \\ []) do
    state(opts) |> Map.put("players", players(survival) ++ extra_players) |> View.new()
  end

  defp plan(v, memory \\ Brain.new_memory()), do: Brain.plan(v, looked(memory, 1, v.tick), terrain())

  describe "the brain" do
    test "spares the last opponent's only Command Center and camps by it" do
      # Their Command Center (400) and two workers we see (100) are all their survival score.
      workers = for i <- 1..2, do: unit(950 + i, "Worker", 57, 57, owner: 1)
      v = view([units: soldiers(5) ++ workers, buildings: [@their_cc]], 500)

      assert {%{spare: spare, target: @camp, why: why}, _, memory} = plan(v)
      assert %{id: 900, pos: {56, 56}, goal: @camp, camp: @camp, siege_camp: @siege_camp} = spare
      assert {:spare, "player 1's last Command Center at (56,56) stays up: we farm until the end"} in why

      # Logged once.
      assert {%{spare: %{id: 900}, why: why}, _, _} = plan(v, memory)
      refute Enum.any?(why, &(elem(&1, 0) == :spare))
    end

    test "goes for their other buildings first" do
      barracks = building(901, "Barracks", 54, 54, 1)
      v = view([units: soldiers(5), buildings: [@their_cc, barracks]], 550)
      assert {%{spare: %{goal: {54, 54}, camp: @camp}, target: {54, 54}}, _, _} = plan(v)
    end

    test "not when what they have alive could be another Command Center" do
      v = view([units: soldiers(5), buildings: [@their_cc]], 800)
      assert {%{spare: nil}, _, _} = plan(v)
    end

    test "not while another opponent is still in" do
      third = %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 7}, "score" => %{"survival" => 900}}
      v = view([units: soldiers(5), buildings: [@their_cc]], 400, [third])
      assert {%{spare: nil}, _, _} = plan(v)
    end

    test "it comes down in the last 30 ticks" do
      v = view([units: soldiers(5), buildings: [@their_cc], tick: 1769], 400)
      assert {%{spare: %{id: 900}}, _, _} = plan(v)

      v = view([units: soldiers(5), buildings: [@their_cc], tick: 1775], 400)
      assert {%{spare: nil, target: {56, 56}, why: why}, _, %{spare_lifted: true}} = plan(v)
      assert {:spare_lifted, "25 ticks left: player 1's last Command Center comes down"} in why
    end

    test "their side of the map is ours to mine: a depot by their ore once home runs short" do
      # Home ore nearly gone; known ore at (44, 44), on their side (12 from their start, 37 from ours).
      deposits = [%{"id" => 4, "x" => 2, "y" => 7, "remaining" => 100}, %{"id" => 60, "x" => 44, "y" => 44, "remaining" => 900}]
      opts = [units: workers(10), buildings: [@their_cc], deposits: deposits, ore: 200, tick: 100]
      memory = %{Brain.new_memory() | ore_short_since: 50}
      depot? = fn {_, commands, _} -> Enum.find(commands, &match?(%{"type" => "Build", "buildingType" => "ResourceDepot"}, &1)) end

      assert %{"x" => x, "y" => y} = depot?.(plan(view(opts, 400), memory))
      assert View.dist({x, y}, {44, 44}) <= 3

      # Not spared (they could have more): their side stays theirs.
      refute depot?.(plan(view(opts, 900), memory))
    end

    test "short of ore at home, the scout looks over the rest of the map, eliminated players' starts first" do
      fallen = %{"slot" => 2, "eliminated" => true, "startPosition" => %{"x" => 40, "y" => 7}, "score" => %{"survival" => 0}}
      scout = unit(300, "Scout", 7, 7)
      v = view([units: [scout | workers(5)], tick: 200], 900, [fallen])

      assert {%{survey: spot}, _, _} = plan(v, %{Brain.new_memory() | ore_short_since: 100})
      assert View.dist(spot, {40, 7}) <= 3

      # With ore at home, only the rings around our base.
      assert {%{survey: spot}, _, _} = plan(v)
      assert View.dist(spot, {7, 7}) <= 20
    end

    test "their army back, stronger than the wave can take on: it comes down after all, for good" do
      wave = for i <- 1..10, do: unit(200 + i, "Soldier", 50, 50)
      army = Map.new(1..12, &{960 + &1, %{"id" => 960 + &1, "type" => "Soldier", "owner" => 1, "hp" => 110, "x" => 56, "y" => 58, "seen" => 100}})
      memory = %{Brain.new_memory() | wave: %{id: 1, members: Enum.to_list(201..210), released: true, owner: 1, at: 50}, next_wave: 2, enemies: army}
      v = view([units: wave, buildings: [@their_cc]], 400)

      assert {%{spare: nil, why: why}, _, memory} = plan(v, memory)
      assert Enum.any?(why, &match?({:spare_lifted, "player 1's army is back" <> _}, &1))
      assert memory.spare_lifted

      # Their army gone again: still not spared.
      assert {%{spare: nil}, _, _} = plan(v, %{memory | enemies: %{}})
    end
  end

  describe "the units" do
    @spare %{id: 900, pos: {56, 56}, goal: @camp, camp: @camp, siege_camp: @siege_camp}
    @strategy %{mode: :attack, target: @camp, rally: {10, 10}, post: {9, 9}, threat: nil, wave: %{id: 1, members: [2]}, spare: @spare}

    defp decide(unit, strategy, others \\ []) do
      v = View.new(state(units: [unit | others], buildings: [Map.put(@their_cc, "hp", 20)]))
      elem(UnitBrain.decide(unit["id"], v, strategy), 0)
    end

    test "a wave member by it doesn't finish it off, and walks (no attack-move) to the camp" do
      soldier = unit(2, "Soldier", 55, 55)
      assert %{"type" => "Attack", "targetId" => 900} = decide(soldier, %{@strategy | spare: nil})
      assert %{"type" => "Move", "x" => 50, "y" => 50} = decide(soldier, @strategy)
    end

    test "far from it, the wave attack-moves to the goal" do
      assert %{"type" => "Attack", "x" => 50, "y" => 50} = decide(unit(2, "Soldier", 30, 30), @strategy)
    end

    test "it kills what comes out of it" do
      worker = unit(950, "Worker", 57, 56, owner: 1)
      assert %{"type" => "Attack", "targetId" => 950} = decide(unit(2, "Soldier", 52, 52), @strategy, [worker])
    end

    test "a Trebuchet waits farther out, beyond its own reach of it" do
      assert %{"type" => "Attack", "x" => 47, "y" => 47} = decide(unit(2, "Trebuchet", 30, 30), @strategy)
    end
  end
end
