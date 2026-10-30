defmodule Swarm do
  @moduledoc """
  Helpers to call from `iex` on any node.

      Swarm.status()   # who leads, which nodes are up, how many units each one runs
      Swarm.play()     # play another match
      Swarm.play(opponents: ["balanced", "rusher"])   # ... against these (and from now on)
      Swarm.play(3)    # three more (each call adds to the queue: see Swarm.status())
      Swarm.stop()     # no more matches after the current one
      Swarm.join("season-week3")   # play a league match, round after round, until it closes
      Swarm.leave()    # stop after the current round (back to practice)
      Swarm.client()   # a NetRts client for the configured server and key
      Swarm.enemies()  # the enemy fighters the leader remembers, per opponent
  """

  alias Swarm.{Match, NetRts, Ra, Roles, Units}

  def client, do: NetRts.new(Match.config(:server), Match.api_key!())

  def status do
    leader =
      case Ra.members() do
        {:ok, _members, {_, leader}} -> leader
        other -> "unknown (#{inspect(other)})"
      end

    per_node = Units.running() |> Map.values() |> List.flatten() |> Enum.frequencies_by(&node/1)

    shared =
      case Ra.state() do
        {:ok, s, _} -> s
        _ -> %{}
      end

    IO.puts("""
    leader:  #{leader}
    league:  #{shared[:league] || "none"}
    match:   #{shared[:match_id] || "none"}  (played #{shared[:matches_played]} of #{shared[:matches_wanted]})
    nodes:
    #{Enum.map_join(Units.nodes(), "\n", &"  #{&1}#{if &1 == leader, do: " ★", else: ""}  #{Map.get(per_node, &1, 0)} units")}
    """)
  end

  @doc """
  Joins the league match called `name` (as the admin named it) and plays every round until the
  admin closes it. Goes through the replicated state, so whichever node leads does the joining,
  and a new leader carries on. The bot must be Discord-verified.
  """
  def join(name) when is_binary(name) do
    {:ok, :ok, _leader} = Ra.command({:join_league, name})
    :ok
  end

  @doc "No more practice matches after the one being played: clears the queue `play` built up."
  def stop do
    {:ok, :ok, _leader} = Ra.command(:stop)
    :ok
  end

  @doc "Stops playing the league match once the current round is over."
  def leave do
    case Ra.state() do
      {:ok, %{league: name}, _} when is_binary(name) ->
        {:ok, :ok, _} = Ra.command({:league_over, name})
        :ok

      _ ->
        {:error, :not_in_a_league}
    end
  end

  @doc """
  The enemy fighters the leader remembers (it only knows what our units have seen), per
  opponent slot: how many of each type, their strength, and how long ago they were last seen.
  """
  def enemies do
    case Ra.state() do
      {:ok, %{brain: %{enemies: enemies}, last_tick: tick}, _leader} -> IO.puts(enemy_report(enemies, tick))
      {:ok, _state, _leader} -> IO.puts("no enemy fighters seen yet")
      other -> IO.puts("can't read the replicated state: #{inspect(other)}")
    end
  end

  @doc false
  def enemy_report(enemies, _tick) when enemies == %{}, do: "no enemy fighters seen yet"

  def enemy_report(enemies, tick) do
    enemies
    |> Map.values()
    |> Enum.group_by(& &1["owner"])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("\n", fn {owner, units} ->
      types = units |> Enum.frequencies_by(& &1["type"]) |> Enum.map_join(", ", fn {t, n} -> "#{n} #{t}" end)
      ages = Enum.map(units, &(tick - &1["seen"]))

      "player #{owner}: #{length(units)} (#{types}), strength #{round(Roles.strength(units))}, " <>
        "seen #{Enum.min(ages)}-#{Enum.max(ages)} ticks ago"
    end)
  end

  @doc """
  Asks the leader to play `n` more matches. `opponents:` sets the house bots, one seat each,
  for these and later matches; the setting lives in the replicated state, so it holds whichever
  node leads.
  """
  def play, do: play(1, [])
  def play(opts) when is_list(opts), do: play(1, opts)
  def play(n) when is_integer(n), do: play(n, [])

  def play(n, opts) do
    {:ok, :ok, _leader} = Ra.command({:play, n, opts[:opponents]})
    :ok
  end
end
