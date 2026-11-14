defmodule Swarm.GroupFightTest do
  @moduledoc """
  Fights decided by group (`Swarm.Roles.groups/2`): every one of our fighters in a fight sees the
  same estimate of it (`Swarm.Fight.advantage/2`) and decides the same way, each for itself. And
  it is quick enough for a big game.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Fight, Roles, UnitBrain, View}

  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}

  defp soldier(delay), do: %{hp: 110, armor: 1, damage: 9, cooldown: 1, delay: delay, order: 0, value: 9}
  defp archer, do: %{hp: 60, armor: 0, damage: 12, cooldown: 2, delay: 0, order: 1, value: 20.6}

  describe "the estimate" do
    test "who hits first matters: together, Soldiers beat a stack of archers; one at a time, they all die" do
      archers = List.duplicate(archer(), 23)

      # 26 walking in together from just out of reach (5 ticks under fire).
      assert Fight.advantage(List.duplicate(soldier(5), 26), archers) > 0.3

      # The same 26 arriving one a tick.
      assert Fight.advantage(for(i <- 0..25, do: soldier(5 + i)), archers) < 0

      # Half as many, together: not enough.
      assert Fight.advantage(List.duplicate(soldier(5), 13), List.duplicate(archer(), 20)) < 0
    end

    test "even is even, and nobody is no fight" do
      assert Fight.advantage([soldier(0)], [soldier(0)]) == 0.0
      assert Fight.advantage([], [archer()]) == -1.0
      assert Fight.advantage([soldier(0)], []) == 1.0
    end
  end

  describe "the margin" do
    test "one already in stays in until it clearly turns, one not yet in waits for even" do
      g = %{ids: MapSet.new([900]), ready: -0.1, all: -0.1, gather: {20, 20}}
      fresh = unit(201, "Soldier", 30, 30)
      in_it = unit(202, "Soldier", 30, 30, activity: "Attacking", target_id: 900)

      assert Roles.verdict(g, in_it) == :go
      assert Roles.verdict(g, fresh) == :away

      # Clearly against us: out, both.
      g = %{g | ready: -0.3, all: -0.3}
      assert Roles.verdict(g, in_it) == :away
      assert Roles.verdict(g, fresh) == :away
    end

    test "one on its way to the gather spot keeps going while it is close" do
      g = %{ids: MapSet.new([900]), ready: -1.0, all: -0.1, gather: {20, 20}}
      walking = unit(201, "Soldier", 30, 30, activity: "Moving") |> Map.put("destination", %{"x" => 21, "y" => 20})
      assert Roles.verdict(g, walking) == :gather
      assert Roles.verdict(g, unit(202, "Soldier", 30, 30)) == :away
    end
  end

  describe "everyone in a fight sees the same one" do
    test "ours near a group, wherever they stand in it, get the same group and estimate" do
      archers = for i <- 1..6, do: unit(900 + i, "Archer", 30, 30 + rem(i, 3), owner: 1)
      ours = [unit(201, "Soldier", 25, 25), unit(202, "Soldier", 34, 36), unit(203, "Archer", 22, 30)]
      v = View.new(state(units: archers ++ ours))
      [a, b, c] = Enum.map(ours, &Roles.group_for(v, nil, &1))
      assert a == b and b == c
      assert a.size == 3
    end

    test "a raid by the workers: home attackers far away are in it too, guards only if near" do
      miners = for i <- 1..3, do: unit(100 + i, "Worker", 40, 10, activity: "Gathering")
      raid = for i <- 1..4, do: unit(900 + i, "Soldier", 42, 10, owner: 1)
      # Twelve at home: 201..205 attackers, the rest guards.
      v = View.new(state(units: miners ++ raid ++ soldiers(12)))
      assert Roles.group_for(v, nil, unit(201, "Soldier", 10, 10)).raid
      assert Roles.group_for(v, nil, unit(212, "Soldier", 10, 10)) == nil
    end
  end

  describe "workers" do
    @ore %{"id" => 8, "x" => 30, "y" => 26, "remaining" => 500}

    test "don't mine ore whose drop-off an enemy reaches" do
      # Ore 8 by our depot at (30, 30) (a walk of 7), ore 9 by the one at (22, 30) (9). Archers
      # south of the first depot, 12 from the ore itself: its miners would walk into them.
      ore = %{"id" => 8, "x" => 30, "y" => 23, "remaining" => 500}
      other = %{"id" => 9, "x" => 13, "y" => 24, "remaining" => 500}
      depots = [building(50, "ResourceDepot", 30, 30), building(51, "ResourceDepot", 22, 30)]
      archers = for i <- 1..3, do: unit(900 + i, "Archer", 30, 35, owner: 1)
      worker = unit(101, "Worker", 30, 20)
      v = View.new(state(units: [worker | archers], buildings: depots, deposits: [ore, other]))
      assert {%{"type" => "Gather", "targetId" => 9}, _} = UnitBrain.decide(101, UnitBrain.prepare(v, nil), @gather)

      # No archers: the nearer one.
      v = View.new(state(units: [worker], buildings: depots, deposits: [ore, other]))
      assert {%{"type" => "Gather", "targetId" => 8}, _} = UnitBrain.decide(101, UnitBrain.prepare(v, nil), @gather)
    end

    test "run from an archer two steps out of reach" do
      miner = unit(101, "Worker", 20, 20, activity: "Gathering", target_id: 8)
      archer = unit(900, "Archer", 26, 20, owner: 1)
      v = View.new(state(units: [miner, archer], deposits: [%{@ore | "x" => 19, "y" => 20}]))
      assert {%{"type" => "Move"}, _} = UnitBrain.decide(101, v, @gather)
    end

    test "with nothing safe to mine, wait by a drop-off no enemy reaches, not a tower one does" do
      tower = building(5, "GuardTower", 20, 12)
      depot = building(50, "ResourceDepot", 4, 14)
      archers = for i <- 1..3, do: unit(900 + i, "Archer", 22, 15, owner: 1)
      idle = unit(101, "Worker", 14, 12, activity: "Idle")
      v = View.new(state(units: [idle | archers], buildings: [tower, depot], deposits: [%{@ore | "x" => 21, "y" => 14}]))
      assert {%{"type" => "Move", "x" => x, "y" => y}, _} = UnitBrain.decide(101, v, @gather)
      assert {x, y} in [{7, 7}, {4, 14}]
    end
  end

  describe "the decision log" do
    test "says what each fight's call is, once, and again when it changes" do
      miners = for i <- 1..3, do: unit(100 + i, "Worker", 25, 7, activity: "Gathering")
      raid = for i <- 1..3, do: unit(900 + i, "Soldier", 27, 7, owner: 1)
      plan = fn units, memory -> Brain.plan(View.new(state(units: units)), looked(memory, 1, 100), terrain()) end

      {s, _, memory} = plan.(miners ++ raid ++ soldiers(12), Brain.new_memory())
      assert [{:fight, "raid at (27,7): 3 Soldier against 5 of ours, estimate +" <> rest}] = Enum.filter(s.why, &(elem(&1, 0) == :fight))
      assert rest =~ "gather at"

      # Same call next tick: nothing new.
      {s, _, memory} = plan.(miners ++ raid ++ soldiers(12), memory)
      assert Enum.filter(s.why, &(elem(&1, 0) == :fight)) == []

      # Gathered by it: they go in.
      gathered = for u <- Enum.take(soldiers(12), 5), do: %{u | "x" => 24, "y" => 8}
      {s, _, _} = plan.(miners ++ raid ++ gathered ++ Enum.drop(soldiers(12), 5), memory)
      assert [{:fight, line}] = Enum.filter(s.why, &(elem(&1, 0) == :fight))
      assert line =~ "go in"
    end
  end
end
