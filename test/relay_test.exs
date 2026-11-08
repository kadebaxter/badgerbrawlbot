defmodule Swarm.RelayTest do
  @moduledoc """
  The tick goes to each node once and the node's relay hands it to its units, with the team-wide
  answers worked out once. They must be the same answers each unit would have worked out itself.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Roles, UnitBrain, View}

  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}

  # A busy tick: twenty of ours at home, an outpost with miners and escorts, a wave of six out,
  # and enemies near both.
  defp busy do
    home = for i <- 1..20, do: unit(200 + i, "Soldier", 10 + rem(i, 4), 10 + div(i, 4))
    out = for i <- 1..6, do: unit(300 + i, "Soldier", 40, 40)
    miners = for i <- 1..4, do: unit(400 + i, "Worker", 31, 31, activity: "Gathering")
    enemies = for(i <- 1..5, do: unit(900 + i, "Archer", 14, 16, owner: 1)) ++ for(i <- 1..4, do: unit(910 + i, "Soldier", 42, 41, owner: 1))
    v = View.new(state(units: home ++ out ++ miners ++ enemies, buildings: [building(50, "ResourceDepot", 30, 30), building(800, "GuardTower", 44, 44, 1)]))
    {v, %{@gather | mode: :attack, wave: %{id: 1, members: Enum.to_list(301..306)}}}
  end

  test "every unit decides the same with the shared answers as without them" do
    {v, strategy} = busy()
    shared = UnitBrain.prepare(v, strategy.wave)

    for u <- v.my_units do
      assert UnitBrain.decide(u["id"], shared, strategy) == UnitBrain.decide(u["id"], v, strategy),
             "unit #{u["id"]} decided differently"
    end
  end

  test "the same on a crowded tick: workers on home and outpost ore, a raid on them, towers both sides" do
    home_ore = for y <- 3..9, do: %{"id" => 60 + y, "x" => 2, "y" => y, "remaining" => 900}
    outpost_ore = for y <- 28..32, do: %{"id" => 80 + y, "x" => 33, "y" => y, "remaining" => 900}
    far_ore = [%{"id" => 120, "x" => 20, "y" => 22, "remaining" => 900, "seen" => 50}]

    home_miners = for i <- 1..12, do: unit(100 + i, "Worker", 3, 4 + rem(i, 5), activity: "Gathering", target_id: 63 + rem(i, 4))
    out_miners = for i <- 1..8, do: unit(120 + i, "Worker", 32, 29 + rem(i, 3), activity: "Gathering", target_id: 108 + rem(i, 3))
    idle = [unit(140, "Worker", 8, 8)]
    home = for i <- 1..24, do: unit(200 + i, "Soldier", 9 + rem(i, 5), 9 + div(i, 5))
    archers = for i <- 1..6, do: unit(230 + i, "Archer", 12, 12)
    wave = for i <- 1..10, do: unit(300 + i, "Soldier", 44, 44)
    extras = [unit(320, "Scout", 20, 20), unit(321, "Trebuchet", 11, 11)]

    raid = for i <- 1..6, do: unit(900 + i, "Archer", 36, 30, owner: 1)
    pokers = for i <- 1..3, do: unit(910 + i, "Soldier", 15, 15, owner: 1)
    by_wave = for i <- 1..5, do: unit(920 + i, "Soldier", 46, 45, owner: 1)

    buildings = [
      building(50, "ResourceDepot", 31, 30),
      building(51, "GuardTower", 12, 10),
      building(52, "GuardTower", 30, 32),
      building(800, "GuardTower", 47, 47, 1),
      building(801, "Barracks", 50, 48, 1)
    ]

    units = home_miners ++ out_miners ++ idle ++ home ++ archers ++ wave ++ extras ++ raid ++ pokers ++ by_wave
    v = View.new(state(units: units, buildings: buildings, deposits: home_ore ++ outpost_ore ++ far_ore))
    v = %{v | remembered: [%{"id" => 802, "owner" => 1, "type" => "GuardTower", "x" => 40, "y" => 36, "hp" => 500, "completed" => true}]}

    for strategy <- [
          %{@gather | mode: :attack, wave: %{id: 1, members: Enum.to_list(301..310)}},
          Map.merge(@gather, %{mode: :defend, threat: %{pos: {15, 15}, size: 3}, fall_back: true}),
          @gather
        ] do
      prepared = UnitBrain.prepare(v, strategy.wave)

      for u <- v.my_units do
        assert UnitBrain.decide(u["id"], prepared, strategy) == UnitBrain.decide(u["id"], v, strategy),
               "unit #{u["id"]} (#{u["type"]}) decided differently in #{strategy.mode}"
      end
    end
  end

  test "answers worked out for another wave aren't used" do
    {v, strategy} = busy()
    stale = Roles.share(v, nil)
    assert Roles.assignments(stale, strategy.wave) == Roles.assignments(v, strategy.wave)
    assert Roles.home_roles(stale, strategy.wave) == Roles.home_roles(v, strategy.wave)
  end

  test "the relay hands its units the tick, with the answers in the view" do
    {v, strategy} = busy()
    ref = make_ref()
    me = self()
    units = for _ <- 1..3, do: spawn(fn -> receive(do: (msg -> send(me, {:got, self(), msg}))) end)

    assert {:noreply, nil} = Swarm.Relay.handle_info({:tick, ref, me, v, strategy, units}, nil)

    for pid <- units do
      assert_receive {:got, ^pid, {:tick, ^ref, ^me, %View{shared: %{wave: wave}}, ^strategy}}
      assert wave == strategy.wave
    end
  end
end
