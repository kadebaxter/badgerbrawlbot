defmodule Swarm.GroupFightSpeedTest do
  @moduledoc """
  The team's answers for a big game, timed: on its own (not async), so the other tests don't
  share the CPU with it.
  """
  use ExUnit.Case, async: false
  import Swarm.Test.GameState
  alias Swarm.{UnitBrain, View}

  @gather %{mode: :gather, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}

  describe "speed" do
    test "300 of ours against 100 of theirs: the team's answers and every decision well inside a tick" do
      ours =
        for i <- 1..300 do
          type = if rem(i, 3) == 0, do: "Archer", else: "Soldier"
          unit(1000 + i, type, 5 + rem(i, 25), 5 + div(i, 25))
        end

      theirs =
        for i <- 1..100 do
          type = if rem(i, 2) == 0, do: "Archer", else: "Soldier"
          # Four packs.
          {x, y} = Enum.at([{30, 10}, {40, 30}, {15, 40}, {50, 50}], rem(i, 4))
          unit(5000 + i, type, x + rem(i, 3), y + rem(div(i, 3), 3), owner: 1)
        end

      workers = for i <- 1..60, do: unit(100 + i, "Worker", 8 + rem(i, 5), 8, activity: "Gathering", target_id: 4)
      wave = %{id: 1, members: Enum.map(Enum.take(ours, 120), & &1["id"])}
      v = View.new(state(units: ours ++ theirs ++ workers))

      # Once per node per tick.
      {prepare_us, shared} = :timer.tc(fn -> UnitBrain.prepare(v, wave) end)
      # Every unit on the node, each on its own.
      strategy = %{@gather | mode: :attack, wave: wave}
      {decide_us, _} = :timer.tc(fn -> for u <- ours ++ workers, do: UnitBrain.decide(u["id"], shared, strategy) end)

      IO.puts("\n  prepare: #{div(prepare_us, 1000)} ms, 360 decisions: #{div(decide_us, 1000)} ms")
      # Units answer within 100 ms; the leader's own work comes on top.
      assert prepare_us < 50_000
      assert decide_us < 100_000
    end
  end
end
