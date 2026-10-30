defmodule Swarm.Match do
  @moduledoc "Match plumbing shared by solo mode and the swarm's game loop."

  require Logger
  alias Swarm.NetRts

  def config(key), do: Application.fetch_env!(:swarm, key)

  @doc "The bot's API key, from NETRTS_API_KEY. The bot is registered once by hand."
  def api_key! do
    case config(:api_key) do
      key when key in [nil, ""] ->
        raise "set NETRTS_API_KEY (in .env, see .env.example) to the key of your registered bot"

      key ->
        key
    end
  end

  @doc "Creates a practice match against house bots (default: the configured ones), one seat each."
  def create!(client, opponents \\ config(:opponents)) do
    settings = if config(:tick_ms), do: %{tickIntervalMs: config(:tick_ms)}, else: %{}
    body = %{houseBots: opponents, maxPlayers: length(opponents) + 1, settings: settings}

    case NetRts.create_match(client, body) do
      {:ok, %{"matchId" => id}} ->
        Logger.info("Created match #{id} vs #{Enum.join(opponents, ", ")}. Watch: #{config(:server)}/#/match/#{id}")
        id

      {:error, reason} ->
        raise "could not create a match: #{inspect(reason)}"
    end
  end

  @doc """
  Joins the league match called `name` and returns its id. Joining again once in is fine, which
  is how a new leader takes over. Errors are the server's codes, e.g. `MATCH_CLOSED` (a round is
  being played; try again between rounds) or `MATCH_FINISHED`.
  """
  def join_league(client, name_or_id) do
    with {:ok, id} <- resolve(client, name_or_id),
         {:ok, _match} <- NetRts.join(client, id) do
      {:ok, id}
    else
      {:error, %{code: code, message: message}} -> {:error, code, message}
      {:error, other} -> {:error, "HTTP_ERROR", inspect(other)}
    end
  end

  # A match id is used as it is; a name is looked up.
  defp resolve(client, name_or_id) do
    if id?(name_or_id) do
      {:ok, name_or_id}
    else
      with {:ok, %{"matchId" => id}} <- NetRts.match_by_name(client, name_or_id), do: {:ok, id}
    end
  end

  @doc "Whether `s` looks like a match id (a UUID)."
  def id?(s), do: is_binary(s) and s =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

  @doc """
  Takes a seat in the match with this id. `{:ok, :league}` if it is a league match (played in
  rounds: join it with `join_league/2` instead), `{:ok, :joined}` once seated (already being
  seated counts), else the server's `{:error, code, message}`.
  """
  def enter(client, id) do
    with {:ok, match} <- NetRts.match(client, id) do
      if match["heats"] != nil do
        {:ok, :league}
      else
        case NetRts.join(client, id) do
          {:ok, _} -> {:ok, :joined}
          {:error, %{code: "ALREADY_JOINED"}} -> {:ok, :joined}
          {:error, %{code: code, message: message}} -> {:error, code, message}
          {:error, other} -> {:error, "HTTP_ERROR", inspect(other)}
        end
      end
    else
      {:error, %{code: code, message: message}} -> {:error, code, message}
      {:error, other} -> {:error, "HTTP_ERROR", inspect(other)}
    end
  end

  @doc """
  Creates a match with `seats` seats that starts once they are all taken: ours, the house bots
  in `bots`, and other people's bots joining by id or by `name`. `{:ok, id}` or
  `{:error, code, message}`.
  """
  def host(client, %{seats: seats} = request) do
    case NetRts.create_match(client, host_body(request)) do
      {:ok, %{"matchId" => id}} ->
        open = seats - 1 - length(Map.get(request, :bots, []))
        named = if request[:name], do: " (named #{request[:name]})", else: ""

        Logger.info(
          "Hosting match #{id}#{named}: #{seats} seats, waiting for #{open} more bot(s). " <>
            "Others join with POST /api/v1/matches/#{id}/join#{if request[:name], do: " or by name", else: ""}. " <>
            "Watch: #{config(:server)}/#/match/#{request[:name] || id}"
        )

        {:ok, id}

      {:error, %{code: code, message: message}} ->
        {:error, code, message}

      {:error, other} ->
        {:error, "HTTP_ERROR", inspect(other)}
    end
  end

  @doc false
  def host_body(request) do
    tick_ms = Application.get_env(:swarm, :tick_ms)
    settings = if tick_ms, do: %{tickIntervalMs: tick_ms}, else: %{}
    body = %{maxPlayers: request.seats, houseBots: Map.get(request, :bots, []), settings: settings}
    if request[:name], do: Map.put(body, :name, request.name), else: body
  end

  @doc """
  Long-polls until the match has started, then returns its current state; `:gone` if the server
  no longer has it live (it ended, e.g. while every node was down).
  """
  def wait_for_start!(client, match_id) do
    case NetRts.state(client, match_id, 0) do
      {:ok, state} ->
        state

      {:error, %{code: code}} when code in ["MATCH_NOT_FOUND", "NOT_FOUND"] ->
        :gone

      {:error, %{code: "MATCH_NOT_STARTED"}} ->
        Logger.info("Waiting for match #{match_id} to start...")
        wait_for_start!(client, match_id)

      {:error, reason} ->
        raise "could not read match #{match_id}: #{inspect(reason)}"
    end
  end

  def terrain!(client, match_id) do
    {:ok, %{"terrain" => terrain}} = NetRts.map(client, match_id)
    terrain
  end

  @doc "Posts commands and logs any that were rejected."
  def submit(_client, _match_id, _tick, []), do: :ok

  def submit(client, match_id, tick, commands) do
    case NetRts.commands(client, match_id, commands) do
      {:ok, %{"results" => results}} ->
        rejected =
          for %{"accepted" => false, "index" => i, "error" => err} <- results do
            Logger.debug("tick #{tick}: rejected #{Enum.at(commands, i)["type"]}: #{err["message"]}")
          end

        Swarm.Metrics.inc(:swarm_commands_total, %{result: "accepted"}, length(results) - length(rejected))
        Swarm.Metrics.inc(:swarm_commands_total, %{result: "rejected"}, length(rejected))
        :ok

      {:error, reason} ->
        Logger.warning("tick #{tick}: commands not sent: #{inspect(reason)}")
        Swarm.Metrics.inc(:swarm_commands_total, %{result: "not_sent"}, length(commands))
        :error
    end
  end

  def report(client, match_id) do
    case NetRts.result(client, match_id) do
      {:ok, %{"outcome" => outcome, "players" => players}} ->
        winner = Enum.find_value(players, "draw", &(&1["winner"] && &1["name"]))

        lines =
          for p <- players do
            s = p["score"]
            total = s["destruction"] + s["economy"] + s["survival"]
            "  #{String.pad_trailing(p["name"], 20)} total #{total}"
          end

        Logger.info(
          "Match over after #{outcome["ticks"]} ticks (#{outcome["reason"]}). Winner: #{winner}\n" <>
            Enum.join(lines, "\n")
        )

      {:error, reason} ->
        Logger.warning("Match over; could not read the result: #{inspect(reason)}")
    end
  end
end
