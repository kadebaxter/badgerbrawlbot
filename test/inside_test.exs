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
end
