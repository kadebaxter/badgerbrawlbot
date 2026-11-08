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

  test "a wave member in a tower's reach goes after it, with enough of us there" do
    # Five soldiers (4950) against the tower (3960, four soldiers).
    v = view(soldiers_at(5, 26, 10), buildings: [@tower])
    assert %{"id" => 800} = Roles.tower_hitting(v, wave(5), hd(soldiers_at(1, 26, 10)))
    assert {%{"type" => "Attack", "targetId" => 800}, _} = UnitBrain.decide(201, v, attacking(5))
  end

  test "too few of us there: nobody walks in alone, they fall back" do
    v = view(soldiers_at(3, 26, 10), buildings: [@tower])
    assert {%{"type" => "Move", "x" => 10, "y" => 10}, _} = UnitBrain.decide(201, v, attacking(3))
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
    v = %{view(soldiers_at(5, 26, 13)) | remembered: [remembered(@tower)]}
    assert {%{"type" => "Move", "x" => 30, "y" => 10}, _} = UnitBrain.decide(201, v, attacking(5))
  end

  test "a tower that isn't shooting at it is a building like the rest" do
    # Five of us 6 from a tower (out of its reach) and from a Barracks: the Barracks, by id.
    ours = soldiers_at(5, 25, 10)
    barracks = building(799, "Barracks", 25, 16, 1)
    v = view(ours, buildings: [%{@tower | "id" => 803, "x" => 31}, barracks])
    assert %{"id" => 799} = Roles.target(v, wave(5), hd(ours))
  end

  test "a group goes in together: the ones behind count, not only those already by the enemy" do
    # Eight archers in our base at (14, 10). Three of ours 5 tiles from them, seventeen more 5
    # behind those.
    archers = for i <- 1..8, do: unit(900 + i, "Archer", 14, 10, owner: 1)
    front = for i <- 1..3, do: unit(200 + i, "Soldier", 9, 10)
    behind = for i <- 4..20, do: unit(200 + i, "Soldier", 4, 10)
    v = view(archers ++ front ++ behind)
    assert %{"id" => _} = Roles.target(v, nil, hd(front))

    # The same three on their own still hold back.
    assert Roles.target(view(archers ++ front), nil, hd(front)) == nil
  end

  test "no flip-flop: going in and pulling back use one measure, with a gap between them" do
    # Six of ours in a wave (5940) four tiles from five archers (6187): not enough to go in, but not
    # "losing" either (that takes 1.3 x 5940). Before, it pulled back here, and one tile back was
    # "even" again and went in: it flipped every tick.
    ours = soldiers_at(6, 40, 39)
    archers = for i <- 1..5, do: unit(900 + i, "Archer", 36, 41, owner: 1)
    v = view(ours ++ archers)
    odds = Roles.odds_for(v, hd(ours), {40, 39})
    refute Roles.engage?(odds)
    refute Roles.losing?(odds)
    refute match?({%{"type" => "Move", "x" => 10, "y" => 10}, _}, UnitBrain.decide(201, v, attacking(6)))

    # Clearly outmatched (ten archers, 12375): it pulls back.
    pack = for i <- 1..10, do: unit(900 + i, "Archer", 36, 41, owner: 1)
    assert Roles.losing_for?(view(ours ++ pack), hd(ours), {40, 39})
  end

  test "at home: not this rule" do
    v = view(soldiers_at(3, 26, 10), buildings: [@tower])
    assert Roles.tower_hitting(v, nil, hd(soldiers_at(1, 26, 10))) == nil
  end
end
