defmodule Swarm.TowerRulesTest do
  @moduledoc """
  Guard Towers shoot buildings too, once no unit is in their reach (server revision 2), and the
  state says what each tower shot (`towerShots`). Nothing of ours goes up in an enemy tower's
  reach, no ore there is mined, no tower of ours goes up in reach of the Command Center we spare,
  and a tower that shot at us from the fog is known from then on.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, UnitBrain, View}

  @tower building(800, "GuardTower", 20, 20, 1)

  defp shot(tower_id, owner, from, target_id, at) do
    {fx, fy} = from
    {x, y} = at
    %{"towerId" => tower_id, "owner" => owner, "fromX" => fx, "fromY" => fy, "targetId" => target_id, "x" => x, "y" => y}
  end

  describe "towerShots" do
    test "read into the view" do
      s = shot(800, 1, {20, 20}, 5, {22, 22})
      assert View.new(Map.put(state([]), "towerShots", [s])).tower_shots == [s]
      assert View.new(state([])).tower_shots == []
    end

    test "a tower that shot at us from the fog is known from then on, until we see the spot without it" do
      soldier = unit(5, "Soldier", 26, 26)
      v = View.new(Map.put(state(units: [soldier]), "towerShots", [shot(800, 1, {20, 20}, 5, {26, 26})]))

      {v, memory} = Brain.see(v, Brain.new_memory())
      assert [%{"id" => 800, "x" => 20, "y" => 20}] = Roles.enemy_towers(v)

      # Next tick, no shot: still known.
      {v, memory} = Brain.see(View.new(state(units: [soldier])), memory)
      assert [%{"id" => 800}] = Roles.enemy_towers(v)

      # We see the spot and it isn't there: destroyed, forgotten.
      {v, _memory} = Brain.see(View.new(state(units: [unit(5, "Soldier", 21, 21)])), memory)
      assert Roles.enemy_towers(v) == []
    end

    test "the tower that shot a wave member is the one it goes after, even one we thought out of reach" do
      # Our estimate of where it is says 6 tiles, out of its reach of 5; the server says it shot.
      soldier = unit(5, "Soldier", 26, 26)
      wave = %{id: 1, members: [5]}
      v = View.new(state(units: [soldier], buildings: [@tower]))
      assert Roles.tower_hitting(v, wave, soldier) == nil

      v = %{v | tower_shots: [shot(800, 1, {20, 20}, 5, {26, 26})]}
      assert %{"id" => 800} = Roles.tower_hitting(v, wave, soldier)
    end
  end

  describe "enemy tower reach" do
    test "a worker doesn't go for ore in reach of one" do
      deposits = [%{"id" => 60, "x" => 22, "y" => 22, "remaining" => 900}, %{"id" => 61, "x" => 9, "y" => 3, "remaining" => 900}]
      worker = unit(100, "Worker", 8, 8)
      v = View.new(state(units: [worker], buildings: [@tower], deposits: deposits))
      assert Roles.under_tower?(v, {22, 22})
      refute Roles.under_tower?(v, {9, 3})

      assert %{"type" => "Gather", "targetId" => 61} = elem(UnitBrain.decide(100, UnitBrain.prepare(v, nil), %{mode: :gather, target: nil, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}), 0)
    end

    test "nothing of ours goes up in reach of one" do
      # A Barracks site: the ring around home, but an enemy tower sits right by it.
      tower = building(800, "GuardTower", 11, 11, 1)
      v = View.new(state(units: workers(8), buildings: [], ore: 500))
      site = Brain.site(terrain(), v, :base)
      assert site != nil

      v = View.new(state(units: workers(8), buildings: [tower], ore: 500))
      site = Brain.site(terrain(), v, :base)
      assert site == nil or View.dist(site, {11, 11}) > 6
    end
  end

  describe "the Command Center we spare" do
    # Our outpost depot at (53, 53), their Command Center at (47, 51), a Barracks done: the outpost
    # gets a tower (2 to 4 tiles toward the middle of the map, so in reach of it), but not when it
    # is the Command Center we spare.
    defp outpost_view(extra_players) do
      players = [
        %{"slot" => 0, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 7}, "score" => %{"survival" => 5000}},
        %{"slot" => 1, "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 56}, "score" => %{"survival" => 400}}
        | extra_players
      ]

      buildings = [building(900, "CommandCenter", 47, 51, 1), building(10, "Barracks", 11, 7), building(11, "ResourceDepot", 53, 53)]
      state(units: workers(5) ++ soldiers(5), buildings: buildings, ore: 400) |> Map.put("players", players) |> View.new()
    end

    defp tower_site(v) do
      {strategy, commands, _} = Brain.plan(v, looked(nil, 1, v.tick), terrain())
      send(self(), {:spare, strategy.spare})

      Enum.find_value(commands, fn
        %{"type" => "Build", "buildingType" => "GuardTower", "x" => x, "y" => y} -> {x, y}
        _ -> nil
      end)
    end

    test "no tower of ours goes up in its reach: it would shoot it on its own" do
      # Another opponent still in: nothing spared, the outpost gets its tower.
      third = %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 7}, "score" => %{"survival" => 900}}
      assert {_, _} = site = tower_site(outpost_view([third]))
      assert View.dist(site, {47, 51}) <= 6

      # The last one: spared, no tower there.
      site = tower_site(outpost_view([]))
      assert_received {:spare, nil}
      assert_received {:spare, %{id: 900}}
      assert site == nil or View.dist(site, {47, 51}) > 6
    end
  end

  describe "upgrades" do
    test "after Armor2: Fortify1, Armor3, Fortify2, each only once the one before it is done" do
      lab = building(20, "TechLab", 12, 7) |> Map.put("research", nil)
      base = ["Harvesting1", "Weapons1", "Armor1", "SiegeEngineering", "Harvesting2", "Weapons2", "Armor2"]

      research = fn upgrades, researching ->
        v = state(units: soldiers(30), buildings: [lab], ore: 2000) |> put_in(["you", "upgrades"], upgrades) |> put_in(["you", "researching"], researching) |> View.new()
        {_, commands, _} = Brain.plan(v, looked(nil, 1, v.tick), terrain())
        Enum.find_value(commands, &(&1["type"] == "Research" && &1["upgrade"]))
      end

      assert research.(base, []) == "Fortify1"
      assert research.(base ++ ["Fortify1"], []) == "Armor3"
      assert research.(base ++ ["Fortify1", "Armor3"], []) == "Fortify2"
      # Armor2 still going: not Armor3 yet.
      assert research.(base -- ["Armor2"], [%{"upgrade" => "Armor2"}]) == "Fortify1"
      assert research.(base -- ["Armor2"], [%{"upgrade" => "Armor2"}, %{"upgrade" => "Fortify1"}]) == nil
    end
  end
end
