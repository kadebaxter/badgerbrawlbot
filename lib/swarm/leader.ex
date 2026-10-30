defmodule Swarm.Leader do
  @moduledoc """
  Starts the game loop on this node while its ra server is the leader, and stops it otherwise.

  `ra` calls `lead/0` and `follow/0` from inside the ra server (see `Swarm.Machine.state_enter/2`),
  so they only send a message here and return. The ra server must never wait on us.

  Those only fire when leadership changes, so every `@check_ms` it also checks that the leader
  has a game loop: one that crashed too often for its supervisor gets started again.
  """

  use GenServer
  require Logger

  @check_ms 5_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def lead, do: GenServer.cast(__MODULE__, :lead)
  def follow, do: GenServer.cast(__MODULE__, :follow)

  @impl true
  def init(nil) do
    Process.send_after(self(), :check, @check_ms)
    {:ok, nil}
  end

  # The supervisor may have restarted a crashed game loop, so ask it rather than remember a pid.
  @impl true
  def handle_cast(:lead, state) do
    if game_loops() == [] do
      Logger.warning("*** This node is the LEADER: starting the game loop ***")
      {:ok, _pid} = DynamicSupervisor.start_child(Swarm.LeaderSupervisor, Swarm.GameLoop)
    end

    {:noreply, state}
  end

  def handle_cast(:follow, state) do
    for pid <- game_loops() do
      Logger.warning("No longer the leader: stopping the game loop")
      DynamicSupervisor.terminate_child(Swarm.LeaderSupervisor, pid)
    end

    # Game figures are the leader's to report.
    Swarm.Metrics.clear_game()

    {:noreply, state}
  end

  @impl true
  def handle_info(:check, state) do
    leader? =
      try do
        Swarm.Ra.leader?()
      catch
        :exit, _ -> false
      end

    if leader? and game_loops() == [] do
      Logger.warning("Leading without a game loop (it crashed?): starting it again")
      handle_cast(:lead, state)
    end

    Process.send_after(self(), :check, @check_ms)
    {:noreply, state}
  end

  defp game_loops do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Swarm.LeaderSupervisor), is_pid(pid), do: pid
  end
end
