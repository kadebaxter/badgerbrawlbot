defmodule Swarm.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:swarm, :start_cluster, true), do: cluster_children(), else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: Swarm.Supervisor)
  end

  defp cluster_children do
    if node() == :nonode@nohost do
      raise """
      the swarm needs a named node. Start it with scripts/node.sh a (or iex --sname a -S mix),
      or run the non-distributed bot with mix swarm.solo.
      """
    end

    # Any node can become leader, so every node needs the key; fail now rather than at election.
    Swarm.Match.api_key!()

    # /metrics and /health; port 0 turns it off.
    metrics =
      case Application.get_env(:swarm, :metrics_port, 9568) do
        0 -> []
        port -> [{Bandit, plug: Swarm.MetricsPlug, scheme: :http, port: port}]
      end

    # The figures /metrics serves, first: everything after it records into them.
    [Swarm.Metrics] ++
      metrics ++
      [
        # Find and connect the other nodes.
        {Cluster.Supervisor, [Application.get_env(:libcluster, :topologies, []), [name: Swarm.ClusterSupervisor]]},
        # Cluster-wide process groups: :nodes, :units, {:unit, id}.
        %{id: :pg, start: {:pg, :start_link, [:swarm]}},
        # Unit processes the leader placed on this node.
        {DynamicSupervisor, name: Swarm.UnitSupervisor, strategy: :one_for_one},
        # The game loop, while this node leads.
        {DynamicSupervisor, name: Swarm.LeaderSupervisor, strategy: :one_for_one},
        Swarm.Leader,
        # This node's ra server; last, because becoming leader starts the game loop.
        Swarm.Ra
      ]
  end
end
