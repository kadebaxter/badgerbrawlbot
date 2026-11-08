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
    shared = Roles.share(v, strategy.wave)

    for u <- v.my_units do
      assert UnitBrain.decide(u["id"], shared, strategy) == UnitBrain.decide(u["id"], v, strategy),
             "unit #{u["id"]} decided differently"
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
