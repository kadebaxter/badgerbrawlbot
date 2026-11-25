defmodule Swarm.ClaimTest do
  @moduledoc """
  One situation, start to finish, from the game lost with 53 workers idle: the ore by our
  drop-offs is gone, the only ore we know of is a field across the middle with another player's
  workers on it and a depot of theirs a few tiles off (so it is "enemy ground" and our workers
  won't touch it), and we have an army at home. The army goes and takes the field.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  @built [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 11, 11)]
  # Their depot six tiles from the field: enemy ground. Their start is at (56, 56).
  @their_depot building(900, "ResourceDepot", 40, 36, 1)
  @field for {id, x, y} <- [{31, 34, 34}, {32, 35, 34}, {33, 34, 35}, {34, 35, 35}], into: %{}, do: {id, %{"id" => id, "x" => x, "y" => y, "remaining" => 800, "seen" => 300}}

  # The field as the game shows it once one of ours stands by it.
  defp in_sight, do: for({_id, d} <- @field, do: Map.delete(d, "seen"))
  defp idle(n \\ 10), do: for(i <- 1..n, do: unit(100 + i, "Worker", 8, 8))
  defp scout, do: unit(300, "Scout", 10, 12)
  defp home(n \\ 20), do: soldiers(n)
  defp at_field(n), do: for(i <- 1..n, do: unit(200 + i, "Soldier", 33, 33))
  defp their_workers, do: for(i <- 1..6, do: unit(950 + i, "Worker", 35, 36, owner: 1))

  # The field is remembered, not in sight; we banked our last ore at tick 380.
  defp start, do: %{Brain.new_memory() | map_ore: 72_000, income_at: {9_000, 380}, ore: @field}

  defp tick(tick, units, memory, opts \\ []) do
    state =
      state(units: units, buildings: @built ++ [@their_depot] ++ Keyword.get(opts, :buildings, []), deposits: Keyword.get(opts, :deposits, []), ore: Keyword.get(opts, :ore, 60), tick: tick)
      |> Map.update!("players", fn [me, them] ->
        [Map.put(me, "score", %{"economy" => 9_000, "total" => 9_000}), Map.put(them, "score", %{"economy" => 20_000, "total" => 20_000, "survival" => 3000})]
      end)

    {v, memory} = Brain.see(View.new(state), memory)
    {strategy, commands, memory} = Brain.plan(v, looked(memory, 1, tick), terrain())
    prepared = UnitBrain.prepare(v, strategy.wave)
    orders = for u <- v.my_units, {cmd, _} = UnitBrain.decide(u["id"], prepared, strategy), is_map(cmd), into: %{}, do: {u["id"], cmd}
    %{v: v, strategy: strategy, commands: commands, memory: memory, orders: orders, log: for({:claim, text} <- strategy.why, do: text)}
  end

  test "the whole thing: idle, the army goes, kills what is on it, the workers mine it, a depot goes up, and it ends when the field does" do
    # Tick 400: twenty ticks with nothing banked and nobody mining. The field is claimed.
    t = tick(400, [scout() | idle() ++ home()], start())
    assert t.strategy.claim == {34, 34}
    assert [said] = t.log
    assert said =~ "nothing to mine for 20 ticks" and said =~ "the field at (34,34)" and said =~ "3200 ore known there"

    # Home's attackers set off for it; the guards stay; the workers wait under cover, not mining yet.
    assert %{"type" => "Move", "x" => 34, "y" => 34} = t.orders[201]
    refute Enum.any?(101..110, &match?(%{"type" => "Gather"}, t.orders[&1]))

    # No wave leaves meanwhile, and it says why.
    assert t.strategy.wave == nil
    assert t.strategy.hold =~ "the army takes the field at (34,34) first"

    # Tick 420: thirteen of them are at the field, with their workers on it. They are attacked...
    there = at_field(13) ++ Enum.drop(home(), 13)
    t = tick(420, [scout() | idle() ++ there ++ their_workers()], t.memory, deposits: in_sight())
    assert t.strategy.claim == {34, 34} and t.log == []
    assert Enum.any?(201..213, &match?(%{"type" => "Attack", "targetId" => id} when id in 951..956, t.orders[&1]))

    # ...and ours come and mine it, enemy ground or not.
    assert Enum.all?(101..110, &match?(%{"type" => "Gather", "targetId" => id} when id in 31..34, t.orders[&1]))

    # Tick 440: they are walking to it. A depot goes up right by it.
    walking = for w <- idle(), do: %{w | "x" => 20, "y" => 20, "activity" => "Moving", "targetId" => 31}
    t = tick(440, [scout() | walking ++ there], t.memory, ore: 250, deposits: in_sight())
    assert %{"x" => x, "y" => y} = Enum.find(t.commands, &(&1["buildingType"] == "ResourceDepot"))
    assert View.dist({x, y}, {34, 34}) <= 4

    # Tick 500: mining it. The army stays there while the field has ore.
    mining = for w <- idle(), do: %{w | "x" => 33, "y" => 34, "activity" => "Gathering", "targetId" => 31}
    t = tick(500, [scout() | mining ++ there], t.memory, deposits: in_sight())
    assert t.strategy.claim == {34, 34} and t.strategy.help == {34, 34}

    # Tick 600: the field is in sight and empty. Done.
    t = tick(600, [scout() | (for w <- idle(), do: %{w | "x" => 33, "y" => 34}) ++ there], t.memory)
    assert t.strategy.claim == nil
    assert [said] = t.log
    assert said =~ "the field at (34,34) is done"
  end

  test "until five of the army are by it, no worker walks out to it" do
    # Claimed. Two of ours are six tiles from it (by it, but the ore is still out of sight).
    by = fn n -> for(i <- 1..n, do: unit(200 + i, "Soldier", 28, 34)) ++ Enum.drop(home(), n) end
    t = tick(400, [scout() | idle() ++ home()], start())
    t = tick(410, [scout() | idle() ++ by.(2)], t.memory)
    assert t.strategy.claim == {34, 34}
    refute Enum.any?(101..110, &match?(%{"type" => "Gather"}, t.orders[&1]))

    # Five: they go.
    t = tick(411, [scout() | idle() ++ by.(5)], t.memory)
    assert Enum.all?(101..110, &match?(%{"type" => "Gather", "targetId" => id} when id in 31..34, t.orders[&1]))
  end

  test "a wave that is out comes home for it" do
    out = for i <- 1..12, do: unit(200 + i, "Soldier", 45, 45)
    wave = %{id: 1, members: Enum.to_list(201..212), released: true, owner: 1, peak: 12 * 990, at: 350}
    t = tick(400, [scout() | idle() ++ out ++ Enum.drop(home(), 12)], %{start() | wave: wave, next_wave: 2})
    assert t.strategy.wave == nil
    assert Enum.any?(t.strategy.why, &match?({:wave_recalled, "wave 1: our workers have nothing to mine, coming home to take the field at (34,34)"}, &1))
  end

  test "not while anyone is mining or on the way to ore, not in the first ten ticks, and not with the map mined out" do
    mining = [unit(101, "Worker", 8, 8, activity: "Gathering", target_id: 31) | tl(idle())]
    assert tick(400, [scout() | mining ++ home()], start()).strategy.claim == nil

    walking = [unit(101, "Worker", 20, 20, activity: "Moving", target_id: 31) | tl(idle())]
    assert tick(400, [scout() | walking ++ home()], start()).strategy.claim == nil

    assert tick(385, [scout() | idle() ++ home()], start()).strategy.claim == nil

    # Everyone together has banked the lot: what we remember there is gone.
    assert tick(400, [scout() | idle() ++ home()], %{start() | map_ore: 29_000}).strategy.claim == nil
  end

  test "not a field under their towers, at their start, or with more on it than home can take" do
    # A tower of theirs in reach of the field.
    tower = building(901, "GuardTower", 36, 36, 1)
    assert tick(400, [scout() | idle() ++ home()], start(), buildings: [tower]).strategy.claim == nil

    # The only ore known is at their start.
    theirs = for {id, d} <- @field, into: %{}, do: {id, %{d | "x" => d["x"] + 20, "y" => d["y"] + 20}}
    assert tick(400, [scout() | idle() ++ home()], %{start() | ore: theirs}).strategy.claim == nil

    # Thirty of theirs standing on it, in sight of our scout: more than our twenty.
    guard = for i <- 1..30, do: unit(900 + i, "Soldier", 35, 35, owner: 1)
    watcher = unit(300, "Scout", 30, 30)
    assert tick(400, [watcher | idle() ++ home()] ++ guard, start()).strategy.claim == nil
  end

  test "given up when too much turns up there, and not taken again for sixty ticks" do
    t = tick(400, [scout() | idle() ++ home()], start())
    assert t.strategy.claim == {34, 34}

    army = for i <- 1..40, do: unit(900 + i, "Soldier", 36, 36, owner: 1)
    there = at_field(13) ++ Enum.drop(home(), 13)
    t = tick(420, [scout() | idle() ++ there] ++ army, t.memory, deposits: in_sight())
    assert t.strategy.claim == nil
    assert [said] = t.log
    assert said =~ "the field at (34,34) is given up"

    # They have gone again: not straight back. After the rest, again.
    assert tick(450, [scout() | idle() ++ home()], t.memory).strategy.claim == nil
    assert tick(481, [scout() | idle() ++ home()], t.memory).strategy.claim == {34, 34}
  end
end

defmodule Swarm.BetweenTest do
  @moduledoc """
  From the game lost between the two Formics: a raid is not "nothing to mine", and with an army
  on each side no wave leaves until one of them has spent its own.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  @built [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 11, 11)]
  @field for {id, x, y} <- [{31, 34, 34}, {32, 35, 34}], into: %{}, do: {id, %{"id" => id, "x" => x, "y" => y, "remaining" => 800, "seen" => 300}}

  defp idle, do: for(i <- 1..10, do: unit(100 + i, "Worker", 8, 8))
  defp scout, do: unit(300, "Scout", 10, 12)
  defp start, do: %{Brain.new_memory() | map_ore: 72_000, income_at: {9_000, 380}, ore: @field}

  defp claim(tick, units, memory) do
    {v, memory} = Brain.see(View.new(state(units: units, buildings: @built, deposits: [], tick: tick)), memory)
    {strategy, _, memory} = Brain.plan(v, looked(memory, 1, tick), terrain())
    {strategy.claim, memory}
  end

  describe "taking a field is for want of ore, not for hiding" do
    test "not while raiders are on us, nor in the ticks after they have gone" do
      # Twenty raiders in the base: the workers aren't mining because of them.
      raid = for i <- 1..20, do: unit(900 + i, "Soldier", 13, 9, owner: 1)
      {claim, memory} = claim(400, [scout() | idle() ++ soldiers(20)] ++ raid, start())
      assert claim == nil

      # Gone five ticks: still not. Twenty ticks: now it is for want of ore.
      {claim, memory} = claim(405, [scout() | idle() ++ soldiers(20)], memory)
      assert claim == nil
      {claim, _} = claim(425, [scout() | idle() ++ soldiers(20)], memory)
      assert claim == {34, 34}
    end

    test "not while home has fallen back to the towers, nor just after" do
      fallen = %{start() | fall_back: true, fall_back_at: 399}
      assert {nil, _} = claim(400, [scout() | idle() ++ soldiers(20)], fallen)
      assert {nil, _} = claim(420, [scout() | idle() ++ soldiers(20)], %{start() | fall_back_at: 399})
      assert {{34, 34}, _} = claim(430, [scout() | idle() ++ soldiers(20)], %{start() | fall_back_at: 399})
    end
  end

  describe "between two armies" do
    # Three players: neighbors at (56, 7) and (7, 56), each with `alive` on the scoreboard beyond
    # their buildings. Twenty-two of ours at the rally point, a fresh look at player 1.
    defp three(alive_1, alive_2, opts \\ []) do
      s = state([units: [unit(300, "Scout", 10, 12) | workers(10) ++ soldiers(22)], buildings: [building(2, "Barracks", 11, 7)], tick: 300] ++ opts)
      other = fn slot, x, y, alive -> %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}, "score" => %{"survival" => alive, "economy" => 5000, "total" => 9000}} end
      View.new(%{s | "players" => Enum.filter(s["players"], &(&1["slot"] == 0)) ++ [other.(1, 56, 7, alive_1), other.(2, 7, 56, alive_2)]})
    end

    defp plan(v, memory \\ Brain.new_memory()), do: Brain.plan(v, looked(memory, 1, 300), terrain())

    test "an army on each side: no wave leaves, and it says who and how many" do
      # Each has some 14 Soldiers' worth alive beyond buildings and workers: over half our 22.
      {strategy, _, _} = plan(three(3_000, 3_000))
      assert strategy.wave == nil
      assert strategy.hold =~ "between two armies" and strategy.hold =~ "none leaves until one of them is down to half of ours"
    end

    test "one of them spent: the wave goes as it would" do
      {strategy, _, _} = plan(three(1_200, 3_000))
      assert %{wave: %{owner: 1}} = strategy
      refute to_string(strategy.hold) =~ "between two armies"
    end

    test "it holds tick after tick while both stand, and lifts the tick one is spent" do
      {s1, _, memory} = plan(three(3_000, 3_000))
      {s2, _, memory} = plan(three(3_000, 3_000, tick: 301), memory)
      assert s1.wave == nil and s2.wave == nil
      assert s1.hold =~ "between two armies" and s2.hold =~ "between two armies"
      {s3, _, _} = plan(three(1_200, 3_000, tick: 302), memory)
      assert %{wave: %{owner: 1}} = s3
    end

    test "with one opponent there is no between" do
      {strategy, _, _} = Brain.plan(View.new(state(units: [unit(300, "Scout", 10, 12) | workers(10) ++ soldiers(22)], buildings: [building(2, "Barracks", 11, 7)], tick: 300)), looked(Brain.new_memory(), 1, 300), terrain())
      refute to_string(strategy.hold) =~ "between two armies"
    end
  end
end
