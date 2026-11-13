defmodule Swarm.Unit do
  @moduledoc """
  One game unit, as one process. It lives on whichever node the leader placed it on.

  Each tick its node's relay (`Swarm.Relay`, which got the tick from the leader once for the whole
  node) sends `{:tick, ref, leader_pid, view, strategy}`; the unit decides for itself and answers
  the leader `{:command, ref, unit_id, command | :no_change}`. That is the only way it
  talks to anyone: no shared memory, and the same `send/2` whether the leader is on this machine
  or another.

  Between ticks it keeps its own memory (the order it is carrying out, see `Swarm.UnitBrain`).
  It also keeps the memory it had before its last decision: when the leader didn't send that
  command (it was cut, see `Swarm.Orders`, or came too late), the next tick says so
  (`strategy.resend`) and the unit decides again from there. Otherwise it would think the order
  went out and keep quiet, carrying on with the old one.
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
    memory = Swarm.UnitBrain.new_memory()
    {:ok, %{id: id, type: type, memory: memory, before: memory}}
  end

  @impl true
  def handle_info({:tick, ref, leader, view, strategy}, state) do
    memory = if resend?(strategy, state.id), do: Map.get(state, :before, state.memory), else: state.memory
    {cmd, next} = Swarm.UnitBrain.decide(state.id, view, strategy, memory)
    send(leader, {:command, ref, state.id, cmd})
    {:noreply, %{state | memory: next, before: memory}}
  end

  @doc "Whether the leader didn't send this unit's last command (`strategy.resend`)."
  def resend?(strategy, id) do
    case Map.get(strategy, :resend) do
      %MapSet{} = ids -> MapSet.member?(ids, id)
      _ -> false
    end
  end
end
