defmodule Swarm.InsideTest do
  @moduledoc "A raid that would beat us is stayed out of only while it is outside our base; inside it the fighters fight (or go to our next base, when there is one behind it), and workers run."
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Roles, UnitBrain, View}

  @defend %{mode: :defend, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}

  # Four of ours at home, a tower of ours at `tower`; twelve Soldiers of theirs at `at`.
  defp view(at, tower, more \\ []) do
    {x, y} = at
    raid = for i <- 1..12, do: unit(900 + i, "Soldier", x, y, owner: 1)
    ours = for i <- 1..4, do: unit(200 + i, "Soldier", 9, 9)
    View.new(state(units: ours ++ raid ++ more, buildings: [building(50, "GuardTower", elem(tower, 0), elem(tower, 1))]))
  end

  test "outside our towers' reach, a raid that would beat us is stayed out of" do
    v = view({14, 10}, {4, 4})
    g = Roles.group_for(v, nil, hd(View.units_of(v, "Soldier")))
    assert Roles.away?(g) and not Roles.inside?(v, g)
    assert {cmd, _} = UnitBrain.decide(201, v, @defend)
    refute match?(%{"type" => "Attack"}, cmd)
  end

  test "inside our towers' reach, everyone fights it, whatever the estimate" do
    v = view({14, 10}, {12, 12})
    g = Roles.group_for(v, nil, hd(View.units_of(v, "Soldier")))
    assert Roles.away?(g) and Roles.inside?(v, g)
    assert {%{"type" => "Attack"}, _} = UnitBrain.decide(201, v, @defend)
  end

  describe "workers" do
    @worker unit(101, "Worker", 11, 10, activity: "Gathering")

    test "inside our base with the fight lost, a worker by them runs; it never hits back" do
      v = view({14, 10}, {12, 12}, [@worker])
      assert {%{"type" => "Move", "unitIds" => [101]}, _} = UnitBrain.decide(101, v, @defend)
      v = view({14, 10}, {12, 12}, [%{@worker | "activity" => "Attacking"}])
      assert {%{"type" => "Move", "unitIds" => [101]}, _} = UnitBrain.decide(101, v, @defend)
    end

    test "with them outside the base, it runs for cover as ever" do
      v = view({14, 10}, {4, 4}, [@worker])
      assert {%{"type" => "Move"}, _} = UnitBrain.decide(101, v, @defend)
    end
  end

  describe "with three or four players, ore is mined under cover" do
    # A field by a depot of ours with no tower, and one by a depot with a tower over it.
    @bare %{"id" => 30, "x" => 22, "y" => 20, "remaining" => 1000}
    @covered %{"id" => 40, "x" => 30, "y" => 8, "remaining" => 1000}
    @miner unit(101, "Worker", 21, 20, activity: "Gathering", target_id: 30)

    defp field_state(players) do
      s = state(units: [@miner], deposits: [@bare, @covered],
                buildings: [building(60, "ResourceDepot", 20, 20), building(61, "ResourceDepot", 30, 10), building(62, "GuardTower", 31, 9)])
      third = %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56}}
      View.new(if(players == 3, do: %{s | "players" => s["players"] ++ [third]}, else: s))
    end

    test "a miner at a field no tower of ours reaches goes to one under cover" do
      assert {%{"type" => "Gather", "targetId" => 40}, _} = UnitBrain.decide(101, field_state(3), @defend)
    end

    test "with one opponent it mines on where it is" do
      assert {:no_change, _} = UnitBrain.decide(101, field_state(2), @defend)
    end
  end

  describe "a base of ours lost, with another behind it" do
    # Our base in the middle at (28, 40) with a tower, twelve of theirs in the tower's reach; four
    # of ours and a miner there; another base of ours at (20, 20); home at (7, 7).
    defp lost(players, at \\ {31, 40}, more \\ []) do
      {x, y} = at
      raid = for i <- 1..12, do: unit(900 + i, "Soldier", x, y, owner: 1)
      ours = for i <- 1..4, do: unit(200 + i, "Soldier", 28, 38)
      miner = unit(101, "Worker", 26, 41, activity: "Gathering")
      s = state(units: ours ++ raid ++ [miner] ++ more,
                buildings: [building(60, "CommandCenter", 28, 40), building(61, "GuardTower", 29, 39), building(62, "CommandCenter", 20, 20)])
      third = %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56}}
      %{View.new(if(players == 3, do: %{s | "players" => s["players"] ++ [third]}, else: s)) | bases: [{28, 40}, {20, 20}]}
    end

    test "the fighters there go to the nearest other base, and so do the workers" do
      v = lost(3)
      g = Roles.group_for(v, nil, hd(View.units_of(v, "Soldier")))
      assert Roles.away?(g) and Roles.inside?(v, g)
      assert Roles.retreat(v, g) == {20, 20}
      assert {%{"type" => "Move", "x" => 20, "y" => 20}, _} = UnitBrain.decide(201, v, @defend)
      assert {%{"type" => "Move", "x" => 20, "y" => 20}, _} = UnitBrain.decide(101, v, @defend)
    end

    test "with one opponent just the same" do
      v = lost(2)
      assert Roles.retreat(v, Roles.group_for(v, nil, hd(View.units_of(v, "Soldier")))) == {20, 20}
      assert {%{"type" => "Move", "x" => 20, "y" => 20}, _} = UnitBrain.decide(201, v, @defend)
      assert {%{"type" => "Move", "x" => 20, "y" => 20}, _} = UnitBrain.decide(101, v, @defend)
    end

    test "nobody leaves the main base: a raid at it is fought there" do
      raid = for i <- 1..12, do: unit(900 + i, "Soldier", 10, 8, owner: 1)
      ours = for i <- 1..4, do: unit(200 + i, "Soldier", 8, 9)
      s = state(units: ours ++ raid, buildings: [building(62, "CommandCenter", 28, 28)])
      third = %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56}}
      v = %{View.new(%{s | "players" => s["players"] ++ [third]}) | bases: [{28, 28}]}
      g = Roles.group_for(v, nil, hd(ours))
      assert Roles.away?(g) and Roles.inside?(v, g)
      assert Roles.retreat(v, g) == nil
      assert {%{"type" => "Attack"}, _} = UnitBrain.decide(201, v, @defend)
    end
  end

  describe "workers leave a base ahead of a big raid, win or lose" do
    test "twelve of theirs twelve tiles from the base: its workers go to the base they are far from" do
      v = lost(2, {40, 40})
      assert [{_spots, {20, 20}}] = Roles.evacuations(v, nil)
      assert {%{"type" => "Move", "unitIds" => [101], "x" => 20, "y" => 20}, _} = UnitBrain.decide(101, v, @defend)
    end

    test "with forty of ours there to win it, just the same" do
      more = for i <- 1..40, do: unit(500 + i, "Soldier", 28, 38)
      v = lost(2, {40, 40}, more)
      assert {%{"type" => "Move", "x" => 20, "y" => 20}, _} = UnitBrain.decide(101, v, @defend)
    end

    test "not for a few raiders, and not from the main base" do
      few = lost(2, {40, 40})
      few = %{few | enemy_units: Enum.take(few.enemy_units, 5)}
      assert Roles.evacuations(few, nil) == []

      raid = for i <- 1..12, do: unit(900 + i, "Soldier", 18, 8, owner: 1)
      v = %{View.new(state(units: raid, buildings: [building(62, "CommandCenter", 40, 40)])) | bases: [{40, 40}]}
      assert Roles.evacuations(v, nil) == []
    end
  end

  describe "falling back from a fight we'd lose" do
    test "to our tower nearest us, one off to the side included, not the home one far behind" do
      # Ours at (48, 39) with theirs six tiles north; a base tower of ours six tiles west, as far from
      # them as from us, and the home tower fourteen tiles south.
      raid = for i <- 1..12, do: unit(900 + i, "Soldier", 48, 33, owner: 1)
      ours = for i <- 1..4, do: unit(200 + i, "Soldier", 48, 39)
      v = View.new(state(units: ours ++ raid, buildings: [building(50, "GuardTower", 42, 39), building(51, "GuardTower", 48, 53)]))
      g = Roles.group_for(v, nil, hd(ours))
      assert Roles.away?(g)
      assert View.dist(g.fallback, {42, 39}) <= 1
    end
  end
end
