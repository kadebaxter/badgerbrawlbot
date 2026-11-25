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
    test "a big raid beaten at home since the last look: a new look goes now, not when the old one is stale" do
      units = [unit(300, "Scout", 9, 9) | soldiers(22)]
      sent? = fn {s, _, _} -> Enum.any?(s.why, &match?({:scout_sent, _}, &1)) end
      # Looked at tick 90, still fresh at 100: nothing sent.
      refute sent?.(plan([units: units, tick: 100], looked(Brain.new_memory(), 1, 90)))
      # Ten of a raid's fighters killed here, the raid last here at tick 95: sent.
      beaten = %{looked(Brain.new_memory(), 1, 90) | raid: %{at: 95, kills: 10}}
      assert sent?.(plan([units: units, tick: 100], beaten))
      # Three killed isn't a big raid; and a look done after it left is the count we want.
      refute sent?.(plan([units: units, tick: 100], %{beaten | raid: %{at: 95, kills: 3}}))
      refute sent?.(plan([units: units, tick: 100], %{looked(Brain.new_memory(), 1, 97) | raid: %{at: 95, kills: 10}}))
    end

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

    # Their fighters as the scout saw them at tick 125, on its way in.
    defp on_the_way(n), do: for(i <- 1..n, into: %{}, do: {900 + i, %{"id" => 900 + i, "owner" => 1, "type" => "Soldier", "hp" => 110, "x" => 49, "y" => 49, "seen" => 125}})

    test "the scout dies on its way in, having seen their fighters: that is a look, and their army counts by their score if that is more" do
      # The scout that left at tick 120 is gone; it saw eight of theirs on the way. Their score says
      # 9,000 ore alive; we know of their Command Center (400) and have 20 workers ourselves (1,000).
      their_cc = building(900, "CommandCenter", 56, 56, 1)

      state =
        state(units: workers(20) ++ soldiers(22), buildings: [their_cc], tick: 130)
        |> Map.update!("players", fn [me, them] -> [me, Map.put(them, "score", %{"survival" => 9000, "total" => 9000})] end)

      memory = %{Brain.new_memory() | look: %{owner: 1, pos: {56, 56}, at: 120, done: nil, lookers: 1}, enemies: on_the_way(8)}
      {strategy, _, memory} = Brain.plan(View.new(state), memory, terrain())

      assert %{look: %{done: 130}} = memory
      refute Map.get(memory.look, :failed, false)
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :scouted and text =~ "8 of their fighters seen on the way" end)
      # (9000 - 400 - 1000) ore of army, at a Soldier's 990 a hundred: 75,240. Not the eight it saw.
      assert elem(memory.army_seen[1], 0) == 75_240.0
      # Fifteen attackers against that: no wave.
      assert strategy.wave == nil
    end

    test "a few of theirs seen on the way and a small score: the wave is weighed against that, and goes" do
      state =
        state(units: workers(20) ++ soldiers(22), buildings: [building(900, "CommandCenter", 56, 56, 1)], tick: 130)
        |> Map.update!("players", fn [me, them] -> [me, Map.put(them, "score", %{"survival" => 1600, "total" => 1600})] end)

      memory = %{Brain.new_memory() | look: %{owner: 1, pos: {56, 56}, at: 120, done: nil, lookers: 1}, enemies: on_the_way(2)}
      assert {%{wave: %{members: [_ | _]}}, _, _} = Brain.plan(View.new(state), memory, terrain())
    end

    test "the scout dies having seen nothing of them: that is no look" do
      memory = %{Brain.new_memory() | look: %{owner: 1, pos: {56, 56}, at: 120, done: nil, lookers: 1}}
      assert {%{wave: nil}, _, %{look: %{done: 130, failed: true}}} = Brain.plan(View.new(state(units: soldiers(22), tick: 130)), memory, terrain())
    end

    test "an opponent the scoreboard shows has no army is gone for without a look, whatever we last counted" do
      # No scout, 28 of theirs counted ten ticks ago; their Command Center is all we know of them.
      soldier = Swarm.Roles.strength([%{"type" => "Soldier"}])
      memory = %{Brain.new_memory() | army_seen: %{1 => {28 * soldier, 120}}}
      scored = fn alive ->
        state(units: soldiers(22), buildings: [building(900, "CommandCenter", 56, 56, 1)], tick: 130)
        |> Map.update!("players", fn [me, them] -> [me, Map.put(them, "score", %{"survival" => alive, "total" => alive})] end)
      end

      # 1,000 ore alive, 400 of it that Command Center: nothing left to be an army.
      assert {%{wave: %{members: [_ | _]}}, _, _} = Brain.plan(View.new(scored.(1000)), memory, terrain())
      # 5,000 alive: they may well have one, and no wave leaves without a look.
      assert {%{wave: nil}, _, _} = Brain.plan(View.new(scored.(5000)), memory, terrain())
    end

    test "passing short of their base without seeing it is no look yet" do
      # Thirteen tiles from their start at (56, 56): where the old spot, seven short of it, counted.
      memory = %{Brain.new_memory() | look: %{owner: 1, pos: {56, 56}, at: 120, done: nil, lookers: 1}}
      assert {_, _, %{look: %{done: nil}}} = Brain.plan(View.new(state(units: [unit(300, "Scout", 47, 47) | soldiers(22)], tick: 130)), memory, terrain())
    end

    test "a Scout sees the spot from a distance: that is a look too" do
      state = state(units: [unit(300, "Scout", 44, 46) | soldiers(22)], tick: 130)
      memory = %{Brain.new_memory() | look: %{owner: 1, pos: {49, 49}, at: 120, done: nil}}
      assert {_, _, %{look: %{done: 130}}} = Brain.plan(View.new(state), memory, terrain())
      # Farther off than it sees: still looking.
      state = state(units: [unit(300, "Scout", 40, 40) | soldiers(22)], tick: 130)
      assert {_, _, %{look: %{done: nil}}} = Brain.plan(View.new(state), memory, terrain())
    end

    test "enemies out of sight only diagonally aren't forgotten: sight is a circle" do
      # A scout at (43, 43); one of theirs remembered at (49, 49): six tiles each way, 8.5 in a straight line.
      memory = %{Brain.new_memory() | enemies: %{901 => %{"id" => 901, "owner" => 1, "type" => "Soldier", "hp" => 110, "x" => 49, "y" => 49, "seen" => 125}}}
      {_, _, memory} = Brain.plan(View.new(state(units: [unit(300, "Scout", 43, 43)], tick: 130)), memory, terrain())
      assert Map.has_key?(memory.enemies, 901)
      # Straight along a row, six tiles is in sight: it should be there and isn't. Forgotten.
      {_, _, memory} = Brain.plan(View.new(state(units: [unit(300, "Scout", 43, 49)], tick: 131)), memory, terrain())
      refute Map.has_key?(memory.enemies, 901)
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
      # A pile we know of that nobody is mining (no ore known at all is a stall at once, below).
      opts = [buildings: [@barracks, @depot], deposits: [@pile], ore: 500]

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

      early = [units: idle(10), buildings: [@depot], deposits: [@pile], ore: 500, tick: 250]
      {strategy, _, _} = plan_banked(early, 0, 0, %{Brain.new_memory() | map_ore: 72_000})
      assert economy(strategy) == []
    end

    test "with no ore known at all and nobody mining it is a stall at once, at any tick: workers go looking" do
      # The home field ran out at tick 270 and nothing else had ever been seen.
      memory = %{Brain.new_memory() | map_ore: 72_000, income_at: {9_000, 270}}
      opts = [buildings: [@barracks, @depot], deposits: [], ore: 100]

      {strategy, commands, _} = plan_banked([units: idle(10) ++ soldiers(10), tick: 280] ++ opts, 9_000, 30_000, memory)
      assert [text, search] = economy(strategy)
      assert text =~ "no ore known and nobody is mining" and text =~ "at most 33000 left"
      assert search =~ "4 worker(s) go looking for ore"
      refute "Worker" in trains(commands)

      # Not in the tick or two after the last pile goes; not with a pile known; not while anyone mines.
      {strategy, _, _} = plan_banked([units: idle(10) ++ soldiers(10), tick: 275] ++ opts, 9_000, 30_000, memory)
      assert economy(strategy) == []
      {strategy, _, _} = plan_banked([units: idle(10) ++ soldiers(10), tick: 280] ++ Keyword.put(opts, :deposits, [@pile]), 9_000, 30_000, memory)
      assert economy(strategy) == []
      {strategy, _, _} = plan_banked([units: mining(1) ++ tl(idle(10)) ++ soldiers(10), tick: 280] ++ opts, 9_000, 30_000, memory)
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
