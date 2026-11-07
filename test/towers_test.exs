defmodule Swarm.TowersTest do
  @moduledoc """
  Enemy towers shooting at us: fighters first, then the towers hitting us (not every tower), never
  one at a time; and hits from something we can't see: step out, and send someone to look.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, UnitBrain, View}

  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
  # An enemy tower out in the field, east of us.
  @tower building(800, "GuardTower", 30, 10, 1)

  defp view(units, opts \\ []), do: View.new(state(Keyword.merge([units: units], opts)))
  defp soldiers_at(n, x, y), do: for(i <- 1..n, do: unit(200 + i, "Soldier", x, y))
  defp hp(unit, hp), do: Map.put(unit, "hp", hp)

  # The server's memory of a building hidden by fog.
  defp remembered(b), do: b |> Map.take(["id", "owner", "type", "x", "y", "completed"]) |> Map.merge(%{"hp" => 500, "lastSeenTick" => 50})

  describe "which towers" do
    test "known towers: in sight, and remembered in the fog; only finished ones" do
      fogged = remembered(building(801, "GuardTower", 40, 10, 1))
      site = Map.put(building(802, "GuardTower", 20, 30, 1), "completed", false)
      v = %{view([], buildings: [@tower, site]) | remembered: [fogged, remembered(@tower)]}
      assert v |> Roles.enemy_towers() |> Enum.map(& &1["id"]) |> Enum.sort() == [800, 801]
    end

    test "hitting us: only with one of our units in its reach" do
      assert Roles.towers_hitting(view(soldiers_at(1, 26, 10), buildings: [@tower])) == [@tower]
      assert Roles.towers_hitting(view(soldiers_at(1, 24, 10), buildings: [@tower])) == []
    end

    test "a tower that leaves us alone is a building like any other" do
      # In the wave, 6 from a tower (out of its reach) and from a Barracks: no tower first.
      ours = unit(201, "Soldier", 24, 10)
      barracks = building(799, "Barracks", 24, 16, 1)
      tower = %{@tower | "id" => 803}
      v = view([ours], buildings: [tower, barracks])
      assert %{"id" => 799} = Roles.target(v, %{id: 1, members: [201]}, ours)
    end
  end

  describe "a unit by a tower hitting us" do
    test "enemy fighters come first" do
      ours = soldiers_at(6, 27, 10)
      enemy = unit(900, "Soldier", 27, 11, owner: 1)
      v = view([enemy | ours], buildings: [@tower])
      assert {%{"type" => "Attack", "targetId" => 900}, _} = UnitBrain.decide(201, v, @gather)
    end

    test "then the tower, with enough of us there to take it" do
      v = view(soldiers_at(6, 27, 10), buildings: [@tower])
      assert {:hit, %{"id" => 800}} = Roles.tower_job(v, hd(soldiers_at(1, 27, 10)))
      assert {%{"type" => "Attack", "targetId" => 800}, _} = UnitBrain.decide(201, v, @gather)
    end

    test "home fighters too: it is hitting us" do
      # Guards and attackers alike; no wave out.
      v = view(soldiers_at(8, 27, 10), buildings: [@tower])
      assert {%{"type" => "Attack", "targetId" => 800}, _} = UnitBrain.decide(208, v, @gather)
    end

    test "one we can't see (remembered in the fog): walk at it until we do" do
      v = %{view(soldiers_at(6, 26, 14)) | remembered: [remembered(@tower)]}
      assert {%{"type" => "Move", "x" => 30, "y" => 10}, _} = UnitBrain.decide(201, v, @gather)
    end

    test "too few of us to take it: step out of its reach, not in one at a time" do
      v = view(soldiers_at(2, 27, 10), buildings: [@tower])
      assert {:back_off, {x, y}} = Roles.tower_job(v, hd(soldiers_at(1, 27, 10)))
      assert View.dist({x, y}, {30, 10}) > 5
      assert {%{"type" => "Move", "x" => ^x, "y" => ^y}, _} = UnitBrain.decide(201, v, @gather)
    end

    test "enemy fighters by the tower count on its side" do
      ours = soldiers_at(5, 27, 10)
      theirs = for i <- 1..4, do: unit(900 + i, "Soldier", 33, 10, owner: 1)
      assert {:back_off, _} = Roles.tower_job(view(ours ++ theirs, buildings: [@tower]), hd(ours))
    end

    test "nothing to do about a tower nobody of ours is near" do
      assert Roles.tower_job(view(soldiers_at(6, 20, 10), buildings: [@tower]), hd(soldiers_at(1, 20, 10))) == nil
    end
  end

  describe "hit by something we can't see" do
    defp plan(units, memory, opts) do
      tick = Keyword.get(opts, :tick, 100)
      state = state(Keyword.merge([units: units, tick: tick], opts))
      Brain.plan(View.new(state), looked(memory, 1, tick), terrain())
    end

    # `hit_id` down to 100 HP, the rest still at 110.
    defp after_hit(units, hit_id), do: Enum.map(units, &if(&1["id"] == hit_id, do: hp(&1, 100), else: hp(&1, 110)))

    defp hit_once(units, hit_id, opts \\ []) do
      {_, _, memory} = plan(Enum.map(units, &hp(&1, 110)), Brain.new_memory(), opts)
      plan(after_hit(units, hit_id), memory, Keyword.put(opts, :tick, 101))
    end

    test "a scout goes to the spot, and the decision log says so" do
      units = [unit(201, "Soldier", 30, 20), unit(300, "Scout", 15, 15)]
      {strategy, _, memory} = hit_once(units, 201)
      assert [%{pos: {30, 20}, by: 300, look: {30, 20}}] = strategy.hidden
      assert [%{pos: {30, 20}}] = memory.hidden
      assert Enum.any?(strategy.why, &match?({:hidden_hit, _}, &1))
    end

    test "with no scout, the closest fighter looks a few tiles toward the enemy" do
      units = [unit(201, "Soldier", 30, 20), unit(202, "Soldier", 12, 12)]
      {strategy, _, _} = hit_once(units, 201)
      assert [%{by: 201, look: look}] = strategy.hidden
      # The enemy's start is at (56, 56).
      assert View.dist(look, {56, 56}) < View.dist({30, 20}, {56, 56})
    end

    test "not for a hit we can explain: an enemy we see in reach, or a tower we know of" do
      soldier = unit(900, "Soldier", 31, 20, owner: 1)
      {strategy, _, _} = hit_once([unit(201, "Soldier", 30, 20), soldier], 201)
      assert strategy.hidden == []

      {strategy, _, _} = hit_once([unit(201, "Soldier", 27, 10)], 201, buildings: [@tower])
      assert strategy.hidden == []
    end

    test "found once a tower we know of reaches the spot" do
      units = [unit(201, "Soldier", 30, 14), unit(300, "Scout", 15, 15)]
      {_, _, memory} = hit_once(units, 201)
      {strategy, _, _} = plan(after_hit(units, 201), memory, tick: 102, buildings: [@tower])
      assert strategy.hidden == []
      assert Enum.any?(strategy.why, &match?({:hidden_found, _}, &1))
    end

    test "forgotten after a while with no more hits" do
      units = [unit(201, "Soldier", 30, 20), unit(300, "Scout", 15, 15)]
      {_, _, memory} = hit_once(units, 201)
      {strategy, _, _} = plan(after_hit(units, 201), memory, tick: 130)
      assert strategy.hidden == []
    end

    test "the rest step out of the area; the one looking goes; workers run too" do
      spot = %{pos: {30, 20}, by: 300, look: {30, 20}}
      strategy = Map.put(@gather, :hidden, [spot])
      soldier = unit(201, "Soldier", 31, 20)
      scout = unit(300, "Scout", 25, 20)
      worker = unit(101, "Worker", 29, 21, activity: "Gathering")
      v = view([soldier, scout, worker])

      assert {%{"type" => "Move", "x" => x, "y" => y}, _} = UnitBrain.decide(201, v, strategy)
      assert View.dist({x, y}, {30, 20}) >= 7
      assert {%{"type" => "Move", "x" => 30, "y" => 20}, _} = UnitBrain.decide(300, v, strategy)
      assert {%{"type" => "Move"}, _} = UnitBrain.decide(101, v, strategy)
    end
  end
end
