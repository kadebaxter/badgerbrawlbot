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

  # While waiting for a league round, how often to check that we are still in that league.
  @league_check_ms 1_000
  require Logger
  alias Swarm.{Brain, Decisions, Match, Metrics, NetRts, Ra, Units, View}

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    send(self(), :start)
    {:ok,
     %{
       client: nil,
       match_id: nil,
       terrain: nil,
       state: nil,
       memory: nil,
       recent: %{},
       idle: false,
       waiting: false,
       mode: nil,
       # Logged as a decision once our first tick commits: only then do we really lead.
       announce: nil,
       # The league round long-poll going on (its ref), or nil: see `{:league_wait, ...}`.
       poll: nil
     }}
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
  # Between league rounds. The server holds the long poll for up to 30 s, so it runs in a process
  # of its own: this one stays free to notice, every `@league_check_ms`, that we left the league
  # (Swarm.leave/0) and go on to whatever comes next (a match to join, say) without waiting for it.
  def handle_info({:league_wait, name, id}, st) do
    if in_league?(name) do
      me = self()
      ref = make_ref()
      client = st.client

      spawn_link(fn ->
        result =
          try do
            NetRts.state(client, id, 0)
          rescue
            e -> {:error, e}
          catch
            :exit, reason -> {:error, reason}
          end

        send(me, {:league_poll, ref, name, id, result})
      end)

      Process.send_after(self(), {:league_check, ref, name}, @league_check_ms)
      {:noreply, %{st | poll: ref}}
    else
      left_league(name, st)
    end
  end

  def handle_info({:league_check, ref, name}, %{poll: ref} = st) do
    if in_league?(name) do
      Process.send_after(self(), {:league_check, ref, name}, @league_check_ms)
      {:noreply, st}
    else
      left_league(name, st)
    end
  end

  # A check or poll result for a wait that is over.
  def handle_info({:league_check, _ref, _name}, st), do: {:noreply, st}
  def handle_info({:league_poll, ref, _name, _id, _result}, %{poll: poll} = st) when ref != poll, do: {:noreply, st}

  def handle_info({:league_poll, _ref, name, id, result}, st) do
    st = %{st | poll: nil}

    case result do
      {:ok, _state} ->
        if in_league?(name), do: round_started(name, id, result, st), else: left_league(name, st)

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

  def handle_info({:wait_start, id, memory}, st) do
    {:ok, shared, _} = Ra.state()

    if shared.match_id != id do
      # We left it (Swarm.leave_match/0) or it was settled elsewhere: back to the start.
      send(self(), :start)
      {:noreply, %{st | waiting: false}}
    else
      case NetRts.state(st.client, id, 0) do
        {:ok, state} ->
          start_playing(id, memory, %{st | waiting: false}, state)

        {:error, %{code: "MATCH_NOT_STARTED"}} ->
          unless st.waiting, do: Logger.info("Waiting for match #{id} to start...")
          send(self(), {:wait_start, id, memory})
          {:noreply, %{st | waiting: true}}

        {:error, %{code: code}} when code in ["MATCH_NOT_FOUND", "NOT_FOUND", "NOT_A_PARTICIPANT"] ->
          # It ended without us (every node was down, say): record it and move on.
          Logger.warning("Match #{id} is no longer live (#{code}); counting it as finished")
          finish(%{st | match_id: id, waiting: false})

        {:error, reason} ->
          Logger.warning("Waiting for match #{id}: #{inspect(reason)}; retrying")
          Process.send_after(self(), {:wait_start, id, memory}, 2_000)
          {:noreply, st}
      end
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

      id = Map.get(shared, :join_match) ->
        join_match(id, st)

      request = Map.get(shared, :host) ->
        host(request, st)

      # A leader claimed a practice match and stopped before recording it: finish the job.
      name = Map.get(shared, :creating) ->
        Logger.info("Match #{shared.matches_played + 1} was claimed as #{name}; looking for it")
        create_claimed(name, shared, st)

      shared.matches_played < shared.matches_wanted ->
        claim_match(shared, st)

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

  # Claim the match in the replicated state before creating it on the server. Only one claim is
  # applied, so two leaders in a handover can't both create one; the loser just starts over.
  defp claim_match(shared, st) do
    name = "swarm-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    case Ra.command({:claim_match, name}) do
      {:ok, :ok, _} ->
        Logger.info("Starting match #{shared.matches_played + 1} of #{shared.matches_wanted} (#{name})")
        create_claimed(name, shared, st)

      {:ok, {:error, :taken}, _} ->
        send(self(), :start)
        {:noreply, st}

      other ->
        Logger.warning("Could not claim a match (#{inspect(other)}); trying again")
        Process.send_after(self(), :start, 1_000)
        {:noreply, st}
    end
  end

  # Find the claimed match by its name (the leader that claimed it may have created it before it
  # stopped), or create it, then record its id.
  defp create_claimed(name, shared, st) do
    opponents = Map.get(shared, :opponents) || Match.config(:opponents)

    found =
      case Match.find(st.client, name) do
        :none -> create_named(st.client, opponents, name)
        other -> other
      end

    case found do
      {:ok, id} ->
        record_claimed(name, id, st)

      {:error, reason} ->
        Logger.error("Could not create match #{name}: #{inspect(reason)}; trying again in 5 s")
        Ra.command({:claim_failed, name})
        Process.send_after(self(), :start, 5_000)
        {:noreply, st}
    end
  end

  # No two unfinished matches share a name (409 MATCH_NAME_TAKEN): if it's taken, the old leader
  # created it after all, between our lookup and our create. That one is ours.
  defp create_named(client, opponents, name) do
    case Match.create(client, opponents, name) do
      {:error, %{code: "MATCH_NAME_TAKEN"}} ->
        case Match.find(client, name) do
          {:ok, id} -> {:ok, id}
          :none -> {:error, :name_taken_but_not_found}
          other -> other
        end

      other ->
        other
    end
  end

  defp record_claimed(name, id, st) do
    case Ra.command({:claimed_started, name, id}) do
      {:ok, :ok, _} ->
        play(id, nil, st)

      {:ok, {:error, :not_claimed}, _} ->
        # Another leader settled the claim first. If it recorded a different match, nobody
        # would play this one: give up our seat in it.
        case Ra.state() do
          {:ok, %{match_id: ^id}, _} ->
            :ok

          _ ->
            Logger.warning("Match #{id} (#{name}) lost the claim to another match; leaving it")
            NetRts.leave(st.client, id)
        end

        send(self(), :start)
        {:noreply, st}

      other ->
        # No majority right now. The command may still be applied; if not, the claim stays and
        # the next try finds this match by its name.
        Logger.warning("Could not record match #{id} (#{inspect(other)}); trying again")
        Process.send_after(self(), :start, 1_000)
        {:noreply, st}
    end
  end

  # Join (again: that is harmless) and wait for a round.
  defp round_started(name, id, {:ok, state}, st) do
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
  end

  # Whether we are still in the league match `name`. If the replicated state can't be read right
  # now, assume we are: keep waiting rather than drop out.
  defp in_league?(name) do
    case Ra.state() do
      {:ok, shared, _} -> Map.get(shared, :league) == name
      _ -> true
    end
  end

  defp left_league(name, st) do
    Logger.info("Left league match #{name}: no longer waiting for its next round")
    send(self(), :start)
    {:noreply, %{st | poll: nil, waiting: false}}
  end

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

  # Join a match by name or id (`Swarm.join/1`). A league match goes to the league flow (every
  # round); any other is played once. A name that isn't there yet is looked for again.
  defp join_match(name_or_id, st) do
    case Match.enter(st.client, name_or_id) do
      {:ok, :joined, id} ->
        Logger.info("Joined match #{name_or_id}; waiting for it to fill and start. Watch: #{Match.config(:server)}/#/match/#{id}")
        {:ok, :ok, _} = Ra.command({:match_started, id})
        play(id, nil, %{st | waiting: false})

      {:ok, :league} ->
        Logger.info("Match #{name_or_id} is a league match: joining it round by round")
        Ra.command({:join_league, name_or_id})
        Ra.command(:request_failed)
        send(self(), :start)
        {:noreply, %{st | waiting: false}}

      # Not created yet (an admin or host about to make it), or a typo: keep looking until
      # `Swarm.leave()`. The server says NOT_FOUND here, though the guide lists MATCH_NOT_FOUND.
      {:error, code, _} when code in ["NOT_FOUND", "MATCH_NOT_FOUND"] ->
        unless st.waiting, do: Logger.warning("No match called #{name_or_id} yet; looking again every 10 s (Swarm.leave() stops)")
        Process.send_after(self(), :start, 10_000)
        {:noreply, %{st | waiting: true}}

      {:error, code, message} ->
        Logger.error("Can't join match #{name_or_id}: #{code}: #{message}")
        Ra.command(:request_failed)
        send(self(), :start)
        {:noreply, %{st | waiting: false}}
    end
  end

  # Create a match others join, and wait for every seat to be taken.
  defp host(request, st) do
    case Match.host(st.client, request) do
      {:ok, id} ->
        {:ok, :ok, _} = Ra.command({:match_started, id})
        play(id, nil, st)

      {:error, code, message} ->
        Logger.error("Can't host a match: #{code}: #{message}")
        Ra.command(:request_failed)
        send(self(), :start)
        {:noreply, st}
    end
  end

  # With a state in hand, play; otherwise wait for the match to start, one long poll at a time
  # (`{:wait_start, ...}`), so a long wait for players never blocks this process.
  defp play(match_id, memory, st, state \\ nil) do
    if state do
      start_playing(match_id, memory, st, state)
    else
      send(self(), {:wait_start, match_id, memory})
      {:noreply, st}
    end
  end

  defp start_playing(match_id, memory, st, state) do
    terrain = Match.terrain!(st.client, match_id)
    send(self(), :tick)

    how = if memory, do: "took over match #{match_id} at tick #{state["tick"]}", else: "started match #{match_id}"

    {:noreply,
     %{
       st
       | match_id: match_id,
         terrain: terrain,
         state: state,
         memory: memory || Brain.new_memory(),
         idle: false,
         announce: "#{node()} #{how}"
     }}
  end

  defp tick(view, st) do
    started = System.monotonic_time(:millisecond)
    {units, recent} = Units.reconcile(view.my_units, view.tick, st.recent)
    {strategy, commands, memory} = Brain.plan(view, st.memory, st.terrain)

    if memory != st.memory, do: Ra.command({:brain, memory})
    planned = System.monotonic_time(:millisecond)

    # Ask every unit, wherever it runs, and give them part of the tick to answer.
    ref = make_ref()
    for {_id, pid} <- units, do: send(pid, {:tick, ref, self(), view, strategy})
    deadline_ms = max(100, div((st.state["tickIntervalMs"] || 1000) * 2, 5))
    replies = collect(ref, map_size(units), System.monotonic_time(:millisecond) + deadline_ms, [])
    answered = System.monotonic_time(:millisecond)
    unit_commands = for {_id, cmd} <- replies, cmd != :no_change, do: cmd

    me = Ra.server_id()

    case Ra.command({:tick_submitted, view.tick}) do
      {:ok, :ok, ^me} ->
        # Team commands last: the latest order for a unit wins, so a builder keeps its Build.
        Match.submit(st.client, st.match_id, view.tick, unit_commands ++ commands)
        send(self(), :poll)

        if rem(view.tick, 10) == 0 do
          done = System.monotonic_time(:millisecond)

          Logger.info(
            "tick #{view.tick} | ore #{view.ore} | #{map_size(units)} units (#{per_node(units)}) | " <>
              "#{strategy.mode}#{wave_info(strategy.wave)} | #{map_size(memory.enemies)} enemy fighters known | " <>
              "#{economy_info(view)} | " <>
              "#{length(replies)}/#{map_size(units)} answered#{hold_info(strategy)}" <>
              timing_info(view, st, done - started, planned - started, answered - planned, deadline_ms, units, replies) <>
              scout_info(view, strategy)
          )
        end

        if st.announce, do: Decisions.log(:leader, view.tick, st.announce)

        for {kind, text} <- Decisions.from_tick(view, strategy, commands, st.mode),
            do: Decisions.log(kind, view.tick, text)

        Metrics.record_tick(%{
          view: view,
          strategy: strategy,
          memory: memory,
          asked: map_size(units),
          answered: length(replies),
          seconds: (System.monotonic_time(:millisecond) - started) / 1000
        })

        {:noreply, %{st | memory: memory, recent: recent, mode: strategy.mode, announce: nil}}

      other ->
        Logger.warning("Lost leadership before tick #{view.tick} (#{inspect(other)}); not sending orders")
        {:stop, :normal, st}
    end
  end

  # The replies that come in before the deadline, as {unit id, command}.
  defp collect(_ref, 0, _deadline, acc), do: acc

  defp collect(ref, waiting, deadline, acc) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:command, ^ref, id, cmd} -> collect(ref, waiting - 1, deadline, [{id, cmd} | acc])
    after
      remaining -> acc
    end
  end

  # How many units each node runs: "swarm-0:26 swarm-1:27 swarm-2:26".
  defp per_node(units) do
    units |> Map.values() |> Enum.frequencies_by(&node/1) |> Enum.sort()
    |> Enum.map_join(" ", fn {n, c} -> "#{host(n)}:#{c}" end)
  end

  # How long this tick took, the part the brain and the units took (against the time units are
  # given), how many units on each node answered in time, and of what type the late ones were:
  # " | took 143ms of 200 (brain 12, units 100 of 100) | on time: swarm-0 0/26 swarm-1 27/27
  # swarm-2 26/26 | late: 4 Soldier, 22 Worker"
  defp timing_info(view, st, total, brain, waited, deadline_ms, units, replies) do
    tick_ms = st.state["tickIntervalMs"] || 1000
    on_time = MapSet.new(replies, &elem(&1, 0))

    by_node =
      units
      |> Enum.group_by(fn {_id, pid} -> node(pid) end, fn {id, _pid} -> id end)
      |> Enum.sort()
      |> Enum.map_join(" ", fn {n, ids} -> "#{host(n)} #{Enum.count(ids, &MapSet.member?(on_time, &1))}/#{length(ids)}" end)

    late =
      for(u <- view.my_units, Map.has_key?(units, u["id"]), not MapSet.member?(on_time, u["id"]), do: u["type"])
      |> Enum.frequencies()
      |> Enum.sort()
      |> Enum.map_join(", ", fn {type, n} -> "#{n} #{type}" end)

    late = if late == "", do: "", else: " | late: " <> late

    " | took #{total}ms of #{tick_ms} (brain #{brain}, units #{waited} of #{deadline_ms}) | on time: #{by_node}" <> late
  end

  # How the economy is doing: "workers 22 (3 idle) | ore in sight 14 (6 in reach)". Ore in reach
  # is within reach of a finished drop-off; all idle with none in sight means nothing left to mine.
  defp economy_info(view) do
    workers = View.units_of(view, "Worker")
    idle = Enum.count(workers, &(&1["activity"] == "Idle"))
    "workers #{length(workers)} (#{idle} idle) | ore in sight #{length(view.deposits)} (#{length(View.near_deposits(view))} in reach)"
  end

  defp finish(st) do
    Ra.command({:match_finished, st.match_id})
    Decisions.log(:match_over, (st.state && st.state["tick"]) || 0, "match #{st.match_id}")
    Match.report(st.client, st.match_id)
    Metrics.clear_game()
    send(self(), :start)
    {:noreply, %{st | match_id: nil, state: nil, recent: %{}, mode: nil}}
  end

  # What each scout is doing and where, e.g. "scouts: 288 wave (51,16), 311 post (40,30) home":
  # "home" means it is by our Command Center, whatever its job.
  defp scout_info(view, strategy) do
    case Swarm.UnitBrain.scout_jobs(view, strategy) do
      [] ->
        ""

      jobs ->
        " | scouts: " <>
          Enum.map_join(jobs, ", ", fn {id, job, {x, y} = pos} ->
            home = if view.cc && View.dist(pos, View.pos(view.cc)) <= 8, do: " home", else: ""
            "#{id} #{job} (#{x},#{y})#{home}"
          end)
    end
  end

  # Why no wave (or no reinforcements) left this tick: see `Swarm.Brain`'s `strategy.hold`.
  defp hold_info(%{hold: hold}) when is_binary(hold), do: " | waiting: " <> hold
  defp hold_info(_strategy), do: ""

  defp wave_info(nil), do: ""
  defp wave_info(%{all_in: true} = wave), do: " (ALL IN: #{length(wave.members)})"
  defp wave_info(wave), do: " (wave #{wave.id}: #{length(wave.members)} out)"

  # "swarm-0" for swarm@swarm-0.swarm.netrts.svc.cluster.local (the pod); the node itself otherwise.
  defp host(node) do
    case node |> to_string() |> String.split(["@", "."]) do
      [_name, host | _] -> host
      [name] -> name
    end
  end
end
