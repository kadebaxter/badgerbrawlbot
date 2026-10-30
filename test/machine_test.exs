defmodule Swarm.MachineTest do
  use ExUnit.Case, async: true
  alias Swarm.Machine

  @meta %{index: 1, term: 1}

  defp run(commands, state \\ Machine.init(%{matches: 1})) do
    Enum.reduce(commands, state, fn cmd, s -> s |> then(&Machine.apply(@meta, cmd, &1)) |> elem(0) end)
  end

  test "a match is started, then finished" do
    state = run([{:match_started, "m1"}, {:brain, %{attacking: true}}, {:tick_submitted, 40}])
    assert %{match_id: "m1", brain: %{attacking: true}, last_tick: 40} = state

    state = run([{:match_finished, "m1"}], state)
    assert %{match_id: nil, matches_played: 1} = state
  end

  test "finishing a different match changes nothing" do
    state = run([{:match_started, "m1"}])
    assert run([{:match_finished, "other"}], state) == state
  end

  test "ticks only move forward" do
    assert %{last_tick: 50} = run([{:tick_submitted, 50}, {:tick_submitted, 49}])
  end

  test "play can set the opponents, and they stick until changed" do
    state = run([{:play, 1, ["balanced", "rusher"]}, {:play, 1, nil}])
    assert %{opponents: ["balanced", "rusher"], matches_wanted: 3} = state
  end

  test "a state saved before opponents existed still takes them" do
    old = Map.delete(Machine.init(%{matches: 1}), :opponents)
    assert %{opponents: ["sitter"]} = run([{:play, 1, ["sitter"]}], old)
  end

  test "joining a league, playing its heats, and leaving it" do
    state = run([{:join_league, "season-week3"}, {:match_started, "L"}, {:brain, %{wave: nil}}])
    assert %{league: "season-week3", match_id: "L"} = state

    # A heat ends: a fresh brain for the next one, still in the league.
    state = run([{:match_finished, "L"}], state)
    assert %{league: "season-week3", match_id: nil} = state

    # Leaving mid-heat keeps the heat, so a new leader still finishes it.
    state = run([{:match_started, "L"}, {:league_over, "season-week3"}], state)
    assert %{league: nil, match_id: "L"} = state
  end

  test "a stale league_over for another league changes nothing" do
    state = run([{:join_league, "season-week3"}])
    assert run([{:league_over, "preseason"}], state) == state
  end

  test "stop clears the queue but lets the current match finish" do
    state = run([{:play, 5}, {:match_started, "m1"}, :stop])
    assert %{matches_wanted: 1, matches_played: 0} = state
    assert %{matches_wanted: 1, matches_played: 1} = run([{:match_finished, "m1"}], state)

    assert %{matches_wanted: 0} = run([{:play, 5}, :stop])
  end

  test "play asks for more matches" do
    state = run([{:match_started, "m1"}, {:match_finished, "m1"}, {:play, 2}])
    assert %{matches_played: 1, matches_wanted: 3} = state
  end

  test "becoming leader starts the game loop, anything else stops it" do
    assert [{:mod_call, Swarm.Leader, :lead, []}] = Machine.state_enter(:leader, %{})
    assert [{:mod_call, Swarm.Leader, :follow, []}] = Machine.state_enter(:follower, %{})
  end
end
