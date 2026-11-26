defmodule Swarm.EngageTest do
  @moduledoc """
  From a fight of 67 against 62 lost 62 for 26: sent at an enemy by name, a Soldier stops when it
  dies and stands until its next order, and with several on each target a third of the army was
  idle every other tick. Soldiers go in on an attack-move, which the game works out afresh every
  tick; Archers and the fights round a spared Command Center are by name as before.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{UnitBrain, View}

  @attack %{mode: :attack, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}

  defp decide(unit, others, strategy \\ @attack, memory \\ %{intent: nil}) do
    v = View.new(state(units: [unit | others]))
    UnitBrain.decide(unit["id"], v, strategy, memory)
  end

  defp raid(n \\ 3), do: for(i <- 1..n, do: unit(900 + i, "Soldier", 13, 12, owner: 1))
  defp friends(n \\ 8), do: for(i <- 1..n, do: unit(300 + i, "Soldier", 11, 11))

  test "a Soldier goes in on an attack-move at its enemy, not an attack on it by name" do
    {cmd, memory} = decide(unit(2, "Soldier", 10, 10), friends() ++ raid())
    assert %{"type" => "Attack", "unitIds" => [2], "x" => 13, "y" => 12} = cmd
    refute Map.has_key?(cmd, "targetId")
    assert memory.intent == {:engage, {13, 12}}
  end

  test "an Archer still shoots whom it was given, by name" do
    {cmd, _} = decide(unit(2, "Archer", 10, 12), friends() ++ raid())
    assert %{"type" => "Attack", "targetId" => id} = cmd
    assert id in 901..903
  end

  test "attacking already and the fight a step or two on: nothing is sent, the game carries on" do
    fighting = unit(2, "Soldier", 12, 12, activity: "Attacking", target_id: 901)
    assert {:no_change, _} = decide(fighting, friends() ++ raid(), @attack, %{intent: {:engage, {13, 12}}})
    # Its enemy is where the next of them stands, two tiles on.
    moved = for u <- raid(), do: %{u | "x" => 15}
    assert {:no_change, _} = decide(fighting, friends() ++ moved, @attack, %{intent: {:engage, {13, 12}}})
  end

  test "idle in a fight is told again at once, even standing next to them" do
    idle = unit(2, "Soldier", 12, 12, activity: "Idle")
    assert {%{"type" => "Attack", "x" => 13, "y" => 12}, _} = decide(idle, friends() ++ raid(), @attack, %{intent: {:engage, {13, 12}}})
  end

  test "the fight has moved well on: the attack-move is sent after it" do
    fighting = unit(2, "Soldier", 12, 12, activity: "Attacking", target_id: 901)
    moved = for u <- raid(), do: %{u | "x" => 9, "y" => 14}
    assert {%{"type" => "Attack", "x" => 9, "y" => 14}, _} = decide(fighting, friends() ++ moved, @attack, %{intent: {:engage, {13, 12}}})
  end

  test "with the last Command Center spared, by name: an attack-move there would turn on it" do
    spare = %{pos: {50, 50}, goal: {44, 44}, siege_camp: {40, 40}, id: 999}
    {cmd, _} = decide(unit(2, "Soldier", 10, 10), friends() ++ raid(), Map.put(@attack, :spare, spare))
    assert %{"type" => "Attack", "targetId" => id} = cmd
    assert id in 901..903
  end

  test "a whole fight, tick by tick: as theirs die one by one, no Soldier of ours is ever left without an order" do
    # Ten of ours in contact with six of theirs. Each tick the lowest of theirs dies; ours whose
    # order the game cleared show up idle.
    ours = for i <- 1..10, do: unit(200 + i, "Soldier", 12, 10 + rem(i, 4))
    theirs = for i <- 1..6, do: unit(900 + i, "Soldier", 13, 10 + rem(i, 4), owner: 1)

    Enum.reduce(1..5, {theirs, Map.new(ours, &{&1["id"], %{intent: nil}})}, fn n, {theirs, memories} ->
      # Half of ours come back idle each tick (their target died).
      now = for u <- ours, do: if(rem(u["id"] + n, 2) == 0, do: %{u | "activity" => "Idle"}, else: %{u | "activity" => "Attacking"})
      v = View.new(state(units: now ++ theirs, tick: 100 + n))

      memories =
        for u <- now, into: %{} do
          {cmd, memory} = UnitBrain.decide(u["id"], v, @attack, memories[u["id"]])
          # An idle one always gets an attack-move; one still swinging gets one or is left alone.
          if u["activity"] == "Idle", do: assert(match?(%{"type" => "Attack", "x" => _, "y" => _}, cmd) and not is_map_key(cmd, "targetId"))
          if is_map(cmd), do: refute(Map.has_key?(cmd, "targetId"))
          {u["id"], memory}
        end

      {tl(theirs), memories}
    end)
  end
end
