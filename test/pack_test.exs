defmodule Swarm.PackTest do
  @moduledoc """
  From the four-player game lost in the middle: an army counts as what we have seen of it less
  what we killed, not what the fog shows this tick; the serum for a raid waits for the fight to be
  on; and an army at a depot on its own calls no wave home and pulls nobody out to it.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, View}

  @soldier Roles.strength([%{"type" => "Soldier"}])

  defp theirs(ids, x, y), do: for(i <- ids, do: unit(900 + i, "Soldier", x, y, owner: 1))
  defp see(opts, memory \\ nil), do: Brain.see(View.new(state(opts)), memory)
  defp unseen(v), do: v.recent_enemies |> Enum.map(& &1["id"]) |> Enum.sort()

  describe "a pack seen together" do
    # Twenty Soldiers at (30, 30) at tick 100, one of ours watching. Six ticks on five of them are in
    # sight three tiles east, and we see where the rest stood: nobody there.
    setup do
      {_, memory} = see(units: [unit(201, "Soldier", 26, 30) | theirs(1..20, 30, 30)], tick: 100)
      %{memory: memory}
    end

    test "those out of sight still count, by the ones in sight", %{memory: memory} do
      {v, _} = see([units: [unit(201, "Soldier", 29, 30) | theirs(1..5, 33, 30)], tick: 106], memory)
      assert unseen(v) == Enum.to_list(906..920)
      assert Enum.all?(v.recent_enemies, &(View.pos(&1) == {33, 30}))

      [g] = Map.values(Roles.groups(v, nil).groups)
      assert g.worth == 20 * @soldier

      # Without the memory: the five in sight.
      [g] = Map.values(Roles.groups(View.new(state(units: [unit(201, "Soldier", 29, 30) | theirs(1..5, 33, 30)], tick: 106)), nil).groups)
      assert g.worth == 5 * @soldier
    end

    test "less the ones we saw die", %{memory: memory} do
      killed = for id <- [906, 907, 908], do: %{"kind" => "UnitKilled", "entityId" => id}
      st = state(units: [unit(201, "Soldier", 29, 30) | theirs(1..5, 33, 30)], tick: 106) |> Map.put("events", killed)
      {v, _} = Brain.see(View.new(st), memory)
      assert unseen(v) == Enum.to_list(909..920)
    end

    test "ten of ours stay out of the five in sight with fifteen behind them", %{memory: memory} do
      ours = for i <- 1..10, do: unit(200 + i, "Soldier", 28, 30)
      {v, _} = see([units: ours ++ theirs(1..5, 33, 30), tick: 106], memory)
      assert Roles.away?(Roles.group_for(v, nil, hd(ours)))
      # By what is in sight alone they would have gone in.
      refute Roles.away?(Roles.group_for(View.new(state(units: ours ++ theirs(1..5, 33, 30), tick: 106)), nil, hd(ours)))
    end

    test "through the ticks: seen, hidden, seen again, and the count holds", %{memory: memory} do
      # Tick by tick they walk east; a different handful is in sight each time.
      {memory, counts} =
        Enum.reduce(1..8, {memory, []}, fn n, {memory, counts} ->
          shown = if rem(n, 2) == 0, do: 1..3, else: 8..12
          {v, memory} = see([units: [unit(201, "Soldier", 26 + n, 30) | theirs(shown, 30 + n, 30)], tick: 100 + n], memory)
          [g] = Map.values(Roles.groups(v, nil).groups)
          {memory, [round(g.worth / @soldier) | counts]}
        end)

      assert counts == List.duplicate(20, 8)
      assert map_size(memory.packs) == 20
    end

    test "two that left the rest far behind are two", %{memory: memory} do
      # Twenty ticks on, 26 tiles away: farther than the others could have walked with them.
      {v, _} = see([units: [unit(201, "Soldier", 52, 30) | theirs(1..2, 56, 30)], tick: 120], memory)
      assert unseen(v) == []
    end

    test "not for ever: forty ticks out of sight and they are forgotten", %{memory: memory} do
      {v, memory} = see([units: [unit(201, "Soldier", 29, 30) | theirs(1..5, 33, 30)], tick: 141], memory)
      assert unseen(v) == []
      assert map_size(memory.packs) == 5
    end

    test "with none of the pack in sight, nothing is added", %{memory: memory} do
      {v, _} = see([units: [unit(201, "Soldier", 10, 10)], tick: 110], memory)
      assert unseen(v) == []
    end
  end

  describe "the serum for a raid" do
    defp plan(opts, memory \\ Brain.new_memory()),
      do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

    test "waits until eight of ours are within six tiles of it" do
      # Ten of ours against fourteen in the base: ours with the serum. Nine tiles off, all ten are
      # in that fight already, but it isn't on yet: not taken. Five tiles off, it is.
      far = for i <- 1..10, do: unit(200 + i, "Soldier", 5, 5)
      assert {%{serum: nil}, _, _} = plan(units: far ++ theirs(1..14, 14, 14))
      near = for i <- 1..10, do: unit(200 + i, "Soldier", 9, 9)
      assert {%{serum: :take}, _, _} = plan(units: near ++ theirs(1..14, 14, 14))
    end
  end

  describe "an army at a depot on its own" do
    # A depot in the middle with our miners, and a wave out by the enemy's base.
    @depot building(50, "ResourceDepot", 30, 30)
    defp miners, do: for(i <- 1..4, do: unit(100 + i, "Worker", 31, 31, activity: "Gathering"))
    defp out, do: for(i <- 1..5, do: unit(200 + i, "Soldier", 45, 45))
    @wave %{id: 1, members: [201, 202, 203, 204, 205]}

    test "calls no wave home; one at a Command Center of ours does" do
      v = View.new(state(units: out() ++ miners() ++ theirs(1..12, 33, 31), buildings: [@depot]))
      assert Roles.base_recall(v, @wave) == nil
      # Home is still hit harder than it can hold: no new wave leaves (`recall/2`).
      assert {_, _} = Roles.recall(v, @wave)

      base = building(51, "CommandCenter", 30, 27)
      v = View.new(state(units: out() ++ miners() ++ theirs(1..12, 33, 31), buildings: [@depot, base]))
      assert {_, _} = Roles.base_recall(v, @wave)

      v = View.new(state(units: out() ++ theirs(1..12, 12, 9)))
      assert {_, _} = Roles.base_recall(v, @wave)
    end

    test "pulls no attacker from home; a few raiders there still do, and so does an army at a base" do
      home = soldiers(12)
      far = hd(home)

      v = View.new(state(units: home ++ miners() ++ theirs(1..12, 33, 31), buildings: [@depot]))
      assert Roles.group_for(v, nil, far) == nil

      v = View.new(state(units: home ++ miners() ++ theirs(1..4, 33, 31), buildings: [@depot]))
      assert Roles.group_for(v, nil, far).raid

      base = building(51, "CommandCenter", 30, 27)
      v = View.new(state(units: home ++ miners() ++ theirs(1..12, 33, 31), buildings: [@depot, base]))
      assert Roles.group_for(v, nil, far).raid
    end

    test "one of ours right by it is still in its fight" do
      by = unit(230, "Soldier", 29, 30)
      v = View.new(state(units: [by | soldiers(12)] ++ miners() ++ theirs(1..12, 33, 31), buildings: [@depot]))
      assert Roles.group_for(v, nil, by) != nil
    end
  end
end
