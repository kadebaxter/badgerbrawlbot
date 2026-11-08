defmodule Swarm.Units do
  @moduledoc """
  Keeps one unit process per game unit, spread over the nodes. Run by the leader every tick.

  | Game says        | Processes say      | Action                                      |
  |------------------|--------------------|---------------------------------------------|
  | we own unit 88   | no process for 88  | start one on the node with the fewest units per core |
  | unit 31 is gone  | process 31 exists  | stop it                                     |
  | we own unit 32   | one process for 32 | nothing                                     |

  The same rule covers newly trained units, units that died, and units orphaned when a node went
  down.
  """

  require Logger

  # :pg spreads group changes asynchronously, so remember our own spawns for a few ticks.
  @spawn_grace_ticks 3

  @doc "unit id => [pid], for every unit process in the cluster."
  def running do
    for {:unit, id} = group <- :pg.which_groups(:swarm),
        pid <- :pg.get_members(:swarm, group),
        reduce: %{} do
      acc -> Map.update(acc, id, [pid], &[pid | &1])
    end
  end

  @doc "Nodes that can host units."
  def nodes, do: :swarm |> :pg.get_members(:nodes) |> Enum.map(&node/1) |> Enum.uniq() |> Enum.sort()

  @doc """
  Makes the unit processes match `my_units` (from the game state).
  `recent` is `%{id => {pid, tick}}` of our own spawns. Returns `{%{id => pid}, recent}`.
  """
  def reconcile(my_units, tick, recent) do
    running = running()
    wanted = Map.new(my_units, &{&1["id"], &1["type"]})

    # Units that died in the game: stop their processes.
    for {id, pids} <- running, not Map.has_key?(wanted, id), pid <- pids, do: stop(pid)

    # Two processes for one unit (e.g. after a partition heals): keep one.
    alive =
      for {id, [keep | extra]} <- running, Map.has_key?(wanted, id), into: %{} do
        Enum.each(extra, &stop/1)
        {id, keep}
      end

    recent =
      for {id, {pid, at}} <- recent,
          not Map.has_key?(alive, id),
          Map.has_key?(wanted, id),
          tick - at <= @spawn_grace_ticks,
          into: %{},
          do: {id, {pid, at}}

    known = Map.merge(alive, Map.new(recent, fn {id, {pid, _}} -> {id, pid} end))

    {known, recent} =
      wanted
      |> Enum.reject(fn {id, _type} -> Map.has_key?(known, id) end)
      |> Enum.sort()
      |> Enum.reduce({known, recent}, fn {id, type}, {known, recent} ->
        case start(id, type, least_loaded(known)) do
          {:ok, pid} -> {Map.put(known, id, pid), Map.put(recent, id, {pid, tick})}
          :error -> {known, recent}
        end
      end)

    {known, recent}
  end

  # The node with the fewest units per core (`pick_node/3`).
  defp least_loaded(known) do
    on = nodes()
    load = known |> Map.values() |> Enum.frequencies_by(&node/1)
    pick_node(on, load, Map.new(on, &{&1, cores(&1)})) || node()
  end

  @doc """
  Where a new unit goes: the node with the fewest units per core (`cores`: node => cores), so a
  4-core machine carries a quarter of what a 16-core one does, not the same third. Every late
  answer in our big games came from the 4-core one while each node had a third of the units.
  Ties go to the first node by name. Nil with no nodes.
  """
  def pick_node(nodes, load, cores) do
    Enum.min_by(nodes, &{Map.get(load, &1, 0) / max(Map.get(cores, &1, 1), 1), &1}, fn -> nil end)
  end

  # How many cores a node has (its BEAM's schedulers), asked once and kept; 1 if it can't be asked.
  defp cores(on_node) do
    key = {__MODULE__, :cores, on_node}

    case :persistent_term.get(key, nil) do
      nil ->
        cores =
          try do
            :erpc.call(on_node, System, :schedulers_online, [], 1_000)
          catch
            _, _ -> nil
          end

        if is_integer(cores) and cores > 0 do
          :persistent_term.put(key, cores)
          cores
        else
          1
        end

      cores ->
        cores
    end
  end

  defp start(id, type, on_node) do
    case DynamicSupervisor.start_child({Swarm.UnitSupervisor, on_node}, {Swarm.Unit, {id, type}}) do
      {:ok, pid} -> {:ok, pid}
      other ->
        Logger.warning("could not start unit #{id} on #{on_node}: #{inspect(other)}")
        :error
    end
  catch
    :exit, reason ->
      Logger.warning("could not start unit #{id} on #{on_node}: #{inspect(reason)}")
      :error
  end

  defp stop(pid) do
    DynamicSupervisor.terminate_child({Swarm.UnitSupervisor, node(pid)}, pid)
  catch
    :exit, _ -> :ok
  end
end
