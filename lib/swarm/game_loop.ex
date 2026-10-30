defmodule Swarm.GameLoop do
  @moduledoc """
  The leader's job, running only on the node whose ra server leads (see `Swarm.Leader`).

  Every tick:

    1. read the game state (long-poll for the next tick)
    2. make the unit processes match the game (`Swarm.Units.reconcile/3`)
    3. decide the team strategy and the building orders (`Swarm.Brain`)
    4. send every unit the state and strategy, and collect their commands until a deadline
    5. commit `{:tick_submitted, tick}` through ra: if that fails we are no longer leader, stop
    6. post the commands to NetRTS

  It keeps nothing that isn't also in the replicated state, so a new leader on another node
  picks up the same match where this one stopped.

  A league match (`Swarm.join/1`) comes before practice. It is played in rounds of heats: join,
  long-poll for the round to start, play the heat, and wait for the next round, until the admin
  closes the match. Every heat has its own map and starts with a fresh brain.
  """

  use GenServer, restart: :transient
  require Logger
  alias Swarm.{Brain, Match, NetRts, Ra, Units, View}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    send(self(), :start)
    {:ok, %{client: nil, match_id: nil, terrain: nil, state: nil, memory: nil, recent: %{}, idle: false, waiting: false}}
  end

  @impl true
  def handle_info(:start, st) do
    case Ra.state() do
      {:ok, shared, _leader} ->
        start(shared, st)

      other ->
        Logger.info("waiting for the replicated state: #{inspect(other)}")
        Process.send_after(self(), :start, 500)
        {:noreply, st}
    end
  end

  def handle_info(:tick, st) do
    view = View.new(st.state)

    if View.completed?(view) do
      finish(st)
    else
      tick(view, st)
    end
  end

  def handle_info(:poll, st) do
    tick = st.state["tick"]

    case NetRts.state(st.client, st.match_id, tick + 1, tick) do
      {:ok, next} ->
        send(self(), :tick)
        {:noreply, %{st | state: next}}

      {:error, reason} ->
        Logger.warning("could not read tick #{tick + 1}: #{inspect(reason)}; retrying")
        Process.send_after(self(), :poll, 500)
        {:noreply, st}
    end
  end

  # Between league rounds: one long poll at a time (the server holds it), so this process stays
  # responsive and can be stopped if we lose leadership.
  def handle_info({:league_wait, name, id}, st) do
    case NetRts.state(st.client, id, 0) do
      {:ok, state} ->
        {:ok, shared, _} = Ra.state()

        # The same heat we were playing when the old leader stopped: carry on with its brain. A
        # new round starts its tick over, so an earlier tick means a heat that ended without us.
        memory =
          if shared.match_id == id and state["tick"] >= shared.last_tick do
            Logger.info("Resuming the heat in league match #{name}")
            shared.brain
          else
            Logger.info("League match #{name}: a round has started")
            {:ok, :ok, _} = Ra.command({:match_started, id})
            nil
          end

        play(id, memory, %{st | waiting: false}, state)

      {:error, %{code: "MATCH_NOT_STARTED"}} ->
        unless st.waiting, do: Logger.info("League match #{name}: waiting for the admin to start the round...")
        send(self(), {:league_wait, name, id})
        {:noreply, %{st | waiting: true}}

      {:error, %{code: "MATCH_FINISHED"}} ->
        Logger.warning("League match #{name} is closed: no more rounds")
        Ra.command({:league_over, name})
        send(self(), :start)
        {:noreply, %{st | waiting: false}}

      {:error, reason} ->
        Logger.warning("League match #{name}: #{inspect(reason)}; retrying")
        Process.send_after(self(), {:league_wait, name, id}, 2_000)
        {:noreply, st}
    end
  end

  # A unit that answered after the deadline.
  def handle_info({:command, _ref, _id, _cmd}, st), do: {:noreply, st}

  defp start(shared, st) do
    client = NetRts.new(Match.config(:server), Match.api_key!())
    st = %{st | client: client}

    cond do
      Map.get(shared, :league) ->
        league(shared.league, st)

      shared.match_id ->
        Logger.info("Resuming match #{shared.match_id}")
        play(shared.match_id, shared.brain, st)

      shared.matches_played < shared.matches_wanted ->
        Logger.info("Starting match #{shared.matches_played + 1} of #{shared.matches_wanted}")
        id = Match.create!(client, Map.get(shared, :opponents) || Match.config(:opponents))
        {:ok, :ok, _} = Ra.command({:match_started, id})
        play(id, nil, st)

      true ->
        unless st.idle do
          Logger.info(
            "Played #{shared.matches_played} match(es); idle. Run Swarm.play() to play another."
          )
        end

        Process.send_after(self(), :start, 2_000)
        {:noreply, %{st | idle: true}}
    end
  end

  # Join (again: that is harmless) and wait for a round.
  defp league(name, st) do
    case Match.join_league(st.client, name) do
      {:ok, id} ->
        send(self(), {:league_wait, name, id})
        {:noreply, st}

      {:error, "MATCH_CLOSED", _} ->
        unless st.waiting, do: Logger.info("League match #{name}: a round is on; joining once it ends...")
        Process.send_after(self(), :start, 5_000)
        {:noreply, %{st | waiting: true}}

      # Not created yet, or a typo: keep looking (`Swarm.leave()` stops it). The server says
      # NOT_FOUND here, though the guide lists MATCH_NOT_FOUND.
      {:error, code, _} when code in ["NOT_FOUND", "MATCH_NOT_FOUND"] ->
        unless st.waiting, do: Logger.warning("No league match called #{name} yet; looking again every 10 s")
        Process.send_after(self(), :start, 10_000)
        {:noreply, %{st | waiting: true}}

      {:error, code, message} when code in ["MATCH_FINISHED", "NOT_VERIFIED", "OWNER_ALREADY_JOINED"] ->
        Logger.error("Can't join league match #{name}: #{code}: #{message}")
        Ra.command({:league_over, name})
        send(self(), :start)
        {:noreply, st}

      {:error, code, message} ->
        Logger.warning("Joining league match #{name}: #{code}: #{message}; retrying")
        Process.send_after(self(), :start, 5_000)
        {:noreply, st}
    end
  end

  defp play(match_id, memory, st, state \\ nil) do
    case state || Match.wait_for_start!(st.client, match_id) do
      :gone ->
        # It ended without us (every node was down, say): record it and move on.
        Logger.warning("Match #{match_id} is no longer live; counting it as finished")
        finish(%{st | match_id: match_id})

      state ->
        start_playing(match_id, memory, st, state)
    end
  end

  defp start_playing(match_id, memory, st, state) do
    terrain = Match.terrain!(st.client, match_id)
    send(self(), :tick)

    {:noreply,
     %{st | match_id: match_id, terrain: terrain, state: state, memory: memory || Brain.new_memory(), idle: false}}
  end

  defp tick(view, st) do
    {units, recent} = Units.reconcile(view.my_units, view.tick, st.recent)
    {strategy, commands, memory} = Brain.plan(view, st.memory, st.terrain)

    if memory != st.memory, do: Ra.command({:brain, memory})

    # Ask every unit, wherever it runs, and give them part of the tick to answer.
    ref = make_ref()
    for {_id, pid} <- units, do: send(pid, {:tick, ref, self(), view, strategy})
    deadline_ms = max(100, div((st.state["tickIntervalMs"] || 1000) * 2, 5))
    replies = collect(ref, map_size(units), System.monotonic_time(:millisecond) + deadline_ms, [])
    unit_commands = Enum.reject(replies, &(&1 == :no_change))

    if rem(view.tick, 10) == 0 do
      per_node =
        units |> Map.values() |> Enum.frequencies_by(&node/1)
        |> Enum.map_join(" ", fn {n, c} -> "#{short(n)}:#{c}" end)

      Logger.info(
        "tick #{view.tick} | ore #{view.ore} | #{map_size(units)} units (#{per_node}) | " <>
          "#{strategy.mode}#{wave_info(strategy.wave)} | #{map_size(memory.enemies)} enemy fighters known | " <>
          "#{length(replies)}/#{map_size(units)} answered"
      )
    end

    me = Ra.server_id()

    case Ra.command({:tick_submitted, view.tick}) do
      {:ok, :ok, ^me} ->
        # Team commands last: the latest order for a unit wins, so a builder keeps its Build.
        Match.submit(st.client, st.match_id, view.tick, unit_commands ++ commands)
        send(self(), :poll)
        {:noreply, %{st | memory: memory, recent: recent}}

      other ->
        Logger.warning("Lost leadership before tick #{view.tick} (#{inspect(other)}); not sending orders")
        {:stop, :normal, st}
    end
  end

  defp collect(_ref, 0, _deadline, acc), do: acc

  defp collect(ref, waiting, deadline, acc) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:command, ^ref, _id, cmd} -> collect(ref, waiting - 1, deadline, [cmd | acc])
    after
      remaining -> acc
    end
  end

  defp finish(st) do
    Ra.command({:match_finished, st.match_id})
    Match.report(st.client, st.match_id)
    send(self(), :start)
    {:noreply, %{st | match_id: nil, state: nil, recent: %{}}}
  end

  defp wave_info(nil), do: ""
  defp wave_info(%{all_in: true} = wave), do: " (ALL IN: #{length(wave.members)})"
  defp wave_info(wave), do: " (wave #{wave.id}: #{length(wave.members)} out)"

  defp short(node), do: node |> to_string() |> String.split("@") |> hd()
end
