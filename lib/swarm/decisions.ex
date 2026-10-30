defmodule Swarm.Decisions do
  @moduledoc """
  The decision log: one line per decision the team makes, with the reason, e.g.

      decision kind=wave_launched tick=812 msg="wave 3: 15 attackers, strength 14850 vs 6000 known"

  Lines are logfmt, so in Grafana (Loki) `{namespace="netrts"} |= "decision" | logfmt` gives
  `kind`, `tick` and `msg` as fields. Each one also counts in `swarm_decisions_total{kind}`.
  """

  require Logger
  alias Swarm.{Roles, View}

  # Units trained often enough that logging each would drown the rest.
  @routine_units ["Worker", "Soldier", "Archer"]

  def log(kind, tick, text) do
    Swarm.Metrics.inc(:swarm_decisions_total, %{kind: kind})
    Logger.info(line(kind, tick, text))
  end

  def line(kind, tick, text),
    do: ~s(decision kind=#{kind} tick=#{tick} msg="#{String.replace(text, ~s("), "'")}")

  @doc """
  The decisions in one tick: the brain's army notes (`strategy.why`), a change of mode, and the
  team commands worth a line (buildings, research, siege and scouts).
  """
  def from_tick(%View{} = v, strategy, commands, previous_mode) do
    mode =
      if strategy.mode != previous_mode and previous_mode != nil,
        do: [{:mode, "#{previous_mode} -> #{strategy.mode}#{reason(v, strategy)}"}],
        else: []

    orders =
      for c <- commands, entry = order(c), do: entry

    strategy.why ++ mode ++ orders
  end

  defp reason(_v, %{mode: :defend, threat: %{pos: {x, y}, size: n}}),
    do: ": #{n} enemy fighters at the base, closest at (#{x},#{y})"

  defp reason(v, %{mode: :defend}) do
    case Roles.help_wanted(v) do
      [{x, y} | _] -> ": enemies at an outpost, our workers or a siege, at (#{x},#{y})"
      [] -> ""
    end
  end

  defp reason(_v, %{mode: :attack, wave: %{id: id, members: m}}), do: ": wave #{id} out with #{length(m)}"
  defp reason(_v, _strategy), do: ""

  defp order(%{"type" => "Build", "buildingType" => t, "x" => x, "y" => y, "unitIds" => ids}),
    do: {:build, "#{t} at (#{x},#{y}) with #{length(ids)} worker(s)"}

  defp order(%{"type" => "Research", "upgrade" => u}), do: {:research, u}

  defp order(%{"type" => "Produce", "unitType" => t}) when t not in @routine_units,
    do: {:train, t}

  defp order(_command), do: nil
end
