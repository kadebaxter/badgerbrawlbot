defmodule Swarm.FirstScoutTest do
  @moduledoc """
  From the game with no scout: under the army floor every Barracks stayed full of Soldiers, no
  scout was ever trained, and the only ore we ever knew of was the home field. From tick 120 there
  is always one scout, ahead of the Soldiers.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  # Two Barracks, both with two Soldiers queued: no room by the old rule, and the floor not met.
  defp full(b), do: %{b | "production" => [%{"unitType" => "Soldier"}, %{"unitType" => "Soldier"}]}
  defp barracks, do: [full(building(10, "Barracks", 11, 3)), full(building(11, "Barracks", 11, 6))]
  defp plan(opts), do: Brain.plan(View.new(state(Keyword.merge([buildings: barracks(), tick: 150], opts))), Brain.new_memory(), terrain())
  defp trained(commands), do: for(%{"type" => "Produce", "unitType" => u} <- commands, do: u)

  test "with none, one is the first thing trained, full queues or not" do
    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 400)
    assert [%{"type" => "Produce", "unitType" => "Scout", "buildingId" => 10} | _] = commands
    assert Enum.count(trained(commands), &(&1 == "Scout")) == 1
  end

  test "short of the ore for it, the ore waits: no Soldier takes it" do
    queued = [building(10, "Barracks", 11, 3), building(11, "Barracks", 11, 6)]
    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 170, buildings: queued)
    # 100 of it is kept for workers: 70 to spend, and a scout is 75.
    refute "Scout" in trained(commands) or "Soldier" in trained(commands)

    # Ten more ore and it is trained, before any Soldier.
    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 180, buildings: queued)
    assert [%{"unitType" => "Scout"} | _] = commands
    refute "Soldier" in trained(commands)
  end

  test "not with one alive or one on its way, and not before tick 120" do
    {_, commands, _} = plan(units: [unit(300, "Scout", 30, 30) | workers(12) ++ soldiers(4)], ore: 400)
    refute "Scout" in trained(commands)

    coming = [%{building(10, "Barracks", 11, 3) | "production" => [%{"unitType" => "Scout"}, %{"unitType" => "Soldier"}]}, full(building(11, "Barracks", 11, 6))]
    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 400, buildings: coming)
    refute "Scout" in trained(commands)

    {_, commands, _} = plan(units: workers(12) ++ soldiers(4), ore: 400, tick: 110)
    refute "Scout" in trained(commands)
  end

  test "through a game: trained, out, killed, and trained again" do
    units = workers(12) ++ soldiers(4)
    {_, commands, memory} = plan(units: units, ore: 400)
    assert "Scout" in trained(commands)

    # It is out: nothing more.
    step = fn units, tick, memory -> Brain.plan(View.new(state(units: units, buildings: barracks(), ore: 400, tick: tick)), memory, terrain()) end
    {_, commands, memory} = step.([unit(300, "Scout", 30, 30) | units], 170, memory)
    refute "Scout" in trained(commands)

    # It died: the next one.
    {_, commands, _} = step.(units, 200, memory)
    assert [%{"unitType" => "Scout"} | _] = commands
  end
end

defmodule Swarm.LastLookTest do
  @moduledoc """
  From the game won on time with 120 Soldiers standing 600 ticks in front of an opponent with no
  army: the map mined out, every scout and worker dead, 118 ore of which 100 was kept for workers.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  @barracks building(10, "Barracks", 11, 3)
  @their_cc building(900, "CommandCenter", 56, 56, 1)

  # Everyone together has banked the whole map: mined out.
  defp plan(opts, memory) do
    st =
      state([deposits: [], tick: 1200] ++ opts)
      |> Map.update!("players", fn [me, them] ->
        [Map.put(me, "score", %{"economy" => 42_000, "total" => 60_000, "survival" => 12_000}),
         Map.put(them, "score", %{"economy" => 30_000, "total" => 35_000, "survival" => Keyword.get(opts, :their_alive, 500)})]
      end)

    {v, memory} = Brain.see(View.new(st), memory)
    Brain.plan(v, memory, terrain())
  end

  defp start, do: %{Brain.new_memory() | map_ore: 72_000, check_next: true}
  defp trained(commands), do: for(%{"type" => "Produce", "unitType" => u} <- commands, do: u)

  test "mined out, what was kept for workers buys the scout; before that it stays for the workers" do
    {strategy, commands, _} = plan([units: soldiers(40), buildings: [@barracks, @their_cc], ore: 118], start())
    assert strategy.no_ore == :mined_out
    assert trained(commands) == ["Scout"]

    # The same 118 with ore still on the map: 18 to spend, no scout.
    early = state(units: workers(12) ++ soldiers(40), buildings: [@barracks, @their_cc], ore: 118, tick: 400)
    {_, commands, _} = Brain.plan(View.new(early), Brain.new_memory(), terrain())
    refute "Scout" in trained(commands)
  end

  test "mined out with a scout alive, it is still kept: for the next scout, not for Soldiers" do
    units = [unit(300, "Scout", 30, 30) | soldiers(40)]
    {_, commands, _} = plan([units: units, buildings: [@barracks, @their_cc], ore: 118], start())
    assert trained(commands) == []
  end

  test "the whole end: no scout, no worker, no ore for one, and the wave goes for them tick after tick until it is out" do
    # 40 ore: nothing can be trained. Their army by the scoreboard is nothing.
    {strategy, commands, memory} = plan([units: soldiers(40), buildings: [@barracks, @their_cc], ore: 40], start())
    assert trained(commands) == []
    assert %{wave: %{id: 1}} = strategy

    {strategy, _, _} = plan([units: soldiers(40), buildings: [@barracks, @their_cc], ore: 40, tick: 1201], memory)
    assert %{wave: %{id: 1}} = strategy
  end

  test "it goes on the scoreboard's count: against an army there that is too big for it, it stays" do
    # 6,000 alive that we know no building for: sixty Soldiers' worth against our forty.
    {strategy, _, _} = plan([units: soldiers(40), buildings: [@barracks, @their_cc], ore: 40, their_alive: 6_400], start())
    assert strategy.wave == nil
    assert strategy.hold =~ "strength"
  end

  test "with the ore for a scout it waits for that one instead: the look comes first when it can be had" do
    {strategy, commands, _} = plan([units: soldiers(40), buildings: [@barracks, @their_cc], ore: 118], start())
    assert trained(commands) == ["Scout"]
    assert strategy.wave == nil
  end
end
