defmodule Swarm.MetricsTest do
  # The metrics table is one named ETS table for the whole node.
  use ExUnit.Case, async: false
  import Swarm.Test.GameState
  alias Swarm.{Brain, Metrics, View}

  setup do
    start_supervised!(Metrics)
    :ok
  end

  test "renders the Prometheus text format, with HELP and TYPE once per metric" do
    Metrics.set(:swarm_units, %{type: "Soldier"}, 4)
    Metrics.set(:swarm_units, %{type: "Archer"}, 2)
    Metrics.inc(:swarm_ticks_total)
    Metrics.inc(:swarm_ticks_total)

    text = Metrics.render()
    assert text =~ ~s(# TYPE swarm_units gauge\nswarm_units{type="Archer"} 2\nswarm_units{type="Soldier"} 4\n)
    assert text =~ "# TYPE swarm_ticks_total counter\nswarm_ticks_total 2\n"
    # This node's own figures are always there.
    assert text =~ "swarm_is_leader 0\n"
  end

  test "a tick's figures, and they go when the game does" do
    v = View.new(state(units: workers(3) ++ soldiers(22), ore: 420, tick: 300))
    {strategy, _, memory} = Brain.plan(v, looked(nil, 1, 300), terrain())
    Metrics.record_tick(%{view: v, strategy: strategy, memory: memory, asked: 23, answered: 22, seconds: 0.25})

    text = Metrics.render()
    assert text =~ "swarm_ore 420\n"
    assert text =~ ~s(swarm_units{type="Worker"} 3\n)
    assert text =~ ~s(swarm_roles{role="wave"} 15\n)
    assert text =~ "swarm_wave_size 15\n"
    assert text =~ "swarm_tick_seconds 0.25\n"

    Metrics.clear_game()
    refute Metrics.render() =~ "swarm_ore"
  end

  test "every job at home has a name: a tick with a field's guard out is recorded like any other" do
    v = %{View.new(state(units: workers(3) ++ soldiers(22), ore: 420, tick: 300)) | claim: {34, 34}, claim_guard: [201, 202, 203]}
    assert Swarm.Roles.home_roles(v, nil)[201] == {:field, {34, 34}}
    {strategy, _, memory} = Brain.plan(v, looked(nil, 1, 300), terrain())
    assert :ok = Metrics.record_tick(%{view: v, strategy: strategy, memory: memory, asked: 25, answered: 25, seconds: 0.1})

    text = Metrics.render()
    assert text =~ ~s(swarm_roles{role="field"} 3\n)
    assert text =~ "swarm_game_tick 300\n"
  end

  test "figures that can't be worked out never take the tick down with them" do
    import ExUnit.CaptureLog
    v = View.new(state(units: workers(3) ++ soldiers(22), ore: 420, tick: 300))
    {strategy, _, memory} = Brain.plan(v, looked(nil, 1, 300), terrain())
    broken = %{strategy | mode: {:not, :a, :name}}

    log = capture_log(fn -> assert :ok = Metrics.record_tick(%{view: v, strategy: broken, memory: memory, asked: 25, answered: 25, seconds: 0.1}) end)
    assert log =~ "metrics: tick 300 not recorded"
  end
end
