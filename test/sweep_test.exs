defmodule Swarm.SweepTest do
  @moduledoc """
  From the game lost on the clock with one soldier standing on an empty start: a player still in,
  with no building we know of and their start seen empty, is somewhere we haven't looked. The
  wave goes over the whole map for them, idle workers too once the map is mined out, and what
  turns up is the target.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  @start {56, 56}
  @grid for x <- 3..63//6, y <- 3..63//6, do: {x, y}

  defp out(x \\ 50, y \\ 50), do: for(i <- 1..20, do: unit(200 + i, "Soldier", x, y))
  defp wave, do: %{id: 1, members: Enum.to_list(201..220), released: true, owner: 1, peak: 20 * 990, at: 900}
  defp memory(more \\ %{}), do: Map.merge(%{Brain.new_memory() | wave: wave(), next_wave: 2, empty_starts: [@start]}, more)

  # The opponent is still in (1,000 alive on the scoreboard); `eco` is what each of us has mined.
  defp plan(units, memory, opts \\ []) do
    {mine, theirs} = Keyword.get(opts, :eco, {9_000, 9_000})

    state =
      state(units: units, tick: Keyword.get(opts, :tick, 1000), deposits: [])
      |> Map.update!("players", fn [me, them] ->
        [Map.put(me, "score", %{"economy" => mine, "total" => mine}), Map.put(them, "score", %{"economy" => theirs, "total" => theirs + 5000, "survival" => 1000})]
      end)
      |> Map.put("rememberedBuildings", Keyword.get(opts, :remembered, []))

    Brain.plan(View.new(state), looked(memory, 1, Keyword.get(opts, :tick, 1000)), terrain())
  end

  defp said(strategy), do: for({:sweep, text} <- strategy.why, do: text)

  test "nothing of theirs known and their start seen empty: the wave goes looking, the nearest place first" do
    {s, _, memory} = plan(out(), memory())
    assert s.target != @start and s.target in @grid
    assert s.target == Enum.min_by(@grid -- [{51, 51}], &{View.dist(&1, {50, 50}), &1})
    assert said(s) == ["nothing left of player 1 that we know of, and they are still in: looking for the rest of them, 121 places"]
    assert memory.sweep.owner == 1
  end

  test "until we have seen their start empty, that is where the wave goes" do
    {s, _, memory} = plan(out(40, 40), memory(%{empty_starts: []}))
    assert s.target == @start and memory.sweep == nil and said(s) == []
  end

  test "standing on it with no Command Center there is seeing it empty" do
    {s, _, _} = plan(out(55, 55), memory(%{empty_starts: []}))
    assert s.target != @start and s.target in @grid
  end

  test "a building of theirs we know of is the target, and the looking is over" do
    {_, _, memory} = plan(out(), memory())
    hidden = building(950, "Barracks", 2, 54, 1)
    {s, _, memory} = plan(out(), memory, remembered: [hidden], tick: 1001)
    assert s.target == {2, 54} and memory.sweep == nil
    assert said(s) == ["found what is left of player 1: the wave goes for it"]

    # A Command Center of theirs: the wave goes there (to it, or to its camp by it while it is spared).
    {s, _, memory} = plan(out(), memory(), remembered: [building(951, "CommandCenter", 2, 54, 1)], tick: 1001)
    assert View.dist(s.target, {2, 54}) <= 12 and memory.sweep == nil
  end

  test "a player who is out is not looked for" do
    state = state(units: out(), tick: 1000, deposits: []) |> Map.update!("players", fn [me, them] -> [me, Map.put(them, "eliminated", true)] end)
    {s, _, memory} = Brain.plan(View.new(state), looked(memory(), 1, 1000), terrain())
    assert memory.sweep == nil and said(s) == []
  end

  test "place by place: the wave is sent over the whole map, to no place twice, and then round again" do
    # Each tick the wave stands where it was sent.
    {places, memory} =
      Enum.reduce(1..130, {[], memory()}, fn n, {places, memory} ->
        at = List.first(places) || {50, 50}
        {s, _, memory} = plan(out(elem(at, 0), elem(at, 1)), memory, tick: 1000 + n)
        {[s.target | places], memory}
      end)

    places = Enum.reverse(places)
    first = Enum.uniq(places)
    # A new place every tick until it has stood on all of them (it sees its neighbors' as it goes).
    assert Enum.all?(places, &(&1 in @grid))
    assert Enum.take(places, 20) == Enum.uniq(Enum.take(places, 20))
    assert length(first) < 121
    # Every place has been in sight by the time it starts over.
    assert memory.sweep != nil
    assert length(places) > length(first)
  end

  test "a place nobody can get to is given up on after sixty ticks" do
    {s, _, memory} = plan(out(), memory())
    goal = s.target
    # The wave never gets there (it stands still, out of sight of it).
    stuck = out(20, 20)
    {s, _, memory} = plan(stuck, %{memory | sweep: %{memory.sweep | goal: {3, 63}, at: 1000}}, tick: 1060)
    assert s.target == {3, 63}
    {s, _, memory} = plan(stuck, memory, tick: 1061)
    assert s.target != {3, 63} and {3, 63} in memory.sweep.done
    assert goal in @grid
  end

  test "with the map mined out, eight idle workers go looking too, each somewhere else" do
    idle = for i <- 1..12, do: unit(100 + i, "Worker", 8, 8)
    mined = memory(%{map_ore: 20_000})
    {s, _, memory} = plan(idle ++ out(), mined, eco: {9_000, 12_000})
    assert s.no_ore == :mined_out
    assert map_size(s.search) == 8
    spots = Map.values(s.search)
    assert spots == Enum.uniq(spots) and s.target not in spots and Enum.all?(spots, &(&1 in @grid))

    # They keep their places while those still want looking at.
    {s2, _, _} = plan(idle ++ out(), memory, eco: {9_000, 12_000}, tick: 1001)
    assert s2.search == s.search
  end

  test "with ore still to mine the workers stay at it" do
    idle = for i <- 1..12, do: unit(100 + i, "Worker", 8, 8)
    {s, _, _} = plan(idle ++ out(), memory(%{map_ore: 72_000}))
    assert s.search == %{}
  end
end
