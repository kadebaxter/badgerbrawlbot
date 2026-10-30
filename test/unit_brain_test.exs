defmodule Swarm.UnitBrainTest do
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{UnitBrain, View}

  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
  @wave %{id: 1, members: [2]}
  @attack %{@gather | mode: :attack, wave: @wave}

  defp decide(unit, strategy, others \\ [], memory \\ UnitBrain.new_memory()) do
    UnitBrain.decide(unit["id"], View.new(state(units: [unit | others])), strategy, memory)
  end

  defp cmd(unit, strategy, others \\ []), do: elem(decide(unit, strategy, others), 0)

  # Fighters at home, at the rally point.
  defp home_soldiers(n), do: for(i <- 1..n, do: unit(10 + i, "Soldier", 10, 10))

  test "an idle worker mines the nearest deposit" do
    assert %{"type" => "Gather", "unitIds" => [1], "targetId" => 4} = cmd(unit(1, "Worker", 8, 8), @gather)
  end

  describe "a worker picks its ore" do
    # Home ore by the Command Center at (7, 7), and a field 30 tiles away.
    @home %{"id" => 4, "x" => 2, "y" => 7, "remaining" => 900}
    @home2 %{"id" => 6, "x" => 1, "y" => 10, "remaining" => 900}
    @far %{"id" => 5, "x" => 40, "y" => 40, "remaining" => 900}

    defp pick(worker, deposits, others) do
      v = View.new(state(units: [worker | others], deposits: deposits))
      elem(UnitBrain.decide(worker["id"], v, @gather), 0)
    end

    defp miners(n, deposit), do: for(i <- 1..n, do: unit(100 + i, "Worker", 3, 7, activity: "Gathering", target_id: deposit))

    test "close ore, even crowded, beats an empty field far away" do
      assert %{"targetId" => 4} = pick(unit(1, "Worker", 8, 8), [@home, @far], miners(6, 4))
    end

    test "spreads to the next closest deposit once one has three" do
      assert %{"targetId" => 4} = pick(unit(1, "Worker", 8, 8), [@home, @home2, @far], miners(2, 4))
      assert %{"targetId" => 6} = pick(unit(1, "Worker", 8, 8), [@home, @home2, @far], miners(3, 4))
    end

    test "a worker mining far away comes back to close ore" do
      far_miner = unit(1, "Worker", 39, 40, activity: "Gathering", target_id: 5)
      assert %{"type" => "Gather", "targetId" => 4} = pick(far_miner, [@home, @far], [])
    end

    test "never to ore with an enemy fighter by it" do
      enemy = unit(900, "Soldier", 2, 3, owner: 1)
      assert %{"targetId" => 6} = pick(unit(1, "Worker", 8, 8), [@home, @home2], [enemy])
    end

    test "a miner whose ore turns unsafe moves to safe ore" do
      enemy = unit(900, "Soldier", 2, 3, owner: 1)
      miner = unit(1, "Worker", 8, 8, activity: "Gathering", target_id: 4)
      assert %{"type" => "Gather", "targetId" => 6} = pick(miner, [@home, @home2], [enemy])
    end

    test "with only unsafe ore, it waits" do
      enemy = unit(900, "Soldier", 2, 8, owner: 1)
      assert :no_change = pick(unit(1, "Worker", 8, 8), [@home, @home2], [enemy])
    end

    test "a worker mining close ore keeps at it" do
      assert :no_change = pick(unit(1, "Worker", 3, 7, activity: "Gathering", target_id: 4), [@home, @far], [])
    end
  end

  test "a busy worker keeps working" do
    assert :no_change = cmd(unit(1, "Worker", 8, 8, activity: "Gathering"), @gather)
  end

  test "an attacker waits at the rally point for the next wave" do
    # Unit 50 is the oldest of eight: an attacker, not a guard.
    attacker = unit(50, "Soldier", 20, 20)
    others = for i <- 1..7, do: unit(60 + i, "Soldier", 10, 10)
    assert %{"type" => "Move", "x" => 10, "y" => 10} = cmd(attacker, @gather, others)
    assert :no_change = cmd(%{attacker | "x" => 10, "y" => 11}, @gather, others)
  end

  test "a guard goes to the post" do
    assert %{"type" => "Move", "x" => 9, "y" => 9} = cmd(unit(2, "Soldier", 20, 20), @gather)
  end

  test "a wave member attack-moves to the target; the others stay" do
    assert %{"type" => "Attack", "x" => 56, "y" => 56} = cmd(unit(2, "Soldier", 20, 20), @attack)
    assert %{"type" => "Move"} = cmd(unit(3, "Soldier", 20, 20), @attack)
  end

  test "a unit waiting for the next wave fights an enemy that comes close" do
    enemy = unit(900, "Soldier", 13, 12, owner: 1)
    waiting = unit(3, "Soldier", 10, 10)
    assert %{"type" => "Attack", "targetId" => 900} = cmd(waiting, @attack, [enemy])
  end

  test "everyone at home goes to the threat" do
    defend = %{@gather | mode: :defend, threat: %{pos: {16, 9}, size: 1}}
    assert %{"type" => "Attack", "x" => 16, "y" => 9} = cmd(unit(2, "Soldier", 25, 25), defend)
  end

  test "the wave comes home when home can't hold, wherever it is" do
    s = %{@attack | threat: %{pos: {12, 9}, size: 10}}
    assert %{"type" => "Attack", "x" => 12, "y" => 9} = cmd(unit(2, "Soldier", 20, 20), s, home_soldiers(3))
    assert %{"type" => "Attack", "x" => 12, "y" => 9} = cmd(unit(2, "Soldier", 45, 45), s, home_soldiers(3))

    # Home can hold (a small raid): the wave keeps going.
    s = %{@attack | threat: %{pos: {12, 9}, size: 2}}
    assert %{"type" => "Attack", "x" => 56, "y" => 56} = cmd(unit(2, "Soldier", 45, 45), s, home_soldiers(3))
  end

  test "a unit already carrying out its order sends nothing" do
    moving = unit(2, "Soldier", 20, 20, activity: "Moving")
    {first, memory} = decide(moving, @attack)
    assert %{"type" => "Attack"} = first
    assert {:no_change, ^memory} = decide(moving, @attack, [], memory)
  end

  test "an idle soldier fights a nearby enemy first" do
    enemy = unit(900, "Worker", 22, 21, owner: 1)
    assert %{"type" => "Attack", "targetId" => 900} = cmd(unit(2, "Soldier", 20, 20), @attack, [enemy])
  end

  test "a wave member hitting a building turns on an archer shooting it" do
    hitting = unit(2, "Soldier", 40, 39, activity: "Attacking", target_id: 800)
    barracks = building(800, "Barracks", 40, 40, 1)
    archer = unit(900, "Archer", 43, 39, owner: 1)
    v = View.new(state(units: [hitting, archer], buildings: [barracks]))
    memory = %{intent: {:attack, 800}}
    assert {%{"type" => "Attack", "targetId" => 900}, _} = UnitBrain.decide(2, v, @attack, memory)
  end

  describe "outposts" do
    defp outpost_view(units) do
      miners = for i <- 1..6, do: unit(400 + i, "Worker", 31, 31, activity: "Gathering")
      View.new(state(units: units ++ miners, buildings: [building(50, "ResourceDepot", 30, 30)]))
    end

    # Ten soldiers: 208..210 guard, 206..207 escort the outpost, 201..205 attack.
    defp army, do: soldiers(10)

    test "an escort stands by its outpost, on the enemy's side" do
      assert {%{"type" => "Move", "x" => 32, "y" => 32}, _} = UnitBrain.decide(207, outpost_view(army()), @gather)
    end

    test "when an outpost is attacked, attackers go help and guards stay home" do
      enemy = unit(900, "Soldier", 36, 36, owner: 1)
      v = outpost_view([enemy | army()])
      assert {%{"type" => "Attack", "x" => 36, "y" => 36}, _} = UnitBrain.decide(201, v, @gather)
      # Already at its post: stays.
      assert {:no_change, _} = UnitBrain.decide(210, v, @gather)
    end
  end

  describe "workers out in the field" do
    defp field(units) do
      miner = unit(101, "Worker", 42, 40, activity: "Gathering")
      enemy = unit(900, "Soldier", 40, 40, owner: 1)
      View.new(state(units: [miner, enemy | units]))
    end

    test "attackers go help them; guards stay home" do
      v = field(soldiers(10))
      assert {%{"type" => "Attack", "x" => 40, "y" => 40}, _} = UnitBrain.decide(201, v, @gather)
      assert {:no_change, _} = UnitBrain.decide(210, v, @gather)
    end

    test "a miner about to be hit runs to the closest help that isn't toward the enemy" do
      miner = unit(101, "Worker", 40, 40, activity: "Gathering")
      enemy = unit(900, "Soldier", 41, 40, owner: 1)

      # Nobody near: the closest drop-off, the Command Center.
      v = View.new(state(units: [miner, enemy]))
      assert {%{"type" => "Move", "x" => 7, "y" => 7}, _} = UnitBrain.decide(101, v, @gather)

      # One of our soldiers close by, on the far side from the enemy: there.
      v = View.new(state(units: [miner, enemy, unit(201, "Soldier", 36, 40)]))
      assert {%{"type" => "Move", "x" => 36, "y" => 40}, _} = UnitBrain.decide(101, v, @gather)

      # Not to a soldier on the enemy's side.
      v = View.new(state(units: [miner, enemy, unit(201, "Soldier", 44, 40)]))
      assert {%{"type" => "Move", "x" => 7, "y" => 7}, _} = UnitBrain.decide(101, v, @gather)
    end

    test "a builder keeps building" do
      v = View.new(state(units: [unit(101, "Worker", 40, 40, activity: "Building"), unit(900, "Soldier", 41, 40, owner: 1)]))
      assert {:no_change, _} = UnitBrain.decide(101, v, @gather)
    end
  end

  test "a Trebuchet holds the guard post and isn't a guard or attacker" do
    treb = unit(300, "Trebuchet", 20, 20)
    v = View.new(state(units: [treb | soldiers(10)]))
    assert Swarm.Roles.role(v, nil, 300) == :siege
    refute Map.has_key?(Swarm.Roles.home_roles(v, nil), 300)
    assert {%{"type" => "Move", "x" => 9, "y" => 9}, _} = UnitBrain.decide(300, v, @attack)
  end

  describe "archers kite" do
    defp archer_decides(archer, others),
      do: elem(UnitBrain.decide(archer["id"], View.new(state(units: [archer | others])), @gather), 0)

    test "a soldier about to reach an archer: it steps back toward home" do
      soldier = unit(900, "Soldier", 32, 32, owner: 1)
      assert %{"type" => "Move", "x" => 27, "y" => 27} = archer_decides(unit(2, "Archer", 30, 30), [soldier])
    end

    test "with the soldier still out of reach, it shoots" do
      soldier = unit(900, "Soldier", 34, 30, owner: 1)
      assert %{"type" => "Attack", "targetId" => 900} = archer_decides(unit(2, "Archer", 30, 30), [soldier])
    end

    test "outnumbered, it backs off sooner" do
      enemies = for i <- 0..2, do: unit(900 + i, "Soldier", 33, 30 + i, owner: 1)
      assert %{"type" => "Move"} = archer_decides(unit(2, "Archer", 30, 30), enemies)

      # Same three, but five of our soldiers with it: it holds.
      friends = for i <- 1..5, do: unit(200 + i, "Soldier", 31, 28 + i)
      assert %{"type" => "Attack"} = archer_decides(unit(2, "Archer", 30, 30), enemies ++ friends)
    end

    test "with the enemy between it and home, it goes around, never closer" do
      soldier = unit(900, "Soldier", 28, 28, owner: 1)
      assert %{"type" => "Move", "x" => x, "y" => y} = archer_decides(unit(2, "Archer", 30, 30), [soldier])
      assert View.dist({x, y}, {28, 28}) > 2
    end

    test "at home, it stands and fights" do
      soldier = unit(900, "Soldier", 12, 11, owner: 1)
      assert %{"type" => "Attack", "targetId" => 900} = archer_decides(unit(2, "Archer", 11, 11), [soldier])
    end

    test "enemy archers don't make it run" do
      enemy = unit(900, "Archer", 32, 30, owner: 1)
      assert %{"type" => "Attack"} = archer_decides(unit(2, "Archer", 30, 30), [enemy])
    end
  end

  describe "shells" do
    defp under_fire(unit, shells) do
      shells = for {x, y} <- shells, do: %{"owner" => 1, "x" => x, "y" => y, "firedTick" => 99, "landsTick" => 102}
      View.new(Map.put(state(units: [unit], tick: 100), "shells", shells))
    end

    test "a unit standing where a shell will land steps aside" do
      v = under_fire(unit(2, "Soldier", 20, 20, activity: "Attacking"), [{20, 20}])
      assert {%{"type" => "Move", "x" => 21, "y" => 20}, %{intent: {:move, {21, 20}}}} = UnitBrain.decide(2, v, @gather)
    end

    test "and not onto another landing tile" do
      v = under_fire(unit(2, "Soldier", 20, 20), [{20, 20}, {21, 20}])
      assert {%{"x" => 19, "y" => 20}, _} = UnitBrain.decide(2, v, @gather)
    end

    test "workers dodge too" do
      v = under_fire(unit(101, "Worker", 3, 7, activity: "Gathering"), [{3, 7}])
      assert {%{"type" => "Move", "x" => 4, "y" => 7}, _} = UnitBrain.decide(101, v, @gather)
    end

    test "a unit on the move is gone before it lands" do
      v = under_fire(unit(2, "Soldier", 20, 20, activity: "Moving"), [{20, 20}])
      refute match?({%{"x" => 21}, _}, UnitBrain.decide(2, v, @gather))
    end

    test "our own shells don't scare us" do
      mine = [%{"owner" => 0, "x" => 20, "y" => 20, "firedTick" => 99, "landsTick" => 102}]
      v = View.new(Map.put(state(units: [unit(2, "Soldier", 20, 20)], tick: 100), "shells", mine))
      refute match?({%{"x" => 21, "y" => 20}, _}, UnitBrain.decide(2, v, @gather))
    end
  end

  test "a scout heads for the enemy base first" do
    assert %{"type" => "Move", "x" => 56, "y" => 56} = cmd(unit(5, "Scout", 10, 10), @gather)
  end

  test "a scout runs from enemy fighters" do
    enemy = unit(900, "Soldier", 33, 30, owner: 1)
    assert %{"type" => "Move", "x" => 24, "y" => 30} = cmd(unit(5, "Scout", 30, 30), @gather, [enemy])
  end

  test "a scout gets close to soldiers but keeps its distance from archers" do
    soldier = unit(900, "Soldier", 34, 30, owner: 1)
    assert %{"x" => 56, "y" => 56} = cmd(unit(5, "Scout", 30, 30), @gather, [soldier])

    archer = unit(900, "Archer", 35, 30, owner: 1)
    assert %{"x" => 24, "y" => 30} = cmd(unit(5, "Scout", 30, 30), @gather, [archer])
  end

  test "a scout runs when it is taking damage" do
    scout = Map.put(unit(5, "Scout", 30, 30), "hp", 40)
    soldier = unit(900, "Soldier", 36, 30, owner: 1)
    assert {%{"x" => 24, "y" => 30}, _} = decide(scout, @gather, [soldier], %{intent: nil, hp: 55})
  end

  test "after running, a scout checks somewhere else before coming back" do
    {%{"x" => 44, "y" => 44}, memory} = decide(unit(5, "Scout", 50, 50), @gather, [unit(900, "Soldier", 52, 52, owner: 1)])
    {%{"x" => x, "y" => y}, _} = decide(unit(5, "Scout", 44, 44, activity: "Moving"), @gather, [], memory)
    refute {x, y} == {56, 56}
  end

  test "scouts share out the map: two scouts head for different enemy bases" do
    scouts = [unit(5, "Scout", 10, 10), unit(6, "Scout", 10, 10)]

    three = Map.update!(state(units: scouts), "players", fn ps ->
      ps ++ [%{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 7}}]
    end)

    v = View.new(three)
    {%{"x" => x5, "y" => y5}, _} = UnitBrain.decide(5, v, @gather)
    {%{"x" => x6, "y" => y6}, _} = UnitBrain.decide(6, v, @gather)
    assert Enum.sort([{x5, y5}, {x6, y6}]) == [{56, 7}, {56, 56}]
  end

  describe "scouts watch the neighbors" do
    # Us at (7, 7). Neighbors at (56, 7) and (7, 56); across the map at (56, 56).
    defp four_scouts(scouts) do
      View.new(
        Map.update!(state(units: scouts), "players", fn [me | _] ->
          [me | for({slot, x, y} <- [{1, 56, 7}, {2, 7, 56}, {3, 56, 56}], do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}})]
        end)
      )
    end

    defp goal(v, id), do: UnitBrain.decide(id, v, @gather) |> elem(0) |> then(&{&1["x"], &1["y"]})

    test "one scout per neighbor, and the third roams" do
      v = four_scouts(for id <- [5, 6, 7], do: unit(id, "Scout", 10, 10))
      assert goal(v, 5) == {56, 7}
      assert goal(v, 6) == {7, 56}
      # The roamer: the far player's start is fair game for it.
      assert goal(v, 7) in [{56, 7}, {7, 56}, {56, 56}]
    end

    test "having seen the neighbor's start, its scout checks near them or the way to us" do
      # Standing by their start: it counts as seen, so the scout picks its next spot.
      v = four_scouts([unit(5, "Scout", 54, 7)])
      assert {%{"x" => x, "y" => y}, _} = UnitBrain.decide(5, v, @gather)
      assert View.dist({x, y}, {56, 7}) <= 16 or {x, y} == {31, 7}
    end

    test "with one scout, a neighbor comes first" do
      v = four_scouts([unit(5, "Scout", 10, 10)])
      assert goal(v, 5) == {56, 7}
    end
  end

  test "a scout gives up on a spot it can't reach and picks another" do
    stuck = unit(5, "Scout", 40, 40)
    {_, memory} = decide(stuck, @gather, [], %{intent: {:move, {56, 56}}})
    {%{"x" => x, "y" => y}, _} = decide(stuck, @gather, [], %{memory | intent: {:move, {56, 56}}})
    refute {x, y} == {56, 56}
  end

  test "a unit that is no longer ours does nothing" do
    assert {:no_change, _} = UnitBrain.decide(12345, View.new(state()), @attack)
  end
end
