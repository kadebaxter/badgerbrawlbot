defmodule Swarm.RolesTest do
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Roles, View}

  defp view(units, buildings \\ []), do: View.new(state(units: units, buildings: buildings))

  test "the newest fighters guard: at least three, or a quarter of the army" do
    assert Roles.guards(view(soldiers(8)), nil) == MapSet.new([206, 207, 208])
    assert MapSet.size(Roles.guards(view(soldiers(20)), nil)) == 5
  end

  test "scouts are neither guards nor attackers" do
    v = view([unit(300, "Scout", 10, 10) | soldiers(4)])
    assert Roles.role(v, nil, 300) == :scout
    refute MapSet.member?(Roles.guards(v, nil), 300)
  end

  describe "outposts" do
    defp depot, do: building(50, "ResourceDepot", 30, 30)
    defp miners(n), do: for(i <- 1..n, do: unit(400 + i, "Worker", 31, 31, activity: "Gathering"))

    test "an outpost with miners gets escorts after the guards: one per 3 workers, at least 2" do
      roles = Roles.home_roles(view(soldiers(10) ++ miners(6), [depot()]), nil)
      assert Enum.map(208..210, &roles[&1]) == [:guard, :guard, :guard]
      assert roles[207] == {:escort, {30, 30}} and roles[206] == {:escort, {30, 30}}
      assert roles[205] == :attacker

      roles = Roles.home_roles(view(soldiers(10) ++ miners(7), [depot()]), nil)
      assert Enum.count(roles, &match?({_, {:escort, _}}, &1)) == 3
    end

    test "escorts already at the outpost keep the job when new units are trained" do
      at_outpost = for id <- [201, 202], do: unit(id, "Soldier", 31, 30)
      home = for i <- 3..10, do: unit(200 + i, "Soldier", 10, 10)
      roles = Roles.home_roles(view(at_outpost ++ home ++ miners(6), [depot()]), nil)
      assert roles[201] == {:escort, {30, 30}} and roles[202] == {:escort, {30, 30}}

      # A new soldier appears: nobody swaps.
      roles = Roles.home_roles(view([unit(211, "Soldier", 10, 10) | at_outpost ++ home] ++ miners(6), [depot()]), nil)
      assert roles[201] == {:escort, {30, 30}} and roles[202] == {:escort, {30, 30}}
      assert roles[211] == :guard
    end

    test "no miners there, no escorts" do
      roles = Roles.home_roles(view(soldiers(10), [depot()]), nil)
      refute Enum.any?(roles, &match?({_, {:escort, _}}, &1))
    end

    test "a depot inside the main base isn't an outpost" do
      assert Roles.outposts(view([], [building(50, "ResourceDepot", 12, 12)])) == []
    end

    test "fighters at home may fight at an outpost" do
      ours = unit(201, "Soldier", 28, 28)
      enemy = unit(900, "Soldier", 32, 31, owner: 1)
      v = view([ours, enemy], [depot()])
      assert %{"id" => 900} = Roles.target(v, nil, ours)
    end
  end

  test "enemies near our workers outside every base are a call for help" do
    miner = unit(101, "Worker", 42, 40, activity: "Gathering")
    enemy = unit(900, "Soldier", 40, 40, owner: 1)
    assert Roles.help_wanted(view([miner, enemy, unit(201, "Soldier", 10, 10)])) == [{40, 40}]

    # And a home fighter that has arrived may fight it there.
    arrived = unit(201, "Soldier", 37, 40)
    assert %{"id" => 900} = Roles.target(view([miner, enemy, arrived]), nil, arrived)
  end

  describe "Trebuchets" do
    test "are worth HP x damage per tick like everything else" do
      assert Roles.strength([unit(900, "Trebuchet", 0, 0)]) == 150 * 40 / 8
    end

    test "come before an enemy that can't hit us yet" do
      ours = unit(201, "Soldier", 20, 20)
      treb = unit(900, "Trebuchet", 24, 20, owner: 1)
      soldier = unit(901, "Soldier", 22, 20, owner: 1)
      wave = %{id: 1, members: [201]}
      assert %{"id" => 900} = Roles.target(view([ours, treb, soldier]), wave, ours)
    end

    test "home units leave the base to kill one shelling our tower, from farther away" do
      tower = building(2, "GuardTower", 15, 15)
      # 7 from the tower, 15 from the Command Center: outside the base.
      treb = unit(900, "Trebuchet", 22, 22, owner: 1)
      guard = unit(201, "Soldier", 14, 14)
      v = view([guard, treb], [tower])
      assert %{"id" => 900} = Roles.target(v, nil, guard)
      assert Roles.help_wanted(v) == [{22, 22}]
    end

    test "one far from our buildings is no call for help" do
      assert Roles.help_wanted(view([unit(900, "Trebuchet", 40, 40, owner: 1)])) == []
    end
  end

  test "wave members aren't guards or attackers" do
    v = view(soldiers(20))
    wave = %{id: 1, members: Enum.to_list(201..215)}
    assert Roles.role(v, wave, 201) == :wave
    assert Roles.role(v, wave, 220) == :guard
    assert Roles.role(v, nil, 201) == :attacker
  end

  describe "turn_back?" do
    # Five wave members, three guards at home, a threat of size 6.
    setup do
      wave = %{id: 1, members: [201, 202, 203, 204, 205]}
      guards = for i <- 1..3, do: unit(300 + i, "Soldier", 10, 10)
      strategy = %{wave: wave, threat: %{pos: {12, 9}, size: 6}, rally: {10, 10}, target: {56, 56}}
      %{guards: guards, strategy: strategy}
    end

    test "when home can't hold and the wave is still near home", %{guards: guards, strategy: s} do
      near = soldiers(5) |> Enum.map(&%{&1 | "x" => 20, "y" => 20})
      assert Roles.turn_back?(view(near ++ guards), s)
    end

    test "not when the wave is nearly at the target", %{guards: guards, strategy: s} do
      far = soldiers(5) |> Enum.map(&%{&1 | "x" => 45, "y" => 45})
      refute Roles.turn_back?(view(far ++ guards), s)
    end

    test "not when home can hold", %{guards: guards, strategy: s} do
      near = soldiers(5) |> Enum.map(&%{&1 | "x" => 20, "y" => 20})
      # Two towers are worth four fighters: 3 + 4 >= 6.
      towers = [building(2, "GuardTower", 12, 12), building(3, "GuardTower", 13, 10)]
      refute Roles.turn_back?(view(near ++ guards, towers), s)
    end
  end

  describe "who fights whom" do
    # Our soldiers in a ring around an enemy archer at (12, 12), inside the base.
    defp around(n), do: for(i <- 1..n, do: unit(200 + i, "Soldier", 11 + rem(i, 3), 11 + div(i, 3)))
    defp archer(opts \\ []), do: Map.merge(unit(900, "Archer", 12, 12, owner: 1), Map.new(opts))

    defp attackers(units, opts \\ []) do
      v = View.new(state(Keyword.merge([units: units], opts)))
      Roles.assignments(v, nil) |> Map.values() |> Enum.count(&(&1 == 900))
    end

    test "an archer gets just enough attackers to die in one volley" do
      # 60 HP, 9 damage each: 7.
      assert attackers(around(9) ++ [archer()]) == 7
      # Already down to 20 HP: 3.
      assert attackers(around(9) ++ [archer(%{"hp" => 20})]) == 3
    end

    test "Weapons1 means fewer are needed" do
      v = View.new(state(units: around(9) ++ [archer()]))
      v = %{v | upgrades: ["Weapons1"]}
      assert Roles.assignments(v, nil) |> Map.values() |> Enum.count(&(&1 == 900)) == 6
    end

    test "a seen enemy TechLab means we assume Armor1" do
      lab = building(800, "TechLab", 50, 50, 1)
      # 8 damage each: 60 HP needs 8.
      assert attackers(around(9) ++ [archer()], buildings: [lab]) == 8
    end

    test "no more than eight melee attackers on one target" do
      tough = unit(900, "Soldier", 12, 12, owner: 1)
      assert attackers(around(12) ++ [tough]) == 8
    end

    test "fighters at home don't chase an enemy out of the base; the wave does" do
      ours = unit(201, "Soldier", 20, 20)
      outside = unit(900, "Archer", 24, 24, owner: 1)
      v = View.new(state(units: [ours, outside]))
      assert Roles.target(v, nil, ours) == nil
      assert %{"id" => 900} = Roles.target(v, %{id: 1, members: [201]}, ours)
    end

    test "an enemy fighter comes before a building" do
      ours = unit(201, "Soldier", 12, 11, target_id: 800)
      barracks = building(800, "Barracks", 12, 12, 1)
      v = View.new(state(units: [ours, archer() |> Map.merge(%{"x" => 15, "y" => 11})], buildings: [barracks]))
      assert %{"id" => 900} = Roles.target(v, nil, ours)
    end

    test "leftovers hit buildings, towers first" do
      ours = unit(201, "Soldier", 12, 11)
      buildings = [building(800, "Barracks", 12, 12, 1), building(801, "GuardTower", 13, 14, 1)]
      v = View.new(state(units: [ours], buildings: buildings))
      assert %{"id" => 801} = Roles.target(v, nil, ours)
    end
  end
end
