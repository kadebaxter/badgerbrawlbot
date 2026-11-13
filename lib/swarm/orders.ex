defmodule Swarm.Orders do
  @moduledoc """
  What goes to the server this tick. It carries out at most #{100} of our commands a tick: more
  than that in one request and the whole request is turned away; in two requests, the rest wait
  in a queue (500 at most) and run on later ticks, after fresher orders, or are turned away once
  it is full. So no more than that goes out in a tick at all.

  - Units' commands that are the same but for who gets them (twenty Soldiers attack-moving to the
    same spot) go as one, with every unit in `unitIds`.
  - The team's commands (training, building, research) always go, and last: the latest order for
    a unit wins, so a builder keeps its Build.
  - Then the units', most urgent first: a unit with an enemy fighter near (fighting, kiting,
    dodging, running), then an attack on a named target, then a move or an attack-move, then a
    Gather. A unit that has waited moves up a class for every tick it waited, so nothing waits
    for long.

  What doesn't go is not lost: the units cut (`pick/5`'s second answer) are told the next tick
  (`strategy.resend`) and decide again from where they were before (`Swarm.Unit`), so they send
  it again.
  """

  alias Swarm.View

  @limit 100
  # An enemy fighter this close and the unit is in a fight.
  @fight_radius 8

  def limit, do: @limit

  @doc """
  `unit_commands` is `[{unit_id, command}]`, `team` the brain's commands, `waited` unit id =>
  ticks its command has waited. Returns `{commands to send, ids of the units whose command was
  cut}`.
  """
  def pick(unit_commands, team, %View{} = v, waited \\ %{}, limit \\ @limit) do
    team = Enum.take(team, limit)
    room = limit - length(team)
    groups = merge(unit_commands)

    rank = urgency(v, waited)
    {go, cut} = groups |> Enum.sort_by(fn {ids, cmd} -> {ids |> Enum.map(&rank.(&1, cmd)) |> Enum.min(), hd(ids)} end) |> Enum.split(room)

    sent = for {ids, cmd} <- go, do: Map.put(cmd, "unitIds", ids)
    {sent ++ team, cut |> Enum.flat_map(&elem(&1, 0)) |> MapSet.new()}
  end

  @doc "Unit id => ticks waited, after a tick that cut `cut`: one more for those, the rest start over."
  def waited(waited, cut), do: Map.new(cut, &{&1, Map.get(waited, &1, 0) + 1})

  # The same command for several units, as one: `[{unit ids, command}]`, in the order each first
  # came up.
  defp merge(unit_commands) do
    {order, by_key} =
      Enum.reduce(unit_commands, {[], %{}}, fn {id, cmd}, {order, by_key} ->
        key = Map.delete(cmd, "unitIds")

        case by_key do
          %{^key => ids} -> {order, %{by_key | key => [id | ids]}}
          _ -> {[key | order], Map.put(by_key, key, [id])}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&{Enum.sort(by_key[&1]), &1})
  end

  defp urgency(v, waited) do
    enemies = for e <- v.enemy_units, e["type"] != "Worker", do: View.pos(e)
    units = Map.new(v.my_units, &{&1["id"], &1})

    fn id, cmd ->
      unit = units[id]

      fighting? =
        unit != nil and Enum.any?(enemies, &(View.dist(&1, View.pos(unit)) <= @fight_radius))

      class =
        cond do
          fighting? -> 1
          cmd["type"] == "Attack" and Map.has_key?(cmd, "targetId") -> 2
          cmd["type"] in ["Attack", "Move"] -> 3
          true -> 4
        end

      max(1, class - Map.get(waited, id, 0))
    end
  end
end
