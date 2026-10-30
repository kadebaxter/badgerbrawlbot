defmodule Swarm.Machine do
  @moduledoc """
  The replicated state machine that `ra` runs on every node.

  Every node holds the same copy, and a command only changes it once a majority of nodes have
  it. That makes it the team's shared memory: which match we're playing, the leader's brain
  memory, the last tick we sent orders for. A new leader reads it and carries on.

  `apply/3` is pure. `state_enter/2` is how a node finds out it has become (or stopped being)
  the leader.
  """

  @behaviour :ra_machine

  @impl true
  def init(config) do
    %{
      match_id: nil,
      brain: nil,
      last_tick: 0,
      matches_wanted: Map.get(config, :matches, 1),
      matches_played: 0,
      # House bots to play from now on, set by `Swarm.play/2`; nil means the configured ones.
      opponents: nil,
      # The league match we are in (its name), set by `Swarm.join/1`. It comes before practice.
      league: nil
    }
  end

  @impl true
  def apply(_meta, {:match_started, id}, state),
    do: {%{state | match_id: id, brain: nil, last_tick: 0}, :ok}

  def apply(_meta, {:match_finished, id}, %{match_id: id} = state),
    do: {%{state | match_id: nil, matches_played: state.matches_played + 1}, :ok}

  def apply(_meta, {:match_finished, _other}, state), do: {state, :ok}

  def apply(_meta, {:brain, memory}, state), do: {%{state | brain: memory}, :ok}

  # Committing this before posting orders is the fence: a leader that has lost its majority
  # can't commit, so it can't send stale orders.
  def apply(meta, {:tick_submitted, tick}, state) do
    state = %{state | last_tick: max(tick, state.last_tick)}

    # Let ra drop old log entries now and then; the state is tiny.
    if rem(meta.index, 500) == 0,
      do: {state, :ok, [{:release_cursor, meta.index, state}]},
      else: {state, :ok}
  end

  def apply(_meta, {:play, n}, state), do: {play(state, n, nil), :ok}
  def apply(_meta, {:play, n, opponents}, state), do: {play(state, n, opponents), :ok}

  # No more matches after the one being played, if any.
  def apply(_meta, :stop, state) do
    current = if state.match_id, do: 1, else: 0
    {%{state | matches_wanted: state.matches_played + current}, :ok}
  end

  def apply(_meta, {:join_league, name}, state), do: {Map.put(state, :league, name), :ok}

  # The league is over (or we left it): no more rounds. A heat being played is finished first.
  def apply(_meta, {:league_over, name}, state) do
    if Map.get(state, :league) == name,
      do: {Map.put(state, :league, nil), :ok},
      else: {state, :ok}
  end

  def apply(_meta, _unknown, state), do: {state, {:error, :unknown_command}}

  # Map.put, not %{state | ...}: a state saved by an older version has no :opponents yet.
  defp play(state, n, opponents) do
    state = %{state | matches_wanted: max(state.matches_wanted, state.matches_played) + n}
    if opponents, do: Map.put(state, :opponents, opponents), else: state
  end

  @impl true
  def state_enter(:leader, _state), do: [{:mod_call, Swarm.Leader, :lead, []}]
  def state_enter(_role, _state), do: [{:mod_call, Swarm.Leader, :follow, []}]
end
