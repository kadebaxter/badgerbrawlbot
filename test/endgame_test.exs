defmodule Swarm.EndgameTest do
  @moduledoc """
  Late in a match: a scout's look brings an old count of their army down; with no ore left the
  last Command Center isn't spared, no more workers are trained, and with no Scout alive an idle
  worker does the looking.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  defp plan(opts, memory),
    do: Brain.plan(View.new(state(opts)), memory, terrain())

  describe "a scout's look and the count we had" do
    # Twenty of theirs counted at tick 100; a look is under way at (49, 49).
    defp counted, do: %{Brain.new_memory() | army_seen: %{1 => {20 * 990.0, 100}}, look: %{owner: 1, pos: {49, 49}, at: 120, done: nil}}

    test "seeing fewer brings it down, to no less than half of it" do
      {_, _, memory} = plan([units: [unit(300, "Scout", 49, 49) | soldiers(10)], tick: 130], counted())
      assert memory.army_seen[1] == {10 * 990.0, 130}

      # Twelve of them standing there: twelve it is.
      there = for i <- 1..12, do: unit(900 + i, "Soldier", 52, 52, owner: 1)
      {_, _, memory} = plan([units: [unit(300, "Scout", 49, 49) | soldiers(10)] ++ there, tick: 130], counted())
      assert elem(memory.army_seen[1], 0) == 12 * 990.0
    end

    test "no look, no change" do
      {_, _, memory} = plan([units: [unit(300, "Scout", 20, 20) | soldiers(10)], tick: 130], counted())
      assert memory.army_seen[1] == {20 * 990.0, 100}
    end
  end

  describe "nothing left to mine" do
    @their_cc building(900, "CommandCenter", 56, 56, 1)
    @barracks building(2, "Barracks", 11, 7)
    @depot building(3, "ResourceDepot", 4, 9)
    @pile %{"id" => 4, "x" => 2, "y" => 7, "remaining" => 1000}

    # The state with what each player has banked so far (the server's `economy` score).
    defp banked(opts, mine, theirs) do
      Map.update!(state(opts), "players", fn [me, them | rest] ->
        [Map.put(me, "score", %{"economy" => mine, "total" => mine}), Map.put(them, "score", %{"economy" => theirs, "total" => theirs}) | rest]
      end)
    end

    defp plan_banked(opts, mine, theirs, memory),
      do: Brain.plan(View.new(banked(opts, mine, theirs)), looked(memory, 1, opts[:tick]), terrain())

    defp mining(n), do: workers(n)
    defp idle(n), do: for(i <- 1..n, do: unit(100 + i, "Worker", 8, 8))
    defp trains(commands), do: for(%{"type" => "Produce", "unitType" => t} <- commands, do: t)
    defp economy(strategy), do: for({:economy, text} <- strategy.why, do: text)

    test "the ore a map starts with: 72,000 with two to four players, 14,100 a player on a ring, scaled by our home piles" do
      {_, _, memory} = plan_banked([units: mining(5), deposits: [@pile], tick: 1], 0, 0, nil)
      assert memory.map_ore == 72_000

      ring = Map.update!(banked([units: mining(5), deposits: [@pile], tick: 1], 0, 0), "players", fn ps ->
        ps ++ for({{x, y}, slot} <- Enum.with_index([{56, 7}, {7, 56}, {32, 60}, {60, 32}], 2), do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}})
      end)
      {_, _, memory} = Brain.plan(View.new(ring), nil, terrain())
      assert memory.map_ore == 6 * 14_100

      # A match with twice the grubs: every pile is 2,000.
      {_, _, memory} = plan_banked([units: mining(5), deposits: [%{@pile | "remaining" => 2000}], tick: 1], 0, 0, nil)
      assert memory.map_ore == 144_000
    end

    test "for certain: everyone together has banked all but the dregs of it, whatever we can see" do
      memory = %{Brain.new_memory() | map_ore: 72_000, income_at: {40_000, 590}}
      opts = [units: mining(10) ++ soldiers(10), buildings: [@barracks, @depot], deposits: [@pile], ore: 500, tick: 600]

      # 70,000 of 72,000 banked: 2,000 may be left, more than the dregs. Workers as usual.
      {strategy, commands, _} = plan_banked(opts, 41_000, 29_000, memory)
      assert economy(strategy) == [] and "Worker" in trains(commands)

      # 71,000: under 2% left. No more workers, said once.
      {strategy, commands, memory} = plan_banked(opts, 42_000, 29_000, memory)
      assert [text] = economy(strategy)
      assert text =~ "the map is mined out: 72000 ore on it, 71000 banked by everyone"
      refute "Worker" in trains(commands)
      {strategy, _, _} = plan_banked(Keyword.put(opts, :tick, 601), 42_000, 29_000, memory)
      assert economy(strategy) == []
    end

    test "or we have banked nothing for 100 ticks with nobody mining, however much the count says is left" do
      memory = %{Brain.new_memory() | map_ore: 72_000, income_at: {30_000, 500}}
      opts = [buildings: [@barracks, @depot], deposits: [], ore: 500]

      # Ore mined and never banked still counts as left: 12,000 here, and none of it is there.
      {strategy, commands, _} = plan_banked([units: idle(10) ++ soldiers(10), tick: 600] ++ opts, 30_000, 30_000, memory)
      assert [text, search] = economy(strategy)
      assert text =~ "banked nothing for 100 ticks" and text =~ "at most 12000 left"
      assert search =~ "4 worker(s) go looking for ore"
      refute "Worker" in trains(commands)

      # Not at 99 ticks; not while anyone is mining; not with too few workers to tell (they are rebuilt).
      {strategy, _, _} = plan_banked([units: idle(10) ++ soldiers(10), tick: 599] ++ opts, 30_000, 30_000, memory)
      assert economy(strategy) == []
      {strategy, _, _} = plan_banked([units: mining(1) ++ tl(idle(10)) ++ soldiers(10), tick: 600] ++ opts, 30_000, 30_000, memory)
      assert economy(strategy) == []
      {strategy, commands, _} = plan_banked([units: idle(3) ++ soldiers(10), tick: 600] ++ opts, 30_000, 30_000, memory)
      assert economy(strategy) == [] and "Worker" in trains(commands)
    end

    test "banking again ends it; and never in the first 300 ticks" do
      stalled = %{Brain.new_memory() | map_ore: 72_000, income_at: {30_000, 500}, mined_out: true}
      opts = [units: mining(10) ++ soldiers(10), buildings: [@barracks, @depot], deposits: [@pile], ore: 500, tick: 700]
      {strategy, commands, memory} = plan_banked(opts, 30_010, 30_000, stalled)
      assert economy(strategy) == ["mining again: workers are trained as usual"]
      assert memory.income_at == {30_010, 700} and "Worker" in trains(commands)

      early = [units: idle(10), buildings: [@depot], deposits: [], ore: 500, tick: 250]
      {strategy, _, _} = plan_banked(early, 0, 0, %{Brain.new_memory() | map_ore: 72_000})
      assert economy(strategy) == []
    end

    test "their last Command Center isn't spared: there is nothing to go on mining" do
      memory = %{Brain.new_memory() | map_ore: 72_000, income_at: {42_000, 590}}
      opts = [units: idle(10) ++ soldiers(20), buildings: [@their_cc], deposits: [], tick: 600]
      {strategy, _, after_plan} = plan_banked(opts, 42_000, 29_500, memory)
      assert strategy.spare == nil
      assert %{id: 900} = after_plan.kill
      assert Enum.any?(strategy.why, &match?({:spare_lifted, "nothing left to mine" <> _}, &1))

      # Stalled only (the count says 12,000 may be left): it stays up while our workers look for that ore...
      stalled = %{Brain.new_memory() | map_ore: 72_000, income_at: {30_000, 450}}
      {strategy, _, searching} = plan_banked(opts, 30_000, 30_000, stalled)
      assert %{id: 900} = strategy.spare
      assert map_size(strategy.search) == 4
      # ...and comes down once they have looked everywhere and found none.
      {strategy, _, _} = plan_banked(opts, 30_000, 30_000, %{searching | search_done: true})
      assert strategy.spare == nil
      # Never while they still have more than that Command Center: we may just be kept from the ore.
      stalled = %{stalled | search_done: true}
      more = [@their_cc, building(901, "Barracks", 52, 52, 1), building(902, "Barracks", 50, 56, 1), building(903, "TechLab", 54, 50, 1)]
      rich = Map.update!(banked(Keyword.put(opts, :buildings, more), 30_000, 30_000), "players", fn [me, them] ->
        [me, put_in(them, ["score", "survival"], 5000)]
      end)
      {strategy, _, _} = Brain.plan(View.new(rich), looked(stalled, 1, 600), terrain())
      assert %{id: 900, farm: false} = strategy.spare

      # With ore still to mine, it is spared as before.
      {strategy, _, _} = plan_banked(Keyword.merge(opts, units: mining(10) ++ soldiers(20), deposits: [@pile]), 30_000, 20_000, %{memory | income_at: {30_000, 599}})
      assert %{id: 900} = strategy.spare
    end

    test "with no Scout alive, the idle worker with the lowest id looks at the target before a wave" do
      memory = %{Brain.new_memory() | map_ore: 72_000, income_at: {42_000, 400}}
      opts = [units: idle(6) ++ soldiers(20), buildings: [@barracks, @depot], deposits: [], tick: 600]
      {strategy, _, memory} = Brain.plan(View.new(banked(opts, 42_000, 29_500)), memory, terrain())
      assert strategy.worker_scout == 101
      assert {x, y} = strategy.look
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :scout_sent and text =~ "worker 101" end)

      # It walks there, the others don't...
      v = View.new(banked(opts, 42_000, 29_500))
      assert {%{"type" => "Move", "x" => ^x, "y" => ^y}, _} = UnitBrain.decide(101, v, strategy)
      {other, _} = UnitBrain.decide(102, v, strategy)
      refute match?(%{"type" => "Move", "x" => ^x, "y" => ^y}, other)

      # ...and once it is there the look is done, like a scout's.
      there = [unit(101, "Worker", x, y) | tl(idle(6))] ++ soldiers(20)
      {strategy, _, _} = Brain.plan(View.new(banked(Keyword.merge(opts, units: there, tick: 640), 42_000, 29_500)), memory, terrain())
      assert Enum.any?(strategy.why, &match?({:scouted, "scouted player 1" <> _}, &1))
    end

    test "not while a Scout lives, or while we are still mining" do
      memory = %{Brain.new_memory() | map_ore: 72_000, income_at: {42_000, 400}}
      {strategy, _, _} = plan_banked([units: [unit(300, "Scout", 9, 9) | idle(6)], buildings: [@depot], deposits: [], tick: 600], 42_000, 29_500, memory)
      assert strategy.worker_scout == nil
      {strategy, _, _} = plan_banked([units: mining(6), buildings: [@depot], deposits: [@pile], tick: 600], 30_000, 20_000, %{memory | income_at: {30_000, 599}})
      assert strategy.worker_scout == nil
    end
  end

  describe "stalled: we go and find the ore" do
    # Banked nothing since tick 450; the count says 12,000 may be left.
    defp stalled, do: %{Brain.new_memory() | map_ore: 72_000, income_at: {30_000, 450}}
    # (A Scout alive: with none, worker 101 would stand in for them and not search.)
    defp search_opts(units, tick \\ 600), do: [units: [unit(300, "Scout", 9, 9) | units], buildings: [@barracks, @depot], deposits: [], tick: tick]

    test "up to four idle workers, each to its own place we haven't seen, clear of the enemy's base" do
      {strategy, _, memory} = plan_banked(search_opts(idle(10) ++ soldiers(10)), 30_000, 30_000, stalled())
      assert [101, 102, 103, 104] == strategy.search |> Map.keys() |> Enum.sort()
      places = Map.values(strategy.search)
      assert length(Enum.uniq(places)) == 4
      # Never by the enemy's start at (56, 56).
      assert Enum.all?(places, &(View.dist(&1, {56, 56}) >= 14))
      assert map_size(memory.search) == 4 and not memory.search_done
    end

    test "the worker walks to its place; one mining or without a place carries on" do
      {strategy, _, _} = plan_banked(search_opts(idle(10)), 30_000, 30_000, stalled())
      v = View.new(banked(search_opts(idle(10)), 30_000, 30_000))
      {x, y} = strategy.search[101]
      assert {%{"type" => "Move", "x" => ^x, "y" => ^y}, _} = UnitBrain.decide(101, v, strategy)
      {other, _} = UnitBrain.decide(109, v, strategy)
      refute match?(%{"type" => "Move", "x" => ^x, "y" => ^y}, other)
    end

    test "a place is done once we see it, and its worker gets the next; one it can't reach is given up after 90 ticks" do
      {strategy, _, memory} = plan_banked(search_opts(idle(10)), 30_000, 30_000, stalled())
      {x, y} = first = strategy.search[101]

      there = [unit(101, "Worker", x, y) | tl(idle(10))]
      {strategy, _, memory2} = plan_banked(search_opts(there, 610), 30_000, 30_000, memory)
      assert first in memory2.searched
      assert strategy.search[101] != nil and strategy.search[101] != first

      # Still at home 91 ticks on: that place is given up, and it is sent to another.
      {strategy, _, memory3} = plan_banked(search_opts(idle(10), 691), 30_000, 30_000, memory)
      assert first in memory3.searched
      assert strategy.search[101] != first
    end

    test "nowhere left to look: said once, and from the next tick it counts as none to be had" do
      everywhere = for x <- 0..63//3, y <- 0..63//3, do: {x, y}
      {strategy, _, memory} = plan_banked(search_opts(idle(10)), 30_000, 30_000, %{stalled() | searched: everywhere})
      assert strategy.search == %{}
      assert memory.search_done
      assert Enum.any?(economy(strategy), &(&1 =~ "looked for ore everywhere we may go"))

      {strategy, _, _} = plan_banked(search_opts(idle(10), 601), 30_000, 30_000, memory)
      refute Enum.any?(economy(strategy), &(&1 =~ "looked for ore everywhere"))
    end

    test "banking again ends the search; the map mined out for certain needs none" do
      {_, _, memory} = plan_banked(search_opts(idle(10)), 30_000, 30_000, stalled())
      {strategy, _, memory} = plan_banked([units: mining(10), buildings: [@barracks, @depot], deposits: [@pile], tick: 620], 30_010, 30_000, memory)
      assert strategy.search == %{} and memory.search == %{}

      {strategy, _, _} = plan_banked(search_opts(idle(10)), 42_000, 29_500, %{stalled() | income_at: {42_000, 450}})
      assert strategy.search == %{}
    end
  end
end
