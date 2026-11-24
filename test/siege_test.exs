defmodule Swarm.SiegeTest do
  @moduledoc """
  Trebuchets out with a wave shell the towers by the target, by name, while the rest of the wave
  holds; and how many of them we keep.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  defp plan(opts, memory),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  defp decide(unit, v, strategy), do: elem(UnitBrain.decide(unit["id"], v, strategy), 0)

  describe "Trebuchets out with a wave" do
    @towers [building(710, "GuardTower", 52, 50, 1), building(711, "GuardTower", 54, 48, 1)]
    @siege %{mode: :attack, target: {50, 50}, rally: {10, 10}, post: {9, 9}, threat: nil,
             wave: %{id: 1, members: [201, 301], released: false, staging: {42, 42}, at: 100, sieging: 130}}

    defp siege_view(extra, at \\ {42, 42}) do
      {x, y} = at
      View.new(state(units: [unit(201, "Soldier", x, y), unit(301, "Trebuchet", x, y)] ++ extra, buildings: @towers))
    end

    test "shell the nearest tower by name, not whatever is closest" do
      worker = unit(950, "Worker", 46, 46, owner: 1)
      assert %{"type" => "Attack", "targetId" => 710} = decide(unit(301, "Trebuchet", 42, 42), siege_view([worker]), @siege)
    end

    test "the rest of the wave holds at the staging point meanwhile" do
      assert %{"type" => "Attack", "x" => 42, "y" => 42} = decide(unit(201, "Soldier", 36, 36), siege_view([], {36, 36}), @siege)
    end

    test "a tower in the fog: they walk to a tile they see it from themselves, outside every tower's reach, exactly" do
      fogged = for t <- @towers, do: t |> Map.take(["id", "owner", "type", "x", "y", "completed"]) |> Map.put("hp", 500)
      fog_view = fn x, y -> %{View.new(state(units: [unit(301, "Trebuchet", x, y)])) | remembered: fogged} end

      assert %{"type" => "Move", "x" => x, "y" => y} = decide(unit(301, "Trebuchet", 40, 40), fog_view.(40, 40), @siege)
      # Six off the nearest tower (52, 50), inside a Trebuchet's sight of 7 (a circle) and its reach.
      assert View.dist({x, y}, {52, 50}) == 6
      assert (x - 52) ** 2 + (y - 50) ** 2 <= 45
      assert Enum.all?(@towers, &(View.dist({x, y}, {&1["x"], &1["y"]}) > 5))

      # Two tiles short of that tile is not there: it keeps walking (they stood idle 200 ticks once).
      assert %{"type" => "Move", "x" => ^x, "y" => ^y} = decide(unit(301, "Trebuchet", x - 2, y), fog_view.(x - 2, y), @siege)
      # On it and the tower still unseen (it can't be, from there): it stays put.
      assert :no_change = decide(unit(301, "Trebuchet", x, y), fog_view.(x, y), @siege)
    end

    test "still walking to the staging point, they keep walking" do
      walking = %{@siege | wave: Map.delete(@siege.wave, :sieging)}
      assert %{"type" => "Move", "x" => 42, "y" => 42} = decide(unit(301, "Trebuchet", 20, 20), siege_view([], {20, 20}), walking)
    end

    test "in place with towers by the target: shelling starts and the wave stays held; towers down, it goes in" do
      wave = %{id: 1, members: Enum.to_list(201..206) ++ [301], owner: 1, staging: {42, 42}, released: false, at: 100}
      units = [unit(301, "Trebuchet", 42, 42) | for(i <- 1..6, do: unit(200 + i, "Soldier", 42, 42))]
      memory = %{Brain.new_memory() | wave: wave, next_wave: 2}
      # Two Command Centers of theirs: neither is the last one we would spare.
      cc = building(720, "Barracks", 50, 50, 1)

      {strategy, _, memory} = plan([units: units, buildings: [cc | @towers], tick: 120], memory)
      assert %{wave: %{released: false, sieging: 120}} = strategy
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :wave_released and text =~ "shelling 2 tower(s)" end)

      {strategy, _, _} = plan([units: units, buildings: [cc], tick: 160], memory)
      assert %{wave: %{released: true}} = strategy
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :wave_released and text =~ "are down" end)
    end

    test "no tower down in 90 ticks: everyone goes in; one down starts the count again" do
      wave = %{id: 1, members: Enum.to_list(201..206) ++ [301], owner: 1, staging: {42, 42}, released: false, at: 100, sieging: 120}
      units = [unit(301, "Trebuchet", 42, 42) | for(i <- 1..6, do: unit(200 + i, "Soldier", 42, 42))]
      memory = %{Brain.new_memory() | wave: wave, next_wave: 2}
      other = building(720, "Barracks", 50, 50, 1)

      {%{wave: %{released: false}}, _, held} = plan([units: units, buildings: [other | @towers], tick: 200], memory)
      {strategy, _, _} = plan([units: units, buildings: [other | @towers], tick: 210], held)
      assert %{wave: %{released: true}} = strategy
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :wave_released and text =~ "no tower down in 90 ticks" end)

      # One of the two fell at tick 200: still shelling at 210, and until 290.
      {%{wave: %{released: false}}, _, held} = plan([units: units, buildings: [other, hd(@towers)], tick: 200], held)
      assert {%{wave: %{released: false}}, _, _} = plan([units: units, buildings: [other, hd(@towers)], tick: 289], held)
      assert {%{wave: %{released: true}}, _, _} = plan([units: units, buildings: [other, hd(@towers)], tick: 290], held)
    end
  end

  describe "how many Trebuchets" do
    defp trains(towers) do
      built = [
        building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 12, 12),
        building(6, "TechLab", 7, 12), building(7, "Barracks", 12, 3), building(8, "GuardTower", 14, 9),
        building(9, "CommandCenter", 40, 4), building(10, "SiegeWorkshop", 3, 12),
        building(11, "Barracks", 1, 10), building(12, "Barracks", 10, 1)
      ]

      enemy = for i <- 1..towers, do: building(800 + i, "GuardTower", 44 + rem(i, 4) * 3, 50 + div(i, 4) * 3, 1)
      have = for i <- 1..2, do: unit(300 + i, "Trebuchet", 10, 10)
      state = state(units: workers(20) ++ soldiers(25) ++ have, buildings: built ++ enemy, ore: 2000)
      state = put_in(state, ["you", "upgrades"], ["SiegeEngineering"])
      {_, commands, _} = Brain.plan(View.new(state), looked(nil), terrain())
      Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Trebuchet"}, &1))
    end

    test "two as before; one for every two towers of theirs we know of beyond that" do
      refute trains(3)
      assert trains(6)
    end
  end
end
