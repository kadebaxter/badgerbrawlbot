defmodule Swarm.BehindTest do
  @moduledoc """
  From the four-player game lost in the middle at tick 310: the opponent beside us is a neighbor
  whatever its slot, the one across the map is not; two armies around us hold the wave whichever
  two they are; and the part of an army in sight out of its base has the rest of it behind it, by
  the scoreboard, until we have watched it long enough to know better.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, View}

  @soldier Roles.strength([%{"type" => "Soldier"}])

  defp other(slot, x, y, alive),
    do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}, "score" => %{"survival" => alive, "economy" => 5000, "total" => 9000}}

  defp with_players(s, others), do: %{s | "players" => Enum.filter(s["players"], &(&1["slot"] == 0)) ++ others}

  describe "who is beside us" do
    # Us at (7, 7). Slot 1 is across the map; slots 2 and 3 are beside us. All three are 49 steps away.
    defp corners(alive, opts \\ []) do
      s = state([units: [unit(300, "Scout", 10, 12) | workers(10) ++ soldiers(22)], buildings: [building(2, "Barracks", 11, 7)], tick: 300] ++ opts)
      View.new(with_players(s, [other(1, 56, 56, alive[1]), other(2, 56, 7, alive[2]), other(3, 7, 56, alive[3])]))
    end

    test "the two beside us are the neighbors, not the one across the map with the lower slot" do
      v = corners(%{1 => 1000, 2 => 1000, 3 => 1000})
      assert v |> Roles.neighbors() |> Enum.map(&elem(&1, 1)) == [2, 3]
    end

    test "all three are around us: as many steps away" do
      v = corners(%{1 => 1000, 2 => 1000, 3 => 1000})
      assert v |> Roles.around() |> Enum.map(&elem(&1, 1)) == [2, 3, 1]
    end

    test "one farther off is not around us" do
      s = state(units: soldiers(5))
      v = View.new(with_players(s, [other(1, 56, 56, 1000), other(2, 30, 7, 1000), other(3, 7, 30, 1000)]))
      assert v |> Roles.around() |> Enum.map(&elem(&1, 1)) == [2, 3]
    end

    test "with one or two opponents, they are the neighbors and all there is around" do
      v = View.new(state(units: soldiers(5)))
      assert Roles.neighbors(v) == [{{56, 56}, 1}] and Roles.around(v) == [{{56, 56}, 1}]
      assert Roles.around(%{v | start_owner: %{}}) == []
    end

    test "an army at each of the two beside us holds the wave, the one across the map weak or not" do
      # Some 14 Soldiers' worth each beside us against our 22; next to nothing across the map.
      {strategy, _, _} = Brain.plan(corners(%{1 => 1000, 2 => 3000, 3 => 3000}), looked(Brain.new_memory(), 2, 300), terrain())
      assert strategy.wave == nil
      assert strategy.hold =~ "between two armies (player 2 with" and strategy.hold =~ "player 3 with"
    end

    test "one beside us and the one across the map: still two armies around us" do
      {strategy, _, _} = Brain.plan(corners(%{1 => 3000, 2 => 1200, 3 => 3000}), looked(Brain.new_memory(), 2, 300), terrain())
      assert strategy.wave == nil
      assert strategy.hold =~ "between two armies (player 1 with" and strategy.hold =~ "player 3 with"
    end

    test "only one of the three with an army: the wave goes, at one beside us" do
      {strategy, _, _} = Brain.plan(corners(%{1 => 1000, 2 => 1200, 3 => 3000}), looked(Brain.new_memory(), 2, 300), terrain())
      assert %{wave: %{owner: 2}} = strategy
      refute to_string(strategy.hold) =~ "between two armies"
    end

    test "the wave never goes at the one across the map, however weak" do
      {strategy, _, _} = Brain.plan(corners(%{1 => 100, 2 => 1200, 3 => 1300}), looked(Brain.new_memory(), 2, 300), terrain())
      assert %{wave: %{owner: 2}} = strategy
    end
  end

  describe "the rest of an army out of its base" do
    # Player 1 starts at (56, 56) and has 40 Soldiers' worth alive beyond buildings and as many
    # workers as our ten. We have a Soldier watching at (26, 30).
    @alive 400 + 500 + 4000

    defp theirs(ids, x, y, type \\ "Soldier"), do: for(i <- ids, do: unit(900 + i, type, x, y, owner: 1))

    defp see(units, tick, memory \\ nil, alive \\ @alive) do
      s = state(units: workers(10) ++ units, tick: tick)
      Brain.see(View.new(with_players(s, [other(1, 56, 56, alive)])), memory)
    end

    defp behind(v), do: Enum.filter(v.recent_enemies, &(&1["behind"] == true))
    defp watcher, do: unit(201, "Soldier", 26, 30)

    test "nine in sight in the middle: the other 31 are taken to be with them" do
      {v, _} = see([watcher() | theirs(1..9, 30, 30)], 300)
      assert length(behind(v)) == 31
      assert Enum.all?(behind(v), &(View.pos(&1) == {30, 30} and &1["owner"] == 1 and &1["type"] == "Soldier"))

      [g] = Map.values(Roles.groups(v, nil).groups)
      assert g.worth == 40 * @soldier
    end

    test "they stand by the one in sight nearest their start: the rear of the column" do
      {v, _} = see([watcher() | theirs(1..5, 30, 30) ++ theirs(6..9, 32, 32)], 300)
      assert Enum.all?(behind(v), &(View.pos(&1) == {32, 32}))
    end

    test "twenty-nine of ours stay out of the nine in sight; by sight alone they would go in" do
      ours = for i <- 1..29, do: unit(200 + i, "Soldier", 27, 30)
      {v, _} = see(ours ++ theirs(1..9, 30, 30), 300)
      assert Roles.away?(Roles.group_for(v, nil, hd(ours)))

      # With nothing on the scoreboard beyond the nine: go in.
      {v, _} = see(ours ++ theirs(1..9, 30, 30), 300, nil, 400 + 500 + 900)
      assert behind(v) == []
      refute Roles.away?(Roles.group_for(v, nil, hd(ours)))
    end

    test "at their own base what we see is what we count" do
      {v, _} = see([unit(201, "Soldier", 44, 50) | theirs(1..9, 48, 50)], 300)
      assert behind(v) == []
    end

    test "three of them are a raiding party, not the head of an army" do
      {v, _} = see([watcher() | theirs(1..3, 30, 30)], 300)
      assert behind(v) == []
    end

    test "Scouts and workers out are no army" do
      {v, _} = see([watcher() | theirs(1..5, 30, 30, "Scout") ++ theirs(6..9, 30, 30, "Worker")], 300)
      assert behind(v) == []
    end

    test "no scoreboard for them, nothing behind" do
      {v, _} = Brain.see(View.new(state(units: [watcher() | theirs(1..9, 30, 30)], tick: 300)), nil)
      assert behind(v) == []
    end

    test "the ones we saw elsewhere lately are not behind these" do
      # Twenty at their base ten ticks ago; nine others in the middle now: 11 unaccounted for.
      {_, memory} = see([unit(202, "Soldier", 44, 50) | theirs(21..40, 48, 50)], 290)
      {v, _} = see([watcher() | theirs(1..9, 30, 30)], 300, memory)
      assert length(behind(v)) == 11
    end

    test "the ones we killed are not behind these: the scoreboard has them gone" do
      {v, _} = see([watcher() | theirs(1..9, 30, 30)], 300, nil, @alive - 1000)
      assert length(behind(v)) == 21
    end

    test "as the column comes into sight the count holds at 40, then it is what we have seen" do
      # Three more come into sight every tick, from nine. All forty are in sight from tick 311.
      {memory, counts} =
        Enum.reduce(0..20, {nil, []}, fn n, {memory, counts} ->
          shown = min(9 + 3 * n, 40)
          {v, memory} = see([watcher() | theirs(1..shown, 30, 30)], 300 + n, memory)
          [g] = Map.values(Roles.groups(v, nil).groups)
          {memory, [{round(g.worth / @soldier), length(behind(v))} | counts]}
        end)

      counts = Enum.reverse(counts)
      assert Enum.all?(counts, fn {worth, _} -> worth == 40 end)
      assert hd(counts) == {40, 31} and List.last(counts) == {40, 0}
      assert memory.behind == %{1 => {300, 320}}
    end

    test "nine that are alone: after fifteen ticks of watching them, they are nine" do
      {v, memory} = see([watcher() | theirs(1..9, 30, 30)], 300)
      assert length(behind(v)) == 31

      {v, memory} = see([watcher() | theirs(1..9, 30, 30)], 315, memory)
      assert length(behind(v)) == 31

      {v, memory} = see([watcher() | theirs(1..9, 30, 30)], 316, memory)
      assert behind(v) == []
      [g] = Map.values(Roles.groups(v, nil).groups)
      assert g.worth == 9 * @soldier

      # Out of sight for a few ticks and back: the same nine, no new count.
      {_, memory} = see([watcher()], 320, memory)
      {v, _} = see([watcher() | theirs(1..9, 30, 30)], 325, memory)
      assert behind(v) == []
    end

    test "a second push, with a scout watching their base all the while: counted anew" do
      # The first, at tick 300; watched for 20 ticks, then they go home. We see them there every tick.
      {_, memory} = see([watcher() | theirs(1..9, 30, 30)], 300)
      memory = Enum.reduce(301..320, memory, fn tick, memory -> elem(see([watcher() | theirs(1..9, 30, 30)], tick, memory), 1) end)
      {v, memory} = see([watcher() | theirs(1..9, 30, 30)], 321, memory)
      assert behind(v) == []

      memory =
        Enum.reduce(322..359, memory, fn tick, memory ->
          {v, memory} = see([unit(202, "Scout", 44, 50) | theirs(1..9, 48, 50)], tick, memory)
          assert behind(v) == []
          memory
        end)

      # Tick 360: ten of them are out again. The other 30 are taken to be behind them.
      {v, memory} = see([watcher() | theirs(1..10, 30, 30)], 360, memory)
      assert length(behind(v)) == 30
      assert memory.behind == %{1 => {360, 360}}
    end

    test "forgotten and out again much later: a new army, counted anew" do
      {_, memory} = see([watcher() | theirs(1..9, 30, 30)], 300)
      {_, memory} = see([watcher()], 345, memory)
      assert memory.behind == %{}

      {v, memory} = see([watcher() | theirs(1..9, 30, 30)], 400, memory)
      assert length(behind(v)) == 31 and memory.behind == %{1 => {400, 400}}
    end

    test "the leader's note on the fight says how many nobody has seen" do
      ours = for i <- 1..29, do: unit(200 + i, "Soldier", 27, 30)
      {v, memory} = see(ours ++ theirs(1..9, 30, 30), 300)
      {strategy, _, _} = Brain.plan(v, memory, terrain())
      assert {:fight, note} = Enum.find(strategy.why, &match?({:fight, _}, &1))
      assert note =~ "40 Soldier (31 of them not seen: behind these, by the scoreboard)" and note =~ "stay out of it"
    end
  end
end
