defmodule Swarm.Metrics do
  @moduledoc """
  Numbers for Prometheus, served at `/metrics` on every node (port `SWARM_METRICS_PORT`, 9568).

  The game loop records the game each tick (`record_tick/1`); only the leader has one, so only
  the leader reports game metrics, and they are cleared when it stops leading. Every node also
  reports its own part of the swarm, worked out when scraped: whether it leads, and how many unit
  processes it runs.

  Values live in an ETS table, so writing one never waits on the scraper.
  """

  use GenServer

  @table :swarm_metrics

  # name => {type, help}
  @metrics %{
    swarm_game_tick: {:gauge, "The game tick the leader last played"},
    swarm_ore: {:gauge, "Ore on hand"},
    swarm_score: {:gauge, "Score total: ours (who=us) and the best opponent's (who=best_enemy)"},
    swarm_units: {:gauge, "Our units by type"},
    swarm_roles: {:gauge, "Our fighters by role"},
    swarm_wave_size: {:gauge, "Members of the wave that is out (0: none)"},
    swarm_wave_id: {:gauge, "Id of the last wave launched"},
    swarm_mode: {:gauge, "1 for the team's current mode"},
    swarm_enemy_fighters_known: {:gauge, "Enemy fighters the leader remembers"},
    swarm_enemy_strength: {:gauge, "Strength (HP x damage per tick) of the remembered enemy army and towers"},
    swarm_tick_seconds: {:gauge, "How long the leader's last tick took, from state read to orders posted"},
    swarm_unit_replies: {:gauge, "Unit processes that answered in time last tick (of swarm_units_asked)"},
    swarm_units_asked: {:gauge, "Unit processes asked for a decision last tick"},
    swarm_ticks_total: {:counter, "Ticks the leader has played"},
    swarm_commands_total: {:counter, "Commands posted to the game, by result"},
    swarm_decisions_total: {:counter, "Decision events, by kind (see Swarm.Decisions)"},
    swarm_is_leader: {:gauge, "1 if this node leads"},
    swarm_unit_processes: {:gauge, "Unit processes running on this node"}
  }

  # Only meaningful while this node runs the game loop.
  @game [
    :swarm_game_tick,
    :swarm_ore,
    :swarm_score,
    :swarm_units,
    :swarm_roles,
    :swarm_wave_size,
    :swarm_wave_id,
    :swarm_mode,
    :swarm_enemy_fighters_known,
    :swarm_enemy_strength,
    :swarm_tick_seconds,
    :swarm_unit_replies,
    :swarm_units_asked
  ]

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  # Without the table (no cluster: tests, `mix swarm.solo`) recording does nothing.
  def set(name, labels \\ %{}, value) do
    if started?(), do: :ets.insert(@table, {{name, labels}, value})
    :ok
  end

  def inc(name, labels \\ %{}, by \\ 1) do
    if started?(), do: :ets.update_counter(@table, {name, labels}, {2, by}, {{name, labels}, 0})
    :ok
  end

  @doc "Forget the game gauges: this node no longer leads, or the match is over."
  def clear_game do
    if started?(), do: for(name <- @game, do: :ets.match_delete(@table, {{name, :_}, :_}))
    :ok
  end

  defp started?, do: :ets.whereis(@table) != :undefined

  @doc """
  Everything the leader knows after a tick, in one go. `info` has the view, strategy, memory,
  how many units were asked and answered, and how long the tick took.
  """
  def record_tick(%{view: v, strategy: s, memory: m} = info) do
    if started?(), do: record(v, s, m, info)
    :ok
  end

  defp record(v, s, m, info) do
    # Gauges with labels are replaced as a set, so a unit type we no longer have drops out.
    for name <- [:swarm_units, :swarm_roles, :swarm_mode, :swarm_score],
        do: :ets.match_delete(@table, {{name, :_}, :_})

    set(:swarm_game_tick, v.tick)
    set(:swarm_ore, v.ore)
    set(:swarm_score, %{who: "us"}, v.my_score)
    set(:swarm_score, %{who: "best_enemy"}, v.enemy_score)
    for {type, n} <- Enum.frequencies_by(v.my_units, & &1["type"]), do: set(:swarm_units, %{type: type}, n)

    for {role, n} <- roles(v, s.wave), do: set(:swarm_roles, %{role: role}, n)

    set(:swarm_mode, %{mode: to_string(s.mode)}, 1)
    set(:swarm_wave_size, if(s.wave, do: length(s.wave.members), else: 0))
    set(:swarm_wave_id, m.next_wave - 1)
    set(:swarm_enemy_fighters_known, map_size(m.enemies))
    set(:swarm_enemy_strength, Swarm.Brain.enemy_strength(v, m))
    set(:swarm_tick_seconds, info.seconds)
    set(:swarm_units_asked, info.asked)
    set(:swarm_unit_replies, info.answered)
    inc(:swarm_ticks_total)
  end

  # Role => how many, worked out once (asking `Swarm.Roles.role/3` per unit would redo it all each time).
  defp roles(v, wave) do
    home = Swarm.Roles.home_roles(v, wave)
    members = if wave, do: wave.members, else: []

    v.my_units
    |> Enum.flat_map(fn u ->
      cond do
        u["type"] == "Worker" -> []
        u["type"] == "Scout" -> ["scout"]
        u["type"] == "Trebuchet" -> ["siege"]
        u["id"] in members -> ["wave"]
        true -> [role_name(Map.get(home, u["id"], :attacker))]
      end
    end)
    |> Enum.frequencies()
  end

  defp role_name({:escort, _}), do: "escort"
  defp role_name(role), do: to_string(role)

  @doc "The Prometheus text format, with this node's own figures added at the time of asking."
  def render do
    node_figures = [
      {{:swarm_is_leader, %{}}, if(leader?(), do: 1, else: 0)},
      {{:swarm_unit_processes, %{}}, unit_processes()}
    ]

    (:ets.tab2list(@table) ++ node_figures)
    |> Enum.group_by(fn {{name, _}, _} -> name end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(fn {name, samples} ->
      {type, help} = Map.fetch!(@metrics, name)

      lines =
        for {{_, labels}, value} <- Enum.sort(samples),
            do: "#{name}#{labels(labels)} #{number(value)}\n"

      "# HELP #{name} #{help}\n# TYPE #{name} #{type}\n" <> Enum.join(lines)
    end)
  end

  defp labels(labels) when labels == %{}, do: ""

  defp labels(labels) do
    inner = Enum.map_join(Enum.sort(labels), ",", fn {k, v} -> ~s(#{k}="#{escape(to_string(v))}") end)
    "{#{inner}}"
  end

  defp escape(s), do: s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")

  defp number(n) when is_integer(n), do: Integer.to_string(n)
  defp number(n) when is_float(n), do: :erlang.float_to_binary(n, [:short])

  defp leader? do
    Swarm.Ra.leader?()
  catch
    :exit, _ -> false
  end

  defp unit_processes do
    DynamicSupervisor.count_children(Swarm.UnitSupervisor).active
  catch
    :exit, _ -> 0
  end
end
