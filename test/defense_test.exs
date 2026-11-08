defmodule Swarm.DefenseTest do
  @moduledoc """
  Holding home: archers counted at their worth, no wave leaving (or staying out) with an enemy army
  near home, sorties only at what we can see and only with who is home, workers by home first,
  falling back that doesn't flicker, and regrouping at the backup Command Center when the main base
  is overrun.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, UnitBrain, View}

  # Us at (7, 7), player 1 at (56, 56). The backup Command Center at (40, 8).
  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
  @backup building(19, "CommandCenter", 40, 8)

  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  # Enemy fighters as the brain remembers them.
  defp remembered(units, tick), do: Map.new(units, &{&1["id"], &1 |> Map.take(["id", "owner", "type", "x", "y"]) |> Map.put("seen", tick)})
  defp archers(n, x, y, owner \\ 1), do: for(i <- 1..n, do: unit(900 + i, "Archer", x, y, owner: owner))

  test "an archer counts at its cost: a Soldier and a quarter, not a third of one" do
    assert Roles.strength([unit(900, "Archer", 0, 0)]) == 1.25 * 990
  end

  describe "an enemy army near home" do
    # Twenty archers we saw 15 tiles from our Command Center: 24750, far more than the guards.
    defp army, do: archers(20, 22, 7)

    test "no wave leaves while it is there, even when it isn't the target's" do
      # Player 2's army; the wave would go at player 1, whom we know nothing about.
      memory = %{Brain.new_memory() | enemies: remembered(archers(20, 22, 7, 2), 95)}
      assert {%{wave: nil, hold: hold}, _, _} = plan([units: soldiers(30)], memory)
      assert hold =~ "army is near home"
    end

    test "a wave out comes home for it" do
      out = for s <- Enum.take(soldiers(20), 15), do: %{s | "x" => 45, "y" => 45}
      memory = %{Brain.new_memory() | wave: %{id: 1, members: Enum.map(out, & &1["id"]), released: true}, next_wave: 2}
      memory = %{memory | enemies: remembered(army(), 99)}
      assert {%{wave: nil, why: why}, _, _} = plan([units: out ++ Enum.drop(soldiers(20), 15)], memory)
      assert Enum.any?(why, &match?({:wave_recalled, "wave 1: player 1's army is near home" <> _}, &1))
    end

    test "not for one too small to matter" do
      memory = %{Brain.new_memory() | enemies: remembered(archers(2, 22, 7), 95)}
      assert {_, _, _} = result = plan([units: soldiers(30)], memory)
      refute match?({%{hold: "player 1's army" <> _}, _, _}, result)
    end
  end

  describe "sorties" do
    defp hit_tower, do: Map.put(building(40, "GuardTower", 14, 7), "hp", 300)
    defp was_whole, do: %{Brain.new_memory() | hp: %{40 => 500}}

    test "only with fighters at home: a wave walking back isn't sent into it" do
      treb = unit(901, "Trebuchet", 20, 12, owner: 1)
      away = for i <- 1..8, do: unit(300 + i, "Soldier", 50, 50)
      assert {%{wave: %{kind: :sortie, members: members}}, _, _} = plan([units: soldiers(8) ++ away ++ [treb], buildings: [hit_tower()]], was_whole())
      assert Enum.all?(members, &(&1 in 201..208))
    end
  end

  describe "workers" do
    @home_ore %{"id" => 4, "x" => 2, "y" => 7, "remaining" => 900}
    # A depot far out, 2 from fresh ore: the shorter walk, but away from home.
    @outpost building(50, "ResourceDepot", 30, 30)
    @outpost_ore %{"id" => 7, "x" => 32, "y" => 30, "remaining" => 900}

    defp pick(worker, others \\ [], deposits \\ [@home_ore, @outpost_ore]) do
      v = View.new(state(units: [worker | others], deposits: deposits, buildings: [@outpost]))
      elem(UnitBrain.decide(worker["id"], v, @gather), 0)
    end

    test "mine by home first, even with a shorter walk out at an outpost" do
      assert %{"type" => "Gather", "targetId" => 4} = pick(unit(1, "Worker", 8, 8))
    end

    test "a miner out at an outpost comes home while there is ore there" do
      assert %{"type" => "Gather", "targetId" => 4} = pick(unit(1, "Worker", 31, 30, activity: "Gathering", target_id: 7))
    end

    test "with home's ore unsafe, out to the outpost" do
      squatter = unit(900, "Soldier", 1, 4, owner: 1)
      assert %{"type" => "Gather", "targetId" => 7} = pick(unit(1, "Worker", 12, 12), [squatter])
    end
  end

  describe "falling back" do
    defp miners, do: for(i <- 1..4, do: unit(100 + i, "Worker", 25, 7, activity: "Gathering"))
    defp raid, do: for(i <- 1..5, do: unit(900 + i, "Soldier", 27, 7, owner: 1))

    test "holds a while after the raiders step out of sight, then lets go" do
      {s, _, memory} = plan(units: miners() ++ raid() ++ soldiers(2))
      assert s.fall_back

      {s, _, memory} = plan([units: miners() ++ soldiers(2), tick: 105], memory)
      assert s.fall_back
      refute Enum.any?(s.why, &match?({:fall_back, _}, &1))

      {s, _, _} = plan([units: miners() ++ soldiers(2), tick: 120], memory)
      refute s.fall_back
    end
  end

  describe "regrouping at the backup Command Center, in secret" do
    # A big raid inside the main base, three soldiers home.
    defp overrun, do: for(i <- 1..12, do: unit(900 + i, "Soldier", 9, 9, owner: 1))
    defp regrouping, do: Map.put(@gather, :regroup, {40, 8})
    defp at_backup(units, opts \\ []), do: %{View.new(state(Keyword.merge([units: units, buildings: [@backup]], opts))) | regroup: {40, 8}}

    test "when the main base is overrun: it says so" do
      {s, _, memory} = plan(units: overrun() ++ soldiers(3) ++ workers(5), buildings: [@backup])
      assert s.regroup == {40, 8}
      assert Enum.any?(s.why, &match?({:regroup, "main base overrun" <> _}, &1))

      {v, _} = Brain.see(View.new(state(units: workers(5), buildings: [@backup], tick: 101)), memory)
      assert v.regroup == {40, 8}
      # Still not a drop-off for everyone: nobody is led there.
      refute {40, 8} in View.drop_offs(v)
    end

    test "not without a backup Command Center" do
      assert {%{regroup: nil}, _, _} = plan(units: overrun() ++ soldiers(3))
    end

    test "not when home can meet them" do
      assert {%{regroup: nil}, _, _} = plan(units: overrun() ++ soldiers(20), buildings: [@backup])
    end

    test "no wave meanwhile; over a while after the base is clear" do
      {_, _, memory} = plan(units: overrun() ++ soldiers(3), buildings: [@backup])
      assert {%{wave: nil, hold: "regrouping" <> _}, _, memory} = plan([units: soldiers(30), buildings: [@backup], tick: 110], memory)
      assert {%{regroup: nil, why: why}, _, _} = plan([units: soldiers(30), buildings: [@backup], tick: 150], memory)
      assert Enum.any?(why, &match?({:regroup, "regroup over" <> _}, &1))
    end

    test "the backup trains two workers of its own, no more" do
      {_, _, memory} = plan(units: overrun() ++ soldiers(3), buildings: [@backup])
      backup_produce? = &match?(%{"type" => "Produce", "unitType" => "Worker", "buildingId" => 19}, &1)

      {_, commands, _} = plan([units: workers(20), buildings: [@backup], ore: 400, tick: 101], memory)
      assert Enum.count(commands, backup_produce?) == 1

      two = for i <- 1..2, do: unit(400 + i, "Worker", 41, 9)
      {_, commands, _} = plan([units: workers(20) ++ two, buildings: [@backup], ore: 400, tick: 102], memory)
      refute Enum.any?(commands, backup_produce?)
    end

    test "its workers mine by it" do
      ore = %{"id" => 30, "x" => 43, "y" => 8, "remaining" => 900}
      v = at_backup([unit(401, "Worker", 41, 9)], deposits: [@home_ore, ore])
      assert {%{"type" => "Gather", "targetId" => 30}, _} = UnitBrain.decide(401, v, regrouping())
    end

    test "attacked, one runs away from the enemy and never toward the backup" do
      miner = unit(401, "Worker", 44, 8, activity: "Returning", target_id: 30)
      enemy = unit(900, "Soldier", 48, 8, owner: 1)
      ore = %{"id" => 30, "x" => 45, "y" => 8, "remaining" => 900}
      v = at_backup([miner, enemy], deposits: [ore])
      assert {%{"type" => "Move", "x" => x, "y" => y}, _} = UnitBrain.decide(401, v, regrouping())
      assert View.dist({x, y}, {48, 8}) > View.dist({44, 8}, {48, 8})
      assert View.dist({x, y}, {40, 8}) >= View.dist({44, 8}, {40, 8})
    end

    test "nobody else goes there: home fighters and main-base workers carry on" do
      away = for s <- soldiers(8), do: %{s | "x" => 20, "y" => 20}
      assert {%{"type" => "Move", "x" => 10, "y" => 10}, _} = UnitBrain.decide(201, at_backup(away), regrouping())

      raid = for i <- 1..3, do: unit(900 + i, "Soldier", 13, 8, owner: 1)
      # Caught at (11, 8): it runs to the Command Center, as always, not to the backup.
      miner = unit(1, "Worker", 11, 8, activity: "Gathering", target_id: 4)
      assert {%{"type" => "Move", "x" => 7, "y" => 7}, _} = UnitBrain.decide(1, at_backup([miner | raid]), regrouping())
    end

    test "main-base workers never mine by a backup, regrouping or not" do
      squatter = unit(900, "Soldier", 1, 4, owner: 1)
      by_backup = %{"id" => 31, "x" => 42, "y" => 9, "remaining" => 900}
      v = View.new(state(units: [unit(1, "Worker", 12, 12), squatter], deposits: [@home_ore, by_backup], buildings: [@backup]))
      refute match?({%{"targetId" => 31}, _}, UnitBrain.decide(1, v, @gather))
    end
  end
end
