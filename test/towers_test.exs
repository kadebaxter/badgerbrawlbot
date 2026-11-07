defmodule Swarm.TowersTest do
  @moduledoc """
  A wave member being shot by an enemy tower goes after that tower, once it has no enemy fighter
  to fight. Nobody else changes what they are doing.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Roles, UnitBrain, View}

  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
  # An enemy tower out in the field, east of us.
  @tower building(800, "GuardTower", 30, 10, 1)

  defp view(units, opts \\ []), do: View.new(state(Keyword.merge([units: units], opts)))
  defp soldiers_at(n, x, y), do: for(i <- 1..n, do: unit(200 + i, "Soldier", x, y))
  defp wave(n), do: %{id: 1, members: Enum.to_list(201..(200 + n))}
  defp attacking(n), do: %{@gather | mode: :attack, wave: wave(n)}

  # The server's memory of a building hidden by fog.
  defp remembered(b), do: b |> Map.take(["id", "owner", "type", "x", "y", "completed"]) |> Map.merge(%{"hp" => 500, "lastSeenTick" => 50})

  test "known towers: in sight, and remembered in the fog; only finished ones" do
    fogged = remembered(building(801, "GuardTower", 40, 10, 1))
    site = Map.put(building(802, "GuardTower", 20, 30, 1), "completed", false)
    v = %{view([], buildings: [@tower, site]) | remembered: [fogged, remembered(@tower)]}
    assert v |> Roles.enemy_towers() |> Enum.map(& &1["id"]) |> Enum.sort() == [800, 801]
  end

  test "a wave member in a tower's reach goes after it" do
    v = view(soldiers_at(3, 26, 10), buildings: [@tower])
    assert %{"id" => 800} = Roles.tower_hitting(v, wave(3), hd(soldiers_at(1, 26, 10)))
    assert {%{"type" => "Attack", "targetId" => 800}, _} = UnitBrain.decide(201, v, attacking(3))
  end

  test "enemy fighters come first" do
    enemy = unit(900, "Soldier", 26, 11, owner: 1)
    v = view([enemy | soldiers_at(3, 26, 10)], buildings: [@tower])
    assert {%{"type" => "Attack", "targetId" => 900}, _} = UnitBrain.decide(201, v, attacking(3))
  end

  test "only the one being shot: a wave member out of its reach carries on" do
    # 201 is in reach at (26, 10); 202 is 6 tiles off, out of it and of the leftover radius's tower.
    shot = unit(201, "Soldier", 26, 10)
    other = unit(202, "Soldier", 22, 17)
    v = view([shot, other], buildings: [@tower])
    assert Roles.tower_hitting(v, wave(2), other) == nil
    assert {%{"type" => "Attack", "x" => 56, "y" => 56}, _} = UnitBrain.decide(202, v, attacking(2))
  end

  test "one we can't see (remembered in the fog): walk at it until we do" do
    v = %{view(soldiers_at(3, 26, 13)) | remembered: [remembered(@tower)]}
    assert {%{"type" => "Move", "x" => 30, "y" => 10}, _} = UnitBrain.decide(201, v, attacking(3))
  end

  test "a tower that isn't shooting at it is a building like the rest" do
    # 6 from a tower (out of its reach) and from a Barracks: the Barracks, by id.
    ours = unit(201, "Soldier", 24, 10)
    barracks = building(799, "Barracks", 24, 16, 1)
    v = view([ours], buildings: [%{@tower | "id" => 803}, barracks])
    assert %{"id" => 799} = Roles.target(v, wave(1), ours)
  end

  test "at home: not this rule" do
    v = view(soldiers_at(3, 26, 10), buildings: [@tower])
    assert Roles.tower_hitting(v, nil, hd(soldiers_at(1, 26, 10))) == nil
  end
end
