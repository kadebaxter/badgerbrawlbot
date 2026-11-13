defmodule Swarm.OrdersTest do
  @moduledoc """
  The server runs at most 100 of our commands a tick: what goes, what waits, and that what waits
  is sent again.
  """
  use ExUnit.Case, async: false
  import Swarm.Test.GameState
  alias Swarm.{Orders, View}

  defp move(id, x \\ 30, y \\ 30), do: {id, %{"type" => "Move", "unitIds" => [id], "x" => x, "y" => y}}
  defp gather(id), do: {id, %{"type" => "Gather", "unitIds" => [id], "targetId" => 4}}
  defp hit(id, target), do: {id, %{"type" => "Attack", "unitIds" => [id], "targetId" => target}}
  @train %{"type" => "Produce", "buildingId" => 1, "unitType" => "Soldier"}

  defp view(units), do: View.new(state(units: units))

  test "the same command for many units goes as one" do
    v = view(soldiers(3))
    assert {[%{"type" => "Move", "unitIds" => [201, 202, 203], "x" => 30, "y" => 30}, %{"x" => 40}], cut} =
             Orders.pick([move(203), move(201), move(202), move(204, 40, 40)], [], v)

    assert MapSet.size(cut) == 0
  end

  test "never more than 100; the team's commands always go, last" do
    v = view([])
    unit_commands = for id <- 1..150, do: move(id, id, id)
    {sent, cut} = Orders.pick(unit_commands, [@train, @train], v)

    assert length(sent) == 100
    assert Enum.take(sent, -2) == [@train, @train]
    assert MapSet.size(cut) == 52
  end

  test "a unit in a fight goes before an attack on a target, a move and a Gather" do
    fighter = unit(1, "Soldier", 50, 50)
    enemy = unit(900, "Soldier", 53, 50, owner: 1)
    v = view([fighter, enemy | soldiers(3)] ++ workers(1))

    commands = [gather(101), move(201), hit(202, 950), move(1, 52, 50)]
    {sent, cut} = Orders.pick(commands, [], v, %{}, 2)

    assert [%{"unitIds" => [1]}, %{"unitIds" => [202]}] = sent
    assert cut == MapSet.new([101, 201])
  end

  test "a unit that has waited moves up, so nothing waits for long" do
    v = view(soldiers(1) ++ workers(1))
    {_, cut} = Orders.pick([move(201), gather(101)], [], v, %{}, 1)
    assert cut == MapSet.new([101])

    waited = Orders.waited(%{}, cut)
    {_, cut} = Orders.pick([move(201), gather(101)], [], v, waited, 1)
    assert cut == MapSet.new([201])

    # Sent: it starts over.
    assert Orders.waited(waited, cut) == %{201 => 1}
  end

  describe "a unit whose command didn't go out" do
    setup do
      unless Process.whereis(:swarm), do: start_supervised!(%{id: :pg, start: {:pg, :start_link, [:swarm]}})
      :ok
    end

    test "decides again from before it, and sends it again" do
      soldier = unit(2, "Soldier", 30, 30, activity: "Moving")
      v = View.new(state(units: [soldier]))
      strategy = %{mode: :attack, target: {50, 50}, rally: nil, post: nil, threat: nil, wave: nil}
      pid = start_supervised!({Swarm.Unit, {2, "Soldier"}})

      tick = fn strategy ->
        ref = make_ref()
        send(pid, {:tick, ref, self(), v, strategy})
        assert_receive {:command, ^ref, 2, cmd}
        cmd
      end

      assert %{"type" => "Attack", "x" => 50, "y" => 50} = tick.(strategy)
      # Not sent (cut, or too late): again.
      assert %{"type" => "Attack", "x" => 50, "y" => 50} = tick.(Map.put(strategy, :resend, MapSet.new([2])))
      # Sent this time: it is carrying it out.
      assert :no_change = tick.(Map.put(strategy, :resend, MapSet.new([99])))
      assert :no_change = tick.(strategy)
    end
  end
end
