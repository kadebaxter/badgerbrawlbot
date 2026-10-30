defmodule Swarm.Unit do
  @moduledoc """
  One game unit, as one process. It lives on whichever node the leader placed it on.

  Each tick the leader sends `{:tick, ref, leader_pid, view, strategy}`; the unit decides for
  itself and answers `{:command, ref, unit_id, command | :no_change}`. That is the only way it
  talks to anyone: no shared memory, and the same `send/2` whether the leader is on this machine
  or another.

  Between ticks it keeps its own memory (the order it is carrying out, see `Swarm.UnitBrain`).
  """

  use GenServer, restart: :transient
  require Logger

  def start_link({id, type}), do: GenServer.start_link(__MODULE__, {id, type})

  @impl true
  def init({id, type}) do
    # Cluster-wide groups: every unit, and this unit by id (how the leader finds it).
    :ok = :pg.join(:swarm, :units, self())
    :ok = :pg.join(:swarm, {:unit, id}, self())
    Logger.info("#{type} #{id} now controlled from #{node()}")
    {:ok, %{id: id, type: type, memory: Swarm.UnitBrain.new_memory()}}
  end

  @impl true
  def handle_info({:tick, ref, leader, view, strategy}, state) do
    {cmd, memory} = Swarm.UnitBrain.decide(state.id, view, strategy, state.memory)
    send(leader, {:command, ref, state.id, cmd})
    {:noreply, %{state | memory: memory}}
  end
end
