defmodule Swarm.PunishSiegeTest do
  @moduledoc """
  An opponent mining far from its start with few fighters is hit early, at its workers and clear
  of its towers; and Trebuchets out with a wave shell the towers by the target, by name, while the
  rest of the wave holds.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  # Us at (7, 7), the enemy started at (56, 56) and has a depot in the middle, 24 tiles from there.
  @depot building(700, "ResourceDepot", 32, 32, 1)
  @home_depot building(701, "ResourceDepot", 52, 52, 1)

  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  defp enemies(n), do: for(i <- 1..n, do: unit(900 + i, "Soldier", 33, 33, owner: 1))
  defp decide(unit, v, strategy), do: elem(UnitBrain.decide(unit["id"], v, strategy), 0)

  describe "a base out in the open" do
    test "the wave leaves with eight attackers, for that drop-off, towers or not" do
      tower = building(702, "GuardTower", 34, 30, 1)
      # 16 soldiers: 7 guards, 9 attackers. Without the exposed base it waits for 12.
      {%{wave: nil}, _, _} = plan(units: soldiers(16), buildings: [@home_depot, tower])

      {strategy, _, _} = plan(units: soldiers(16), buildings: [@depot, tower])
      assert %{wave: %{punish: true, members: members}, target: {32, 32}} = strategy
      assert length(members) == 9
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :wave_launched and text =~ "out in the open" end)
    end

    test "not against more fighters than 1.2 of them can take" do
      {_, _, memory} = plan(units: soldiers(16) ++ enemies(8), buildings: [@depot], tick: 99)
      # Eight remembered soldiers: nine attackers aren't 1.2 times that.
      assert {%{wave: nil}, _, _} = plan([units: soldiers(16), buildings: [@depot]], memory)
    end

    test "out there, their towers don't call it home; their fighters do" do
      wave = %{id: 1, members: Enum.to_list(201..208), owner: 1, staging: nil, released: true, at: 90, punish: true}
      out = for i <- 1..8, do: unit(200 + i, "Soldier", 27, 27)
      towers = for i <- 0..2, do: building(710 + i, "GuardTower", 32 + i, 30, 1)
      memory = %{Brain.new_memory() | wave: wave, next_wave: 2}

      assert {%{wave: %{punish: true}}, _, _} = plan([units: out, buildings: [@depot | towers]], memory)
      # The same wave, not punishing: three towers (and nothing else) are more than it.
      assert {%{wave: nil}, _, _} = plan([units: out, buildings: [@depot | towers]], %{memory | wave: %{wave | punish: false}})

      near = for i <- 1..9, do: unit(900 + i, "Soldier", 30, 30, owner: 1)
      assert {%{wave: nil}, _, _} = plan([units: out ++ near, buildings: [@depot | towers]], memory)
    end
  end

  describe "a punish wave member" do
    @tower building(702, "GuardTower", 34, 30, 1)
    @punish %{mode: :attack, target: {32, 32}, rally: {10, 10}, post: {9, 9}, threat: nil,
              wave: %{id: 1, members: [201], released: true, staging: nil, punish: true}}

    test "goes for a worker no tower covers" do
      worker = unit(950, "Worker", 22, 24, owner: 1)
      v = View.new(state(units: [unit(201, "Soldier", 20, 20), worker], buildings: [@tower]))
      assert %{"type" => "Attack", "targetId" => 950} = decide(unit(201, "Soldier", 20, 20), v, @punish)
    end

    test "not one under a tower: it holds short of a target in a tower's reach" do
      worker = unit(950, "Worker", 31, 31, owner: 1)
      v = View.new(state(units: [unit(201, "Soldier", 18, 18), worker], buildings: [@tower]))
      assert %{"type" => "Move", "x" => x, "y" => y} = decide(unit(201, "Soldier", 18, 18), v, @punish)
      assert View.dist({x, y}, {32, 32}) == 8
    end

    test "in a tower's reach, steps out of it" do
      v = View.new(state(units: [unit(201, "Soldier", 30, 30)], buildings: [@tower]))
      assert %{"type" => "Move", "x" => x, "y" => y} = decide(unit(201, "Soldier", 30, 30), v, @punish)
      assert View.dist({x, y}, {34, 30}) > 5
    end
  end

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

    test "a tower in the fog: they walk to seven tiles from it, never into its reach" do
      fogged = for t <- @towers, do: t |> Map.take(["id", "owner", "type", "x", "y", "completed"]) |> Map.put("hp", 500)
      v = %{View.new(state(units: [unit(301, "Trebuchet", 40, 40)])) | remembered: fogged}
      assert %{"type" => "Move", "x" => x, "y" => y} = decide(unit(301, "Trebuchet", 40, 40), v, @siege)
      assert View.dist({x, y}, {52, 50}) == 7
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
  end

  describe "how many Trebuchets" do
    defp trains(towers) do
      built = [
        building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 12, 12),
        building(6, "TechLab", 7, 12), building(7, "Barracks", 12, 3), building(8, "GuardTower", 14, 9),
        building(9, "CommandCenter", 40, 4), building(10, "SiegeWorkshop", 3, 12)
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
