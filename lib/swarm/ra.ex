defmodule Swarm.Ra do
  @moduledoc """
  Starts this node's member of the Raft cluster and wraps the few `ra` calls we use.

  Each node runs one ra server, `{:swarm_ra, node()}`, and the members are the nodes listed in
  `SWARM_PEERS`. The log lives in `data/<node>/`, so a restarted node rejoins with its history.
  A leader is elected once a majority of members is up.
  """

  use GenServer
  require Logger

  @system :swarm
  # Not :swarm, which is the :pg scope's registered name.
  @cluster :swarm_ra

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def server_id(node \\ node()), do: {@cluster, node}

  @doc "Commits a command through the leader. `{:ok, reply, leader_id}` once a majority has it."
  def command(cmd, timeout \\ 2_000), do: :ra.process_command(server_id(), cmd, timeout)

  @doc "The replicated state, read through the leader."
  # ra 3 takes a query as {module, function, args}; it calls it with the state appended.
  def state(timeout \\ 2_000),
    do: :ra.consistent_query(server_id(), {Function, :identity, []}, timeout)

  @doc "`{:ok, members, leader_id}`, as this node sees it."
  def members(timeout \\ 1_000), do: :ra.members(server_id(), timeout)

  def leader? do
    match?({:ok, _, {_, n}} when n == node(), members())
  end

  @impl true
  def init(nil) do
    data_dir = Application.fetch_env!(:swarm, :data_dir)
    peers = Application.fetch_env!(:swarm, :peers)
    File.mkdir_p!(data_dir)

    :ok = start_system(data_dir)
    :ok = start_server(peers)

    # Lets the leader find every node it can place units on.
    :ok = :pg.join(:swarm, :nodes, self())

    Logger.info("ra server #{inspect(server_id())} up; members: #{inspect(peers)}")
    {:ok, peers}
  end

  defp start_system(data_dir) do
    dir = String.to_charlist(data_dir)

    config =
      Map.merge(:ra_system.default_config(), %{
        name: @system,
        names: :ra_system.derive_names(@system),
        data_dir: dir,
        wal_data_dir: dir
      })

    case :ra_system.start(config) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp start_server(peers) do
    id = server_id()

    case :ra.restart_server(@system, id) do
      :ok ->
        Logger.info("Restarted ra server from its log")
        :ok

      {:error, _not_started_before} ->
        uid = "swarm_" <> String.replace(to_string(node()), ~r/[^A-Za-z0-9_-]/, "_")

        config = %{
          id: id,
          uid: uid,
          cluster_name: @cluster,
          log_init_args: %{uid: uid},
          initial_members: Enum.map(peers, &server_id/1),
          machine: {:module, Swarm.Machine, %{matches: Application.fetch_env!(:swarm, :matches)}}
        }

        case :ra.start_server(@system, config) do
          # A brand-new ra server never starts an election by itself (restarted ones do), so
          # ask for one. If the other members aren't up yet, the candidate keeps retrying.
          :ok -> :ra.trigger_election(id)
          {:error, {:already_started, _}} -> :ok
        end
    end
  end
end
