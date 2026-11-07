defmodule Swarm.RolesTest do
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Roles, View}

  defp view(units, buildings \\ []), do: View.new(state(units: units, buildings: buildings))

  test "the seven newest fighters guard, however big the army" do
    assert Roles.guards(view(soldiers(8)), nil) == MapSet.new(202..208)
    assert MapSet.size(Roles.guards(view(soldiers(30)), nil)) == 7
  end

  test "scouts are neither guards nor attackers" do
    v = view([unit(300, "Scout", 10, 10) | soldiers(4)])
    assert Roles.role(v, nil, 300) == :scout
    refute MapSet.member?(Roles.guards(v, nil), 300)
  end

  describe "outposts" do
    defp depot, do: building(50, "ResourceDepot", 30, 30)
    defp miners(n), do: for(i <- 1..n, do: unit(400 + i, "Worker", 31, 31, activity: "Gathering"))

    test "an outpost with miners gets a group of three escorts, after the guards" do
      roles = Roles.home_roles(view(soldiers(12) ++ miners(6), [depot()]), nil)
      assert Enum.map(206..212, &roles[&1]) == List.duplicate(:guard, 7)
      assert Enum.map(203..205, &roles[&1]) == List.duplicate({:escort, {30, 30}}, 3)
      assert roles[202] == :attacker and roles[201] == :attacker
    end

    test "fewer than three to spare: no escorts at all, they attack instead" do
      roles = Roles.home_roles(view(soldiers(9) ++ miners(6), [depot()]), nil)
      refute Enum.any?(roles, &match?({_, {:escort, _}}, &1))
      assert roles[201] == :attacker and roles[202] == :attacker
    end

    test "a depot seven tiles from the Command Center is an outpost" do
      assert Roles.outposts(view([], [building(50, "ResourceDepot", 14, 7)])) == [{14, 7}]
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

    test "fighters already at an outpost keep it, and the closest fill the rest of the group" do
      at_outpost = for id <- [201, 202], do: unit(id, "Soldier", 31, 30)
      near = for id <- [203, 204, 205], do: unit(id, "Soldier", 18, 18)
      far = for i <- 6..12, do: unit(200 + i, "Soldier", 10, 10)
      roles = Roles.home_roles(view(at_outpost ++ near ++ far ++ miners(6), [depot()]), nil)
      assert Enum.map([201, 202, 205], &roles[&1]) == List.duplicate({:escort, {30, 30}}, 3)
      assert roles[203] == :attacker and roles[204] == :attacker
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

  describe "recall" do
    # Five wave members out by the enemy, three soldiers at home.
    setup do
      wave = %{id: 1, members: [201, 202, 203, 204, 205]}
      out = soldiers(5) |> Enum.map(&%{&1 | "x" => 45, "y" => 45})
      home = for i <- 1..3, do: unit(300 + i, "Soldier", 10, 10)
      %{wave: wave, ours: out ++ home}
    end

    defp raiders(n, x, y), do: for(i <- 1..n, do: unit(900 + i, "Soldier", x, y, owner: 1))

    test "when the base is hit harder than home can hold", %{wave: wave, ours: ours} do
      assert {_, _} = Roles.recall(view(ours ++ raiders(6, 12, 9)), wave)
    end

    test "when our workers out in the field are", %{wave: wave, ours: ours} do
      miners = for i <- 1..4, do: unit(100 + i, "Worker", 30, 8)
      assert {_, _} = Roles.recall(view(ours ++ miners ++ raiders(6, 31, 8)), wave)
    end

    test "when an outpost is", %{wave: wave, ours: ours} do
      depot = building(2, "ResourceDepot", 30, 30)
      assert {_, _} = Roles.recall(view(ours ++ raiders(6, 31, 30), [depot]), wave)
    end

    test "not for a raid home can hold", %{wave: wave, ours: ours} do
      assert Roles.recall(view(ours ++ raiders(2, 12, 9)), wave) == nil
      towers = for {id, x} <- [{2, 12}, {3, 13}, {4, 11}], do: building(id, "GuardTower", x, 10)
      assert Roles.recall(view(ours ++ raiders(6, 12, 9), towers), wave) == nil
    end

    test "only defenders near the raid count, and a tower is worth two soldiers", %{wave: wave} do
      # Twenty raiders at the base. Home: seven guards and three towers there, and nine fighters
      # away at an outpost, which don't count.
      raiders = for i <- 1..20, do: unit(900 + i, "Soldier", 12, 9, owner: 1)
      guards = for i <- 1..7, do: unit(300 + i, "Soldier", 10, 10)
      away = for i <- 1..9, do: unit(400 + i, "Soldier", 40, 40)
      towers = for {id, x} <- [{2, 12}, {3, 13}, {4, 11}], do: building(id, "GuardTower", x, 10)
      far_tower = building(5, "GuardTower", 40, 42)

      # 20 x 990 against 7 x 990 + 3 x 2 x 990.
      assert {19800.0, 12870.0} = Roles.recall(view(raiders ++ guards ++ away, [far_tower | towers]), wave)
    end

    test "not for enemies nowhere near anything of ours", %{wave: wave, ours: ours} do
      assert Roles.recall(view(ours ++ raiders(10, 30, 50)), wave) == nil
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
      outside = unit(900, "Soldier", 24, 24, owner: 1)
      v = View.new(state(units: [ours, outside]))
      assert Roles.target(v, nil, ours) == nil
      assert %{"id" => 900} = Roles.target(v, %{id: 1, members: [201]}, ours)
    end

    test "but they fight back against an enemy that can hit them" do
      ours = unit(201, "Soldier", 20, 20)
      archer = unit(900, "Archer", 24, 24, owner: 1)
      assert %{"id" => 900} = Roles.target(View.new(state(units: [ours, archer])), nil, ours)
    end

    test "out of the base, a building next to a unit going home doesn't keep it there" do
      # A recalled wave: no longer members, standing by the enemy's Command Center.
      ours = unit(201, "Soldier", 53, 34)
      cc = building(78, "CommandCenter", 54, 35, 2)
      assert Roles.target(View.new(state(units: [ours], buildings: [cc])), nil, ours) == nil

      # An enemy soldier hitting it: it fights back.
      soldier = unit(900, "Soldier", 52, 34, owner: 1)
      v = View.new(state(units: [ours, soldier], buildings: [cc]))
      assert %{"id" => 900} = Roles.target(v, nil, ours)
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

    test "then construction sites, then other buildings, and Command Centers last" do
      ours = unit(201, "Soldier", 12, 11)
      site = Map.put(building(802, "Barracks", 14, 14, 1), "completed", false)
      barracks = building(800, "Barracks", 12, 12, 1)
      cc = building(803, "CommandCenter", 12, 13, 1)

      # The closest is the Command Center, then the Barracks; the site, farther, goes first.
      v = View.new(state(units: [ours], buildings: [cc, barracks, site]))
      assert %{"id" => 802} = Roles.target(v, nil, ours)

      v = View.new(state(units: [ours], buildings: [cc, barracks]))
      assert %{"id" => 800} = Roles.target(v, nil, ours)

      v = View.new(state(units: [ours], buildings: [cc]))
      assert %{"id" => 803} = Roles.target(v, nil, ours)
    end
  end
end
