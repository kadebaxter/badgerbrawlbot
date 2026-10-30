defmodule SwarmTest do
  use ExUnit.Case, async: true

  test "the enemy report groups what we remember by opponent" do
    enemies = %{
      901 => %{"owner" => 1, "type" => "Soldier", "hp" => 110, "seen" => 90},
      902 => %{"owner" => 1, "type" => "Archer", "hp" => 60, "seen" => 100},
      950 => %{"owner" => 2, "type" => "Soldier", "hp" => 110, "seen" => 40}
    }

    assert Swarm.enemy_report(enemies, 100) ==
             "player 1: 2 (1 Archer, 1 Soldier), strength 1350, seen 0-10 ticks ago\n" <>
               "player 2: 1 (1 Soldier), strength 990, seen 60-60 ticks ago"

    assert Swarm.enemy_report(%{}, 100) == "no enemy fighters seen yet"
  end
end
