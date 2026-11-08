defmodule Swarm.MediumGameTest do
  @moduledoc """
  6 to 9 players: army first, four towers not ten, no waiting for a tower square, the backup
  Command Center last, and the ore of a neighbor we eliminate taken for a second base.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  # Seven players: us at (7, 7), player 1 at (56, 56), five more around the edge.
  defp seven(state, fallen) do
    more = [{2, 31, 7}, {3, 56, 7}, {4, 7, 31}, {5, 56, 31}, {6, 31, 56}]

    Map.update!(state, "players", fn ps ->
      ps ++ for({slot, x, y} <- more, do: %{"slot" => slot, "eliminated" => slot in fallen, "startPosition" => %{"x" => x, "y" => y}})
    end)
  end

  # A scout has just looked at player 2, the nearest neighbor and so the target.
  defp plan(opts, fallen \\ [], memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(seven(state(opts), fallen)), looked(memory, 2, Keyword.get(opts, :tick, 100)), terrain())

  defp builds(commands), do: for(%{"type" => "Build"} = c <- commands, do: c["buildingType"])

  test "after the Barracks and the depot, a tower toward each neighbor, then the Barracks" do
    # Eight soldiers: past the army floor, which would take the ore first.
    start = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9)]
    assert ["GuardTower"] = builds(elem(plan(units: workers(11) ++ soldiers(8), buildings: start, ore: 300), 1))

    one_tower = start ++ [building(4, "GuardTower", 12, 12)]
    assert ["GuardTower"] = builds(elem(plan(units: workers(11) ++ soldiers(8), buildings: one_tower, ore: 300), 1))

    two = one_tower ++ [building(5, "GuardTower", 12, 4)]
    assert ["Barracks"] = builds(elem(plan(units: workers(12) ++ soldiers(8), buildings: two, ore: 300), 1))
  end

  test "four towers in all, and the backup Command Center only at twenty fighters" do
    done =
      [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(6, "Barracks", 12, 3),
       building(7, "TechLab", 7, 12), building(8, "Barracks", 3, 3)] ++
        for({id, x, y} <- [{10, 12, 12}, {11, 12, 4}, {12, 4, 12}, {13, 14, 8}], do: building(id, "GuardTower", x, y))

    refute "GuardTower" in builds(elem(plan(units: workers(30) ++ soldiers(19), buildings: done, ore: 1000), 1))
    refute "CommandCenter" in builds(elem(plan(units: workers(30) ++ soldiers(19), buildings: done, ore: 1000), 1))
    assert "CommandCenter" in builds(elem(plan(units: workers(30) ++ soldiers(20), buildings: done, ore: 1000), 1))
  end

  test "the first wave goes at fifteen, without waiting for a tower square" do
    # 22 soldiers: 7 guards, 15 attackers at the rally point, nothing known of the enemy.
    assert {%{wave: %{members: members}}, _, _} = plan(units: soldiers(22))
    assert length(members) == 15
  end

  test "a neighbor we eliminated: a depot on its ore, the side nearest us" do
    # Player 2 (at (31, 7)) is out; its ore lies around (31, 10).
    their_ore = for i <- 0..3, do: %{"id" => 300 + i, "x" => 29 + i, "y" => 10, "remaining" => 1000}
    home_ore = [%{"id" => 4, "x" => 2, "y" => 7, "remaining" => 5000}]
    built = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9)]
    opts = [units: workers(20) ++ soldiers(16), buildings: built, deposits: home_ore ++ their_ore, ore: 500]

    {_, commands, _} = plan(opts, [2])
    assert [%{"buildingType" => "ResourceDepot", "x" => x, "y" => y}] = for(%{"buildingType" => "ResourceDepot"} = c <- commands, do: c)
    assert View.dist({x, y}, {30, 10}) <= 3

    # Not while it is still in the game.
    {_, commands, _} = plan(opts)
    refute Enum.any?(commands, &(&1["buildingType"] == "ResourceDepot"))
  end
end
