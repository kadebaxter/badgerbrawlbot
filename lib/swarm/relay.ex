defmodule Swarm.Relay do
  @moduledoc """
  One per node: hands each tick to the units on this node.

  The leader sends the tick here once, `{:tick, ref, leader_pid, view, strategy, unit_pids}`,
  instead of once to every unit: the view crosses the network once per node, not once per unit.
  The relay works out the team-wide answers once for the node (`Swarm.UnitBrain.prepare/2`: every
  fighter's job, who fights whom, our fighters and theirs, the towers, the raids and where help is
  wanted, home's strength, the drop-offs and each deposit's walk, which ore is unsafe), puts them
  in the view, and sends `{:tick, ref, leader_pid,
  view, strategy}` to each of its units. Each unit still decides for itself and answers the
  leader directly (`Swarm.Unit`).

  Every relay joins the `:relays` process group, so the leader knows which nodes have one; a node
  without one (an older release, during a rolling upgrade) gets the tick sent to each unit, as
  before.
  """

  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "node => this node's relay, for every node that has one."
  def all do
    for pid <- :pg.get_members(:swarm, :relays), into: %{}, do: {node(pid), pid}
  end

  @impl true
  def init(nil) do
    :ok = :pg.join(:swarm, :relays, self())
    {:ok, nil}
  end

  @impl true
  def handle_info({:tick, ref, leader, view, strategy, pids}, state) do
    view = Swarm.UnitBrain.prepare(view, strategy.wave)
    for pid <- pids, do: send(pid, {:tick, ref, leader, view, strategy})
    {:noreply, state}
  end
end
