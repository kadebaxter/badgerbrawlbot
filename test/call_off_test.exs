defmodule Swarm.CallOffTest do
  @moduledoc """
  Calling fights off before they bleed us, sizing strikes against every tower there, escorts that
  don't die at their outpost, expanding before home runs dry, and rebuilding a lost depot once the
  enemy has gone.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, UnitBrain, View}

  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}

  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  describe "a wave is called off" do
    # Twelve out at (40, 40), the most it has had.
    defp out(n), do: for(i <- 1..n, do: unit(200 + i, "Soldier", 40, 40))

    defp wave_memory do
      wave = %{id: 1, members: Enum.to_list(201..212), released: true, owner: 1, peak: 12 * 990, at: 90}
      %{Brain.new_memory() | wave: wave, next_wave: 2}
    end

    test "once it has lost over a third of its strength, not when only a few are left" do
      # Seven of twelve left (58%): called off.
      assert {%{wave: nil, why: why}, _, _} = plan([units: out(7)], wave_memory())
      assert Enum.any?(why, &match?({:wave_recalled, "wave 1: lost 42% of its strength" <> _}, &1))
    end

    test "not for a scratch" do
      assert {%{wave: %{id: 1}}, _, _} = plan([units: out(10)], wave_memory())
    end

    test "reinforcements count toward the most it has had" do
      {_, _, memory} = plan([units: out(12)], %{wave_memory() | wave: %{wave_memory().wave | peak: 0}})
      assert memory.wave.peak == 12 * 990
    end
  end

  describe "strikes" do
    defp their_tower(id, x, y), do: building(id, "GuardTower", x, y, 1)

    test "are sized against every tower that covers the one they go for" do
      # Seventeen at home: ten attackers (9900). One tower (3960): go.
      assert {%{wave: %{kind: :strike}}, _, _} = plan(units: soldiers(17), buildings: [their_tower(800, 16, 12)])

      # Two more covering it (11880 in all): not enough.
      towers = [their_tower(800, 16, 12), their_tower(801, 18, 14), their_tower(802, 19, 11)]
      assert {%{wave: nil, hold: "strike at" <> _}, _, _} = plan(units: soldiers(17), buildings: towers)
    end

    test "are called off once they bleed" do
      tower = their_tower(800, 16, 12)
      {_, _, memory} = plan(units: soldiers(17), buildings: [tower])
      memory = %{memory | wave: Map.put(memory.wave, :peak, 10 * 990)}
      # Six of the ten left, by the tower.
      left = for s <- Enum.take(soldiers(17), 6), do: %{s | "x" => 15, "y" => 11}
      assert {%{why: why}, _, _} = plan([units: left ++ Enum.drop(soldiers(17), 10), buildings: [tower], tick: 101], memory)
      assert Enum.any?(why, &match?({:wave_recalled, "strike at player 1's tower at (16,12): lost" <> _}, &1))
    end
  end

  describe "escorts" do
    # An outpost at (30, 30) with miners: three escorts, after seven guards.
    defp depot, do: building(50, "ResourceDepot", 30, 30)
    defp miners, do: for(i <- 1..4, do: unit(400 + i, "Worker", 31, 31, activity: "Gathering"))
    defp escorts, do: for(i <- 1..3, do: unit(200 + i, "Soldier", 32, 32))
    defp guards, do: for(i <- 4..10, do: unit(200 + i, "Soldier", 10, 10))

    test "hold their outpost against a raid they can meet" do
      raid = [unit(900, "Soldier", 27, 30, owner: 1)]
      v = View.new(state(units: escorts() ++ guards() ++ miners() ++ raid, buildings: [depot()]))
      assert {:escort, {30, 30}} = Roles.role(v, nil, 201)
      assert Roles.escorts_hold?(v, nil, {30, 30}, {27, 30})
    end

    test "pull back from a stronger one, to the rally point" do
      raid = for i <- 1..6, do: unit(900 + i, "Archer", 25, 30, owner: 1)
      v = View.new(state(units: escorts() ++ guards() ++ miners() ++ raid, buildings: [depot()]))
      refute Roles.escorts_hold?(v, nil, {30, 30}, {25, 30})
      assert {%{"type" => "Move", "x" => 10, "y" => 10}, _} = UnitBrain.decide(201, v, @gather)
    end
  end

  describe "the economy" do
    test "home is short of ore at 3000 left, so the next depot is up before it runs out" do
      home = for {id, x, y} <- [{4, 2, 7}, {5, 2, 9}], do: %{"id" => id, "x" => x, "y" => y, "remaining" => 1400}
      {_, _, memory} = plan(units: workers(10), deposits: home, ore: 200, tick: 100)
      assert memory.ore_short_since == 100
    end

    @far_field for(i <- 0..2, do: %{"id" => 60 + i, "x" => 40 + i, "y" => 40, "remaining" => 900})
    defp far_miners, do: for(i <- 1..3, do: unit(100 + i, "Worker", 41, 41, activity: "Gathering", target_id: 60))
    defp depot_builds(commands), do: for(%{"type" => "Build", "buildingType" => "ResourceDepot"} = c <- commands, do: c)

    test "a lost depot is built again once no enemy is near the spot" do
      lost = %{Brain.new_memory() | lost: %{{42, 38} => 90}}
      assert [_] = depot_builds(elem(plan([units: far_miners(), deposits: @far_field, ore: 200], lost), 1))
    end

    test "not while enemies we know of are still by it" do
      # Out of our miners' sight (or we would forget it, seeing it gone), 7 from the spot.
      archer = %{"id" => 900, "owner" => 1, "type" => "Archer", "x" => 47, "y" => 34, "seen" => 95}
      lost = %{Brain.new_memory() | lost: %{{42, 38} => 90}, enemies: %{900 => archer}}
      assert [] = depot_builds(elem(plan([units: far_miners(), deposits: @far_field, ore: 200], lost), 1))
    end
  end
end
