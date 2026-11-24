defmodule Swarm.BasesTest do
  @moduledoc """
  Command Centers of our own by fields worth one: when and where they go (unseen corners of a
  mirrored map and eliminated players' starts included), what makes them bases rather than hidden
  backups, and the scout that keeps checking an eliminated player's start is clear.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, UnitBrain, View}

  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
  @barracks building(2, "Barracks", 11, 7)

  defp plan(state, memory \\ Brain.new_memory()) when is_map(state),
    do: Brain.plan(View.new(state), looked(memory, 1, state["tick"]), terrain())

  defp ccs(commands), do: for(%{"type" => "Build", "buildingType" => "CommandCenter"} = c <- commands, do: c)
  # Three piles of 1000, 13 tiles east of our Command Center at (7, 7).
  @field [%{"id" => 30, "x" => 20, "y" => 7, "remaining" => 1000}, %{"id" => 31, "x" => 21, "y" => 7, "remaining" => 1000},
          %{"id" => 32, "x" => 20, "y" => 8, "remaining" => 1000}]
  @home_ore %{"id" => 4, "x" => 2, "y" => 7, "remaining" => 900}

  # A third player, eliminated, who started at (7, 50), with its ore by (7, 53).
  defp with_fallen(state) do
    Map.update!(state, "players", &(&1 ++ [%{"slot" => 2, "eliminated" => true, "startPosition" => %{"x" => 7, "y" => 50}}]))
  end

  @their_ore for {id, x} <- [{50, 6}, {51, 7}, {52, 8}], do: %{"id" => id, "x" => x, "y" => 53, "remaining" => 1000}

  describe "a base Command Center" do
    test "at 16 workers, with a Barracks up, by a field with 2,500 ore or more: three builders, and it is a base" do
      opts = [buildings: [@barracks], deposits: [@home_ore | @field], ore: 1200]
      assert {_, commands, _} = plan(state([units: workers(15)] ++ opts))
      assert ccs(commands) == []

      {strategy, commands, memory} = plan(state([units: workers(16)] ++ opts))
      assert [%{"unitIds" => [_, _, _], "x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {20, 7}) in 2..3
      assert memory.bases == [{x, y}]
      assert Enum.any?(strategy.why, &match?({:base, _}, &1))
    end

    test "not without a Barracks, not by a small field, and one at a time" do
      assert {_, commands, _} = plan(state(units: workers(16), deposits: [@home_ore | @field], ore: 1200))
      assert ccs(commands) == []

      small = for d <- @field, do: %{d | "remaining" => 800}
      assert {_, commands, _} = plan(state(units: workers(16), buildings: [@barracks], deposits: [@home_ore | small], ore: 1200))
      assert ccs(commands) == []

      # One going up already: the third waits for it, 30 workers or not.
      site = %{building(60, "CommandCenter", 22, 5) | "completed" => false}
      more = for d <- @field, do: %{d | "id" => d["id"] + 10, "y" => d["y"] + 20}
      builder = unit(150, "Worker", 22, 6, activity: "Building", target_id: 60)
      assert {_, commands, _} = plan(state(units: [builder | workers(30)], buildings: [@barracks, site], deposits: [@home_ore | @field ++ more], ore: 1200))
      assert ccs(commands) == []
    end

    test "not by an enemy's start, a building of theirs, or their fighters we remember" do
      # (Wherever else one goes, by ore the mirrored map has: never by that field.)
      away_from = fn commands, spot -> Enum.all?(ccs(commands), &(View.dist({&1["x"], &1["y"]}, spot) > 10)) end
      by_start = for d <- @field, do: %{d | "x" => d["x"] + 28, "y" => d["y"] + 40}
      opts = [units: workers(16), ore: 1200]
      assert {_, commands, _} = plan(state(opts ++ [buildings: [@barracks], deposits: [@home_ore | by_start]]))
      assert away_from.(commands, {48, 47})

      tower = building(700, "GuardTower", 30, 7, 1)
      assert {_, commands, _} = plan(state(opts ++ [buildings: [@barracks, tower], deposits: [@home_ore | @field]]))
      assert away_from.(commands, {20, 7})

      raiders = for i <- 1..3, do: unit(900 + i, "Soldier", 26, 10, owner: 1)
      assert {_, commands, _} = plan(state([units: workers(16) ++ raiders, ore: 1200, buildings: [@barracks], deposits: [@home_ore | @field]]))
      assert away_from.(commands, {20, 7})
    end
  end

  describe "ore we haven't seen, on a mirrored map" do
    # Five piles down the west edge by our base; the map has the same in every corner.
    @corner for y <- 5..9, do: %{"id" => 40 + y, "x" => 2, "y" => y, "remaining" => 1000}

    test "the second Command Center goes to a free corner, by ore nobody has seen" do
      {_, commands, memory} = plan(state(units: workers(16), buildings: [@barracks], deposits: @corner, ore: 1200))
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      # The corner below ours (the piles at (2, 54..58)), not the enemy's at (61, 54..58).
      assert x <= 5 and y in 51..61
      assert memory.bases == [{x, y}]
    end

    test "not once we have looked there and found none" do
      {_, _, memory} = plan(state(units: [unit(300, "Scout", 4, 56), unit(301, "Scout", 59, 7)], deposits: @corner))
      assert length(memory.no_ore) == 10
      {_, commands, _} = plan(state(units: workers(16), buildings: [@barracks], deposits: @corner, ore: 1200), memory)
      assert ccs(commands) == []
    end

    test "not on a map with more than four players: no mirror there" do
      many = fn state ->
        Map.update!(state, "players", fn ps ->
          ps ++ for({{x, y}, slot} <- Enum.with_index([{56, 7}, {7, 56}, {32, 60}], 2), do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}})
        end)
      end

      {_, _, memory} = plan(many.(state(units: workers(16) ++ soldiers(15), buildings: [@barracks], deposits: @corner, ore: 1200)))
      assert memory.bases == []
    end
  end

  describe "an eliminated player's start" do
    defp fallen(opts), do: with_fallen(state(opts))

    test "what the server still remembers of their buildings is nothing to us" do
      ghost = %{"id" => 800, "owner" => 2, "type" => "GuardTower", "x" => 9, "y" => 52, "completed" => true, "hp" => 500}
      alive = %{ghost | "id" => 801, "owner" => 1, "x" => 50, "y" => 50}
      v = View.new(Map.put(fallen([]), "rememberedBuildings", [ghost, alive]))
      assert [%{"id" => 801}] = v.remembered
    end

    test "a scout goes to look, and back every 20 ticks; a base goes there only while it was seen clear lately" do
      opts = [buildings: [@barracks], deposits: [@home_ore | @their_ore ++ @field], ore: 1200]
      scout = unit(300, "Scout", 10, 10)

      # Never looked at: the scout goes, and the base goes by the other field meanwhile.
      {strategy, commands, memory} = plan(fallen([units: [scout | workers(16)], tick: 100] ++ opts))
      assert strategy.survey == {7, 50}
      assert [%{"x" => x}] = ccs(commands)
      assert x > 15

      # The scout is there and sees it clear: the base goes by their ore, first of all.
      there = unit(300, "Scout", 7, 48)
      {_, commands, memory} = plan(fallen([units: [there | workers(16)], tick: 130] ++ opts), %{memory | pending: nil, bases: []})
      assert memory.checked[{7, 50}] == 130
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {7, 53}) <= 4

      # Twenty ticks on it goes back to look again.
      memory = %{memory | pending: nil, bases: [], survey: nil}
      {strategy, _, _} = plan(fallen([units: [scout | workers(16)], tick: 140] ++ opts), memory)
      refute strategy.survey == {7, 50}
      {strategy, _, _} = plan(fallen([units: [scout | workers(16)], tick: 150] ++ opts), memory)
      assert strategy.survey == {7, 50}

      # Not seen for 45 ticks: no base there until it has been.
      {_, commands, _} = plan(fallen([units: [scout | workers(16)], tick: 180] ++ opts), memory)
      assert [%{"x" => x}] = ccs(commands)
      assert x > 15
    end

    test "not clear: whoever took them out is still there" do
      opts = [buildings: [@barracks], deposits: [@home_ore | @their_ore], ore: 1200]
      killers = for i <- 1..4, do: unit(900 + i, "Soldier", 10, 50, owner: 1)
      {_, commands, memory} = plan(fallen([units: [unit(300, "Scout", 7, 46) | workers(16) ++ killers], tick: 130] ++ opts))
      assert memory.checked[{7, 50}] == 130
      assert Enum.all?(ccs(commands), &(View.dist({&1["x"], &1["y"]}, {7, 53}) > 10))
    end
  end

  describe "what makes it a base" do
    @base building(60, "CommandCenter", 22, 5)
    defp base_view(opts), do: %{View.new(state(Keyword.merge([buildings: [@base], deposits: [@home_ore | @field]], opts))) | bases: [{22, 5}]}

    test "a drop-off and an outpost, not a hidden backup; without the mark it is a backup as before" do
      v = base_view([])
      assert {22, 5} in View.drop_offs(v)
      assert View.backups(v) == []
      assert {22, 5} in Roles.outposts(v)

      hidden = %{v | bases: []}
      refute {22, 5} in View.drop_offs(hidden)
      assert View.backups(hidden) == [{22, 5}]
      assert Roles.outposts(hidden) == []
    end

    test "the brain hands the mark to the view every unit gets" do
      {v, _} = Brain.see(View.new(state(buildings: [@base])), %{Brain.new_memory() | bases: [{22, 5}]})
      assert v.bases == [{22, 5}]
    end

    test "a worker trained there mines there, not across the map by the main one" do
      v = base_view(units: [unit(1, "Worker", 22, 6)])
      assert {%{"type" => "Gather", "targetId" => id}, _} = UnitBrain.decide(1, v, @gather)
      assert id in [30, 31, 32]

      # One at home still mines at home.
      v = base_view(units: [unit(1, "Worker", 8, 8)])
      assert {%{"type" => "Gather", "targetId" => 4}, _} = UnitBrain.decide(1, v, @gather)
    end

    test "both Command Centers train workers at once" do
      state = state(units: workers(18), buildings: [@barracks, @base, building(3, "ResourceDepot", 4, 9)], deposits: [@home_ore | @field], ore: 1200)
      {_, commands, _} = plan(state, %{Brain.new_memory() | bases: [{22, 5}]})
      assert [1, 60] == for(%{"type" => "Produce", "unitType" => "Worker", "buildingId" => id} <- commands, do: id) |> Enum.sort()

      # A hidden backup trains none.
      {_, commands, _} = plan(state)
      assert [1] == for(%{"type" => "Produce", "unitType" => "Worker", "buildingId" => id} <- commands, do: id)
    end

    test "it gets two towers, rich or not" do
      built = [@barracks, @base, building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 12, 12), building(6, "GuardTower", 24, 7)]
      # 300 ore: not rich. An outpost depot would have its one tower and wait.
      state = state(units: workers(12) ++ soldiers(8), buildings: built, deposits: [@home_ore | @field], ore: 300)
      {_, commands, _} = plan(state, %{Brain.new_memory() | bases: [{22, 5}]})
      assert [%{"x" => x, "y" => y}] = for(%{"type" => "Build", "buildingType" => "GuardTower"} = c <- commands, do: c)
      assert View.dist({x, y}, {22, 5}) <= 4
    end
  end
end
