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

  describe "joining by id and hosting" do
    test "a request waits for the leader; starting the match settles it" do
      state = run([{:join_match, "m9"}])
      assert %{join_match: "m9"} = state
      assert %{join_match: nil, host: nil, match_id: "m9"} = run([{:match_started, "m9"}], state)

      state = run([{:host, %{seats: 6, bots: [], name: "kaden-brawl"}}])
      assert %{host: %{seats: 6}} = state
      assert %{host: nil} = run([:request_failed], state)
    end

    test "refused while we play something, or something is already asked for" do
      busy = run([{:match_started, "m1"}])
      assert {_, {:error, :busy}} = Machine.apply(@meta, {:join_match, "m2"}, busy)
      assert {_, {:error, :busy}} = Machine.apply(@meta, {:host, %{seats: 4}}, busy)

      league = run([{:join_league, "season-week3"}])
      assert {_, {:error, :busy}} = Machine.apply(@meta, {:join_match, "m2"}, league)

      asked = run([{:join_match, "m2"}])
      assert {_, {:error, :busy}} = Machine.apply(@meta, {:host, %{seats: 4}}, asked)
    end

    test "leaving before the start doesn't count as a match played" do
      state = run([{:match_started, "m1"}, {:left, "m1"}])
      assert %{match_id: nil, matches_played: 0} = state
      assert run([{:left, "other"}], state) == state
    end

    test "a state saved before these existed still takes them" do
      old = Machine.init(%{matches: 1}) |> Map.drop([:join_match, :host])
      assert %{join_match: "m9"} = run([{:join_match, "m9"}], old)
    end
  end

  test "play asks for more matches" do
    state = run([{:match_started, "m1"}, {:match_finished, "m1"}, {:play, 2}])
    assert %{matches_played: 1, matches_wanted: 3} = state
  end

  describe "claiming a practice match" do
    defp apply_one(cmd, state), do: Machine.apply(@meta, cmd, state)

    test "two leaders in a handover: only the first claim is applied" do
      state = Machine.init(%{matches: 1})
      {state, :ok} = apply_one({:claim_match, "swarm-a"}, state)
      assert {^state, {:error, :taken}} = apply_one({:claim_match, "swarm-b"}, state)

      {state, :ok} = apply_one({:claimed_started, "swarm-a", "m1"}, state)
      assert %{match_id: "m1", creating: nil} = state
    end

    test "a match recorded for a settled claim is refused" do
      state = run([{:claim_match, "swarm-a"}, {:claimed_started, "swarm-a", "m1"}])
      assert {^state, {:error, :not_claimed}} = apply_one({:claimed_started, "swarm-a", "m2"}, state)
      assert {^state, {:error, :not_claimed}} = apply_one({:claimed_started, "swarm-b", "m2"}, state)
    end

    test "nothing to claim once the wanted matches are played" do
      state = run([{:match_started, "m1"}, {:match_finished, "m1"}])
      assert {^state, {:error, :taken}} = apply_one({:claim_match, "swarm-a"}, state)
    end

    test "a failed create releases the claim, a stale failure doesn't" do
      state = run([{:claim_match, "swarm-a"}])
      assert {^state, :ok} = apply_one({:claim_failed, "swarm-b"}, state)
      assert %{creating: nil} = run([{:claim_failed, "swarm-a"}], state)
    end

    test "joining or hosting waits while a match is being created" do
      state = run([{:claim_match, "swarm-a"}])
      assert {_, {:error, :busy}} = apply_one({:join_match, "x"}, state)
    end

    test "a state saved before claims existed can claim" do
      old = Map.delete(Machine.init(%{matches: 1}), :creating)
      assert %{creating: "swarm-a"} = run([{:claim_match, "swarm-a"}], old)
    end
  end

  test "the serum mode: practice games only by default, then on, off or back" do
    assert %{serum_mode: :on} = Machine.init(%{matches: 1})
    assert %{serum_mode: :practice} = run([{:serum_mode, :practice}])
    assert {_, {:error, :unknown_command}} = Machine.apply(@meta, {:serum_mode, :sometimes}, Machine.init(%{}))
  end

  test "becoming leader starts the game loop, anything else stops it" do
    assert [{:mod_call, Swarm.Leader, :lead, []}] = Machine.state_enter(:leader, %{})
    assert [{:mod_call, Swarm.Leader, :follow, []}] = Machine.state_enter(:follower, %{})
  end
end
