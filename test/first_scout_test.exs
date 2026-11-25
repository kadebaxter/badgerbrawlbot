defmodule Swarm.FirstScoutTest do
  @moduledoc """
  From the game with no scout: under the army floor every Barracks stayed full of Soldiers, no
  scout was ever trained, and the only ore we ever knew of was the home field. From tick 120 there
  is always one scout, ahead of the Soldiers.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  # Two Barracks, both with two Soldiers queued: no room by the old rule, and the floor not met.
  defp full(b), do: %{b | "production" => [%{"unitType" => "Soldier"}, %{"unitType" => "Soldier"}]}
  defp barracks, do: [full(building(10, "Barracks", 11, 3)), full(building(11, "Barracks", 11, 6))]
  defp plan(opts), do: Brain.plan(View.new(state(Keyword.merge([buildings: barracks(), tick: 150], opts))), Brain.new_memory(), terrain())
  defp trained(commands), do: for(%{"type" => "Produce", "unitType" => u} <- commands, do: u)

  test "with none, one is the first thing trained, full queues or not" do
    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 400)
    assert [%{"type" => "Produce", "unitType" => "Scout", "buildingId" => 10} | _] = commands
    assert Enum.count(trained(commands), &(&1 == "Scout")) == 1
  end

  test "short of the ore for it, the ore waits: no Soldier takes it" do
    queued = [building(10, "Barracks", 11, 3), building(11, "Barracks", 11, 6)]
    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 170, buildings: queued)
    # 100 of it is kept for workers: 70 to spend, and a scout is 75.
    refute "Scout" in trained(commands) or "Soldier" in trained(commands)

    # Ten more ore and it is trained, before any Soldier.
    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 180, buildings: queued)
    assert [%{"unitType" => "Scout"} | _] = commands
    refute "Soldier" in trained(commands)
  end

  test "not with one alive or one on its way, and not before tick 120" do
    {_, commands, _} = plan(units: [unit(300, "Scout", 30, 30) | workers(12) ++ soldiers(4)], ore: 400)
    refute "Scout" in trained(commands)

    coming = [%{building(10, "Barracks", 11, 3) | "production" => [%{"unitType" => "Scout"}, %{"unitType" => "Soldier"}]}, full(building(11, "Barracks", 11, 6))]
    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 400, buildings: coming)
    refute "Scout" in trained(commands)

    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 400, tick: 110)
    refute "Scout" in trained(commands)
  end

  test "through a game: trained, out, killed, and trained again" do
    units = workers(12) ++ soldiers(4)
    {_, commands, memory} = plan(units: units, ore: 400)
    assert "Scout" in trained(commands)

    # It is out: nothing more.
    step = fn units, tick, memory -> Brain.plan(View.new(state(units: units, buildings: barracks(), ore: 400, tick: tick)), memory, terrain()) end
    {_, commands, memory} = step.([unit(300, "Scout", 30, 30) | units], 170, memory)
    refute "Scout" in trained(commands)

    # It died: the next one.
    {_, commands, _} = step.(units, 200, memory)
    assert [%{"unitType" => "Scout"} | _] = commands
  end
end
