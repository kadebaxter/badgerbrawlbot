defmodule Swarm.InsideTest do
  @moduledoc "A raid that would beat us is stayed out of only while it is outside our base; inside it, everyone fights."
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

    test "inside our base with the fight lost, a worker by them hits back, and keeps at it" do
      v = view({14, 10}, {12, 12}, [@worker])
      assert {%{"type" => "Attack", "unitIds" => [101], "targetId" => id}, _} = UnitBrain.decide(101, v, @defend)
      assert id in 901..912
      v = view({14, 10}, {12, 12}, [%{@worker | "activity" => "Attacking"}])
      assert {:no_change, _} = UnitBrain.decide(101, v, @defend)
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
