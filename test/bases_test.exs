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
  # One of ours standing by that field: a base only goes where we have seen the ground lately.
  @seeing unit(300, "Scout", 18, 8)
  # A base only goes up with an army to hold it: twelve fighters.
  defp army, do: soldiers(12)
  @home_depot building(3, "ResourceDepot", 4, 9)

  # A third player, eliminated, who started at (7, 50), with its ore by (7, 53).
  defp with_fallen(state) do
    Map.update!(state, "players", &(&1 ++ [%{"slot" => 2, "eliminated" => true, "startPosition" => %{"x" => 7, "y" => 50}}]))
  end

  @their_ore for {id, x} <- [{50, 6}, {51, 7}, {52, 8}], do: %{"id" => id, "x" => x, "y" => 53, "remaining" => 1000}

  describe "a base Command Center" do
    test "at 16 workers, with a Barracks up, by a field with 2,500 ore or more: three builders, and it is a base" do
      opts = [buildings: [@barracks, @home_depot], deposits: [@home_ore | @field], ore: 1200]
      assert {_, commands, _} = plan(state([units: [@seeing | workers(15) ++ army()]] ++ opts))
      assert ccs(commands) == []

      {strategy, commands, memory} = plan(state([units: [@seeing | workers(16) ++ army()]] ++ opts))
      assert [%{"unitIds" => [_, _, _], "x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {20, 7}) in 2..3
      assert memory.bases == [{x, y}]
      assert %{site: {^x, ^y}, builders: [_, _, _], at: 100} = memory.base_order
      assert Enum.any?(strategy.why, &match?({:base, _}, &1))
    end

    test "only where we have seen the ground lately: until then the scout goes to look" do
      opts = [buildings: [@barracks, @home_depot], deposits: [@home_ore | @field], ore: 1200]
      home_scout = unit(300, "Scout", 9, 9)
      {strategy, commands, _} = plan(state([units: [home_scout | workers(16) ++ army()]] ++ opts))
      assert ccs(commands) == []
      assert strategy.survey == {20, 7}
    end

    test "not without an army to hold it: twelve fighters, and theirs not the bigger one" do
      opts = [buildings: [@barracks, @home_depot], deposits: [@home_ore | @field], ore: 1200]
      assert {_, commands, _} = plan(state([units: [@seeing | workers(16) ++ soldiers(11)]] ++ opts))
      assert ccs(commands) == []

      # Twelve of ours, twenty of theirs counted lately: no base into that.
      outnumbered = %{Brain.new_memory() | army_seen: %{1 => {20 * 990.0, 90}}}
      assert {_, commands, _} = plan(state([units: [@seeing | workers(16) ++ soldiers(12)]] ++ opts), outnumbered)
      assert ccs(commands) == []
    end

    test "it has its own order: the rest of the building goes on while its builders walk, its 400 held" do
      opts = [buildings: [@barracks, @home_depot], deposits: [@home_ore | @field]]
      builds = fn commands -> for %{"type" => "Build", "buildingType" => t} <- commands, do: t end

      # Ordered with 1200: the TechLab (next in the build order) is ordered the same tick.
      {_, commands, memory} = plan(state([units: [@seeing | workers(16) ++ army()], ore: 1200] ++ opts))
      assert Enum.sort(builds.(commands)) == ["CommandCenter", "TechLab"]

      # Its builders walking: 400 of the bank is theirs. With 450 (and 100 for workers) nothing else is bought...
      walking = [@seeing | workers(16) ++ army()]
      {_, commands, memory2} = plan(state([units: walking, ore: 450, tick: 101] ++ opts), %{memory | pending: nil})
      assert builds.(commands) == [] and memory2.base_order != nil
      # ...and with 900 the building goes on, no second Command Center.
      {_, commands, _} = plan(state([units: walking, ore: 900, tick: 101] ++ opts), %{memory | pending: nil})
      assert builds.(commands) == ["TechLab"]
    end

    test "short of its 400, nothing is trained any later: each Barracks keeps one in its queue, not two" do
      # Three Barracks, the TechLab busy, both scouts alive: nothing else to buy but workers and fighters.
      lab = Map.put(building(6, "TechLab", 7, 12), "research", "Weapons1")
      barracks = fn queued -> for {id, y} <- [{2, 7}, {7, 3}, {8, 11}], do: %{building(id, "Barracks", 11, y) | "production" => queued} end
      scouts = [@seeing, unit(301, "Scout", 9, 9)]
      one = [%{"unitType" => "Soldier"}]

      fighters = fn workers, queued ->
        opts = [units: scouts ++ workers(workers) ++ army(), buildings: barracks.(queued) ++ [@home_depot, lab], deposits: [@home_ore | @field], ore: 495]
        {_, commands, memory} = plan(state(opts))
        assert memory.base_order == nil
        Enum.count(commands, &match?(%{"type" => "Produce", "unitType" => t} when t in ["Soldier", "Archer"], &1))
      end

      # A base wanted (16 workers, 12 fighters, the field seen), not yet affordable: an empty queue gets its one...
      # (495 ore pays for a worker and two Archers.)
      assert fighters.(16, []) == 2
      # ...and a queue with one in it waits. With no base wanted (15 workers) it would get a second.
      assert fighters.(16, one) == 0
      assert fighters.(15, one) == 2
    end

    test "given up, with a strike against the site, when its builders are dead or 150 ticks have passed" do
      order = %{site: {22, 5}, builders: [101, 102, 103], at: 100}
      memory = %{Brain.new_memory() | base_order: order, bases: [{22, 5}]}
      opts = [buildings: [@barracks, @home_depot], deposits: [@home_ore]]

      {_, _, kept} = plan(state([units: workers(5), tick: 200] ++ opts), memory)
      assert kept.base_order == order

      {_, _, late} = plan(state([units: workers(5), tick: 251] ++ opts), memory)
      assert late.base_order == nil and late.strikes[{22, 5}] == [251]

      {_, _, dead} = plan(state([units: Enum.drop(workers(8), 3), tick: 120] ++ opts), memory)
      assert dead.base_order == nil

      # Broken ground: done with, no strike.
      site = %{building(60, "CommandCenter", 22, 5) | "completed" => false}
      building_it = unit(101, "Worker", 22, 6, activity: "Building", target_id: 60)
      {_, _, up} = plan(state([units: [building_it | workers(5)], tick: 120, buildings: [@barracks, @home_depot, site], deposits: [@home_ore]]), memory)
      assert up.base_order == nil and up.strikes == %{}
    end

    test "not without a Barracks, not by a small field, and one at a time" do
      assert {_, commands, _} = plan(state(units: [@seeing | workers(16) ++ army()], buildings: [@home_depot], deposits: [@home_ore | @field], ore: 1200))
      assert ccs(commands) == []

      small = for d <- @field, do: %{d | "remaining" => 800}
      assert {_, commands, _} = plan(state(units: [@seeing | workers(16) ++ army()], buildings: [@barracks, @home_depot], deposits: [@home_ore | small], ore: 1200))
      assert ccs(commands) == []

      # One going up already: the third waits for it, 30 workers or not.
      site = %{building(60, "CommandCenter", 22, 5) | "completed" => false}
      more = for d <- @field, do: %{d | "id" => d["id"] + 10, "y" => d["y"] + 20}
      builder = unit(150, "Worker", 22, 6, activity: "Building", target_id: 60)
      seeing_more = unit(301, "Scout", 20, 26)
      assert {_, commands, _} = plan(state(units: [builder, seeing_more | workers(30)], buildings: [@barracks, @home_depot, site], deposits: [@home_ore | @field ++ more], ore: 1200))
      assert ccs(commands) == []
    end

    test "not by an enemy's start, a building of theirs, or their fighters we remember" do
      # (Wherever else one goes, by ore the mirrored map has: never by that field.)
      away_from = fn commands, spot -> Enum.all?(ccs(commands), &(View.dist({&1["x"], &1["y"]}, spot) > 10)) end
      by_start = for d <- @field, do: %{d | "x" => d["x"] + 28, "y" => d["y"] + 40}
      opts = [units: [unit(300, "Scout", 46, 46) | workers(16) ++ army()], ore: 1200]
      assert {_, commands, _} = plan(state(opts ++ [buildings: [@barracks, @home_depot], deposits: [@home_ore | by_start]]))
      assert away_from.(commands, {48, 47})

      tower = building(700, "GuardTower", 30, 7, 1)
      opts = [units: [@seeing | workers(16) ++ army()], ore: 1200]
      assert {_, commands, _} = plan(state(opts ++ [buildings: [@barracks, @home_depot, tower], deposits: [@home_ore | @field]]))
      assert away_from.(commands, {20, 7})

      raiders = for i <- 1..3, do: unit(900 + i, "Soldier", 26, 10, owner: 1)
      assert {_, commands, _} = plan(state([units: [@seeing | workers(16) ++ army() ++ raiders], ore: 1200, buildings: [@barracks, @home_depot], deposits: [@home_ore | @field]]))
      assert away_from.(commands, {20, 7})
    end
  end

  describe "ore we haven't seen, on a mirrored map" do
    # Five piles down the west edge by our base; the map has the same in every corner.
    @corner for y <- 5..9, do: %{"id" => 40 + y, "x" => 2, "y" => y, "remaining" => 1000}

    test "a free corner's ore, which nobody has seen: the scout goes to look, and the base goes there once it has" do
      built = [@barracks, @home_depot]
      {strategy, commands, _} = plan(state(units: [unit(300, "Scout", 9, 9) | workers(16) ++ army()], buildings: built, deposits: @corner, ore: 1200))
      assert ccs(commands) == []
      # The corner below ours (the piles at (2, 54..58)), not the enemy's at (61, 54..58).
      assert {2, y} = strategy.survey
      assert y in 54..58

      # There, it sees the ore the mirror promised.
      real = for d <- @corner, do: %{d | "id" => d["id"] + 100, "y" => 63 - d["y"]}
      {_, commands, memory} = plan(state(units: [unit(300, "Scout", 4, 55) | workers(16) ++ army()], buildings: built, deposits: @corner ++ real, ore: 1200))
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      assert x <= 5 and y in 51..61
      assert memory.bases == [{x, y}]
    end

    test "not once we have looked there and found none" do
      {_, _, memory} = plan(state(units: [unit(300, "Scout", 4, 56), unit(301, "Scout", 59, 7)], deposits: @corner))
      assert length(memory.no_ore) == 10
      {strategy, commands, _} = plan(state(units: [unit(300, "Scout", 9, 9) | workers(16) ++ army()], buildings: [@barracks, @home_depot], deposits: @corner, ore: 1200), memory)
      assert ccs(commands) == [] and strategy.survey not in [{2, 54}, {61, 5}]
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

    test "its field comes first: the scout goes to look, and back every 20 ticks; a base goes there only while it was seen clear lately" do
      opts = [buildings: [@barracks, @home_depot], deposits: [@home_ore | @their_ore ++ @field], ore: 1200]
      scout = unit(300, "Scout", 10, 10)
      by_their_ore = fn spot -> spot != nil and View.dist(spot, {7, 53}) <= 6 end

      # Never looked at: the scout goes, and no base goes up unseen.
      {strategy, commands, memory} = plan(fallen([units: [scout | workers(16) ++ army()], tick: 100] ++ opts))
      assert by_their_ore.(strategy.survey)
      assert ccs(commands) == []

      # The scout is there and sees it clear: the base goes by their ore.
      there = unit(300, "Scout", 5, 53)
      {_, commands, memory} = plan(fallen([units: [there | workers(16) ++ army()], tick: 130] ++ opts), memory)
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {7, 53}) <= 5

      # (Say that order came to nothing.) Ten ticks on the scout does other things; at twenty it goes back.
      memory = %{memory | pending: nil, bases: [], base_order: nil, survey: nil}
      {strategy, _, _} = plan(fallen([units: [scout | workers(16) ++ army()], tick: 140] ++ opts), memory)
      refute by_their_ore.(strategy.survey)
      {strategy, _, _} = plan(fallen([units: [scout | workers(16) ++ army()], tick: 150] ++ opts), memory)
      assert by_their_ore.(strategy.survey)

      # Not seen for 45 ticks: no base there until it has been.
      {_, commands, _} = plan(fallen([units: [scout | workers(16) ++ army()], tick: 180] ++ opts), memory)
      assert ccs(commands) == []
    end

    test "not clear: whoever took them out is still there" do
      opts = [buildings: [@barracks, @home_depot], deposits: [@home_ore | @their_ore], ore: 1200]
      killers = for i <- 1..4, do: unit(900 + i, "Soldier", 10, 50, owner: 1)
      {_, commands, _} = plan(fallen([units: [unit(300, "Scout", 5, 53) | workers(16) ++ army() ++ killers], tick: 130] ++ opts))
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
