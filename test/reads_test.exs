defmodule Swarm.ReadsTest do
  @moduledoc """
  What kind of opponent each player is (`Swarm.Reads`), and what the leader does about a boom:
  its bases without towers are gone for early, by a few, before the towers go up.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Reads, View}

  @looked %{kind: :unknown, candidate: :unknown, since: 0, looked: true, scouts: 0, trebuchets: 0}

  describe "the kind what we know says" do
    test "nothing before a scout has looked, nor before tick 120" do
      boom = %{army: 0, ccs: 3, towers: 0, economy: 3000}
      assert Reads.classify(%{@looked | looked: false}, boom, 10, 2000, 200) == :unknown
      assert Reads.classify(@looked, boom, 10, 2000, 100) == :unknown
      assert Reads.classify(@looked, boom, 10, 2000, 200) == :boom
    end

    test "a boom: next to no army, and bases, towers or ore banked well beyond ours" do
      assert Reads.classify(@looked, %{army: 0, ccs: 2}, 12, 2000, 200) == :boom
      assert Reads.classify(@looked, %{army: 2, ccs: 1, towers: 8}, 12, 2000, 200) == :boom
      assert Reads.classify(@looked, %{army: 3, ccs: 1, economy: 2600}, 12, 2000, 200) == :boom
      # A third of ours or less still is; an army like ours with three bases is not.
      assert Reads.classify(@looked, %{army: 9, ccs: 3}, 30, 2000, 400) == :boom
      assert Reads.classify(@looked, %{army: 14, soldiers: 14, ccs: 3}, 15, 2000, 300) == :flood
      # No army yet and nothing else to show for it either: too early to say.
      assert Reads.classify(@looked, %{army: 0, ccs: 1, towers: 1, economy: 2000}, 12, 2000, 200) == :unknown
    end

    test "a flood: an army near ours or bigger" do
      assert Reads.classify(@looked, %{army: 20, soldiers: 20, ccs: 1}, 15, 2000, 250) == :flood
      assert Reads.classify(@looked, %{army: 11, soldiers: 11, ccs: 2}, 15, 2000, 250) == :flood
    end

    test "siege: Trebuchets seen, or a smaller army with many Archers" do
      assert Reads.classify(%{@looked | trebuchets: 2}, %{army: 12, soldiers: 8, archers: 4}, 15, 2000, 400) == :siege
      assert Reads.classify(@looked, %{army: 9, soldiers: 4, archers: 4}, 15, 2000, 300) == :siege
    end

    test "a harasser: Scouts and little else" do
      assert Reads.classify(%{@looked | scouts: 9}, %{army: 6, soldiers: 2, ccs: 1}, 15, 2000, 300) == :harass
    end
  end

  describe "a read" do
    test "changes only once the same thing has been said for 30 ticks, with a line for the log" do
      boom = %{army: 0, ccs: 3, economy: 3000, looked: true}
      {reads, []} = Reads.update(%{}, 200, 1, boom, 12, 2000)
      assert Reads.kind(reads, 1) == :unknown
      {reads, []} = Reads.update(reads, 220, 1, %{boom | looked: false}, 12, 2000)
      assert Reads.kind(reads, 1) == :unknown
      {reads, [{:read, why}]} = Reads.update(reads, 230, 1, %{boom | looked: false}, 12, 2000)
      assert Reads.kind(reads, 1) == :boom
      assert why =~ "player 1 reads as boom" and why =~ "3 Command Centers"

      # One sighting of an army doesn't flip it back; thirty ticks of it does.
      army = %{army: 14, soldiers: 14, ccs: 3, economy: 3000}
      {reads, []} = Reads.update(reads, 240, 1, army, 12, 2000)
      {reads, []} = Reads.update(reads, 241, 1, %{boom | looked: false}, 12, 2000)
      assert Reads.kind(reads, 1) == :boom
      {reads, []} = Reads.update(reads, 250, 1, army, 12, 2000)
      {reads, [{:read, _}]} = Reads.update(reads, 280, 1, army, 12, 2000)
      assert Reads.kind(reads, 1) == :flood
    end

    test "the Scouts and Trebuchets seen at most are remembered" do
      {reads, _} = Reads.update(%{}, 200, 1, %{scouts: 8, trebuchets: 1, looked: true}, 12, 2000)
      {reads, _} = Reads.update(reads, 210, 1, %{scouts: 1}, 12, 2000)
      assert %{scouts: 8, trebuchets: 1, looked: true} = reads[1]
    end

    test "the leader keeps one for each opponent, from what the scout found and the scoreboard" do
      # Their start at (56, 56) and a second Command Center, no fighters, a scout just there.
      theirs = [building(900, "CommandCenter", 56, 56, 1), building(901, "CommandCenter", 44, 44, 1)]
      memory = %{Brain.new_memory() | look: %{owner: 1, pos: {50, 50}, at: 190, done: nil}}
      opts = fn tick -> [units: soldiers(12) ++ [unit(300, "Scout", 50, 50)], buildings: theirs, tick: tick] end

      {_, _, memory} = Brain.plan(View.new(state(opts.(200))), memory, terrain())
      assert memory.reads[1].looked and memory.reads[1].candidate == :boom
      {strategy, _, memory} = Brain.plan(View.new(state(opts.(230))), memory, terrain())
      assert Reads.kind(memory.reads, 1) == :boom
      assert Enum.any?(strategy.why, &match?({:read, _}, &1))
    end
  end

  describe "floods on two sides" do
    @flood %{kind: :flood, candidate: :flood, since: 150, looked: true, scouts: 0, trebuchets: 0}
    # Us at (7, 7) with neighbors at (56, 7) and (7, 56).
    # `alive` is the ore value of all each has alive, by the scoreboard: with our 20 workers taken
    # off it, 1,500 is ten Soldiers' worth of army.
    defp three(opts, alive \\ 1500) do
      s = state(Keyword.put_new(opts, :tick, 250))
      other = fn slot, x, y -> %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}, "score" => %{"survival" => alive, "economy" => 3000, "total" => 8000}} end
      View.new(%{s | "players" => Enum.filter(s["players"], &(&1["slot"] == 0)) ++ [other.(1, 56, 7), other.(2, 7, 56)]})
    end

    # Whether the first thing the ore goes to is a fighter.
    defp army_first?([%{"type" => "Produce", "unitType" => type} | _]), do: type in ["Soldier", "Archer"]
    defp army_first?(_commands), do: false

    test "the Barracks are fed before anything is built or researched, until our army is the bigger of theirs" do
      barracks = for i <- 0..2, do: building(10 + i, "Barracks", 11, 3 + 3 * i)
      lab = building(20, "TechLab", 10, 12)
      opts = [units: workers(20) ++ soldiers(12), buildings: barracks ++ [lab], ore: 450]
      soldier = Swarm.Roles.strength([%{"type" => "Soldier"}])
      floods = %{Brain.new_memory() | reads: %{1 => @flood, 2 => @flood}, army_seen: %{1 => {30 * soldier, 240}, 2 => {22 * soldier, 240}}}

      # Twelve of ours against thirty: the Barracks come first.
      {_, commands, _} = Brain.plan(three(opts), looked(floods, 1, 250), terrain())
      assert army_first?(commands)

      # One flood next to us is today's game: the floor is as it was, and the rest gets its share.
      one = %{floods | reads: %{1 => @flood}}
      {_, commands, _} = Brain.plan(three(opts), looked(one, 1, 250), terrain())
      refute army_first?(commands)

      # Thirty of ours: as many as the bigger of them, and the rest gets its share again.
      {_, commands, _} = Brain.plan(three(Keyword.put(opts, :units, workers(20) ++ soldiers(30))), looked(floods, 1, 250), terrain())
      refute army_first?(commands)
    end

    test "with two or more opponents in, a neighbor's army by the scoreboard is a floor too: no read needed" do
      barracks = for i <- 0..2, do: building(10 + i, "Barracks", 11, 3 + 3 * i)
      opts = [units: workers(20) ++ soldiers(12), buildings: barracks ++ [building(20, "TechLab", 10, 12)], ore: 450]

      # 4,000 ore alive each, less our 20 workers' worth: thirty Soldiers against our twelve.
      {_, commands, _} = Brain.plan(three(opts, 4000), Brain.new_memory(), terrain())
      assert army_first?(commands)

      # Thirty of ours: the rest gets its share again.
      {_, commands, _} = Brain.plan(three(Keyword.put(opts, :units, workers(20) ++ soldiers(30)), 4000), Brain.new_memory(), terrain())
      refute army_first?(commands)

      # Not before tick 120, and not with one opponent left: that game is as it was.
      {_, commands, _} = Brain.plan(three([tick: 100] ++ opts, 4000), Brain.new_memory(), terrain())
      refute army_first?(commands)
      s = state([tick: 250] ++ opts)
      one = %{s | "players" => Enum.map(s["players"], &if(&1["slot"] == 0, do: &1, else: Map.put(&1, "score", %{"survival" => 4000, "economy" => 3000, "total" => 7000})))}
      {_, commands, _} = Brain.plan(View.new(one), Brain.new_memory(), terrain())
      refute army_first?(commands)
    end

    test "catching up, another Barracks as soon as every one is training at all, up to six of them" do
      # Each with one in its queue: not "busy" enough for another by the usual rule (two queued).
      training = fn i -> building(10 + i, "Barracks", 11, 3 + 3 * i) |> Map.put("production", [%{"unitType" => "Soldier"}]) end
      built = fn commands -> for %{"type" => "Build", "buildingType" => type} <- commands, do: type end
      opts = fn n, fighters -> [units: workers(20) ++ soldiers(fighters), buildings: Enum.map(0..(n - 1), training), ore: 1500] end

      # Three Barracks, twelve of ours against thirty by their score: a fourth.
      {_, commands, _} = Brain.plan(three(opts.(3, 12), 4000), Brain.new_memory(), terrain())
      assert "Barracks" in built.(commands)

      # Six of them: no seventh on that.
      {_, commands, _} = Brain.plan(three(opts.(6, 12), 4000), Brain.new_memory(), terrain())
      refute "Barracks" in built.(commands)

      # Thirty of ours: no longer catching up, and the usual rule has it.
      {_, commands, _} = Brain.plan(three(opts.(3, 30), 4000), Brain.new_memory(), terrain())
      refute "Barracks" in built.(commands)
    end

    test "never more than forty Soldiers' worth, whatever we count of them" do
      barracks = for i <- 0..2, do: building(10 + i, "Barracks", 11, 3 + 3 * i)
      soldier = Swarm.Roles.strength([%{"type" => "Soldier"}])
      floods = %{Brain.new_memory() | reads: %{1 => @flood, 2 => @flood}, army_seen: %{1 => {90 * soldier, 240}, 2 => {80 * soldier, 240}}}
      opts = [units: workers(20) ++ soldiers(40), buildings: barracks ++ [building(20, "TechLab", 10, 12)], ore: 450]
      {_, commands, _} = Brain.plan(three(opts), looked(floods, 1, 250), terrain())
      refute army_first?(commands)
    end
  end

  describe "a neighbor that reads as a boom" do
    @boom %{1 => %{kind: :boom, candidate: :boom, since: 150, looked: true, scouts: 0, trebuchets: 0}}
    defp boom(memory \\ Brain.new_memory()), do: looked(Map.put(memory, :reads, @boom), 1, 200)
    defp plan(opts, memory), do: Brain.plan(View.new(state([tick: 200] ++ opts)), memory, terrain())
    defp launched(strategy), do: for({:wave_launched, text} <- strategy.why, do: text)

    # Seven guards stay home: fifteen fighters are eight attackers at the rally point.
    @their_start building(900, "CommandCenter", 56, 56, 1)
    @their_base building(901, "CommandCenter", 40, 40, 1)
    defp tower(id, x, y), do: building(id, "GuardTower", x, y, 1)

    test "a base of theirs without towers is gone for with eight attackers, long before a full wave" do
      {strategy, _, memory} = plan([units: soldiers(15), buildings: [@their_start, @their_base]], boom())
      assert [why] = launched(strategy)
      assert why =~ "they read as a boom" and why =~ "(40,40)"
      assert %{goal: {40, 40}, hunt: true, owner: 1} = memory.wave
      assert strategy.target == {40, 40}

      # Not read as a boom: the same fifteen wait for a wave.
      {strategy, _, memory} = plan([units: soldiers(15), buildings: [@their_start, @their_base]], looked(nil, 1, 200))
      assert launched(strategy) == [] and memory.wave == nil
      # And not with seven attackers.
      {strategy, _, _} = plan([units: soldiers(14), buildings: [@their_start, @their_base]], boom())
      assert launched(strategy) == []
    end

    test "the one with the fewest towers by it; none with more than two, nor more than the attackers can meet" do
      towered = [tower(910, 54, 54), tower(911, 58, 54), tower(912, 54, 58)]
      {_, _, memory} = plan([units: soldiers(15), buildings: [@their_start, @their_base | towered]], boom())
      assert memory.wave.goal == {40, 40}

      # Three towers by each: nothing open, no hunt.
      more = [tower(913, 38, 38), tower(914, 42, 38), tower(915, 38, 42)]
      {strategy, _, memory} = plan([units: soldiers(15), buildings: [@their_start, @their_base | towered ++ more]], boom())
      assert launched(strategy) == [] and memory.wave == nil

      # Two towers by it are eight Soldiers' worth, half as many again to go: eight attackers stay.
      two = [tower(913, 38, 38), tower(914, 42, 38)]
      {strategy, _, _} = plan([units: soldiers(15), buildings: [@their_base | two]], boom())
      assert launched(strategy) == []
      {strategy, _, _} = plan([units: soldiers(19), buildings: [@their_base | two]], boom())
      assert [_] = launched(strategy)
    end

    test "out there: on to the next open base when the first is gone, and home when there is none" do
      {_, _, memory} = plan([units: soldiers(15), buildings: [@their_start, @their_base]], boom())
      # The wave's eight (ids 201 to 208) out by the base, the guards at home.
      out = for i <- 1..15, do: unit(200 + i, "Soldier", if(i <= 8, do: 38, else: 10), if(i <= 8, do: 38, else: 10))

      # The base at (40, 40) is gone: their start has no towers either.
      {strategy, _, memory} = plan([units: out, buildings: [@their_start], tick: 230], memory)
      assert memory.wave.goal == {56, 56}
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :wave_reinforced and text =~ "on to their base by (56,56)" end)

      # Towers went up there meanwhile: nothing open left, the wave comes home.
      towered = [tower(910, 54, 54), tower(911, 58, 54), tower(912, 54, 58)]
      {strategy, _, memory} = plan([units: out, buildings: [@their_start | towered], tick: 231], memory)
      assert memory.wave == nil
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :wave_recalled and text =~ "left without towers" end)
    end

    test "comes before a weaker neighbor: by its score a boom is the strongest of them" do
      state = fn -> state(units: soldiers(15), buildings: [@their_base], tick: 200) end
      # Two opponents: player 1 the boom with the bigger score.
      three = fn ->
        s = state.()
        others = [%{"slot" => 1, "name" => "boom", "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 56}, "score" => %{"survival" => 9000, "economy" => 4000, "total" => 13000}},
                  %{"slot" => 2, "name" => "small", "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 7}, "score" => %{"survival" => 2000, "economy" => 900, "total" => 2900}}]
        %{s | "players" => Enum.filter(s["players"], &(&1["slot"] == 0)) ++ others}
      end

      {_, _, memory} = Brain.plan(View.new(three.()), boom(), terrain())
      assert %{owner: 1, hunt: true} = memory.wave
    end
  end
end
