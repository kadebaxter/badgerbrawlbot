defmodule Swarm.CaughtTest do
  @moduledoc """
  From two armies lost walking away: 57 told to stay out of 67 twelve tiles from a tower, and 66
  from 70 six tiles from one. They walk as fast as we do. Caught in the open by an army we are
  not hopelessly behind, everyone stands and fights; not yet caught, they fall back as ever.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, UnitBrain, View}

  @built [building(2, "Barracks", 11, 7), building(5, "GuardTower", 11, 11)]

  defp ours(n, x, y), do: for(i <- 1..n, do: unit(200 + i, "Soldier", x, y))
  defp theirs(n, x, y), do: for(i <- 1..n, do: unit(900 + i, "Soldier", x, y, owner: 1))

  defp tick(units, opts \\ []) do
    state = state(units: workers(10) ++ units, buildings: @built ++ Keyword.get(opts, :buildings, []), tick: 300)
    {v, memory} = Brain.see(View.new(state), nil)
    {strategy, _commands, _memory} = Brain.plan(v, looked(memory, 1, 300), terrain())
    prepared = UnitBrain.prepare(v, strategy.wave)
    orders = for u <- v.my_units, {cmd, _} = UnitBrain.decide(u["id"], prepared, strategy), is_map(cmd), into: %{}, do: {u["id"], cmd}
    %{v: v, orders: orders, group: Roles.group_for(v, strategy.wave, Enum.find(v.my_units, &(&1["id"] == 201)))}
  end

  defp attacks?(order), do: match?(%{"type" => "Attack"}, order) or match?(%{"type" => "AttackMove"}, order)
  defp leaves?(order), do: match?(%{"type" => "Move"}, order)

  test "twenty of ours with twenty-four on them, twenty tiles from a tower: they stand and fight" do
    t = tick(ours(20, 30, 30) ++ theirs(24, 31, 30))
    # It is a fight we would stay out of, not hopeless, and all of ours are in their reach.
    assert Roles.away?(t.group) and t.group.all > -0.7 and t.group.engaged == 20
    assert Enum.all?(201..220, &attacks?(t.orders[&1]))
  end

  test "the same army still eight tiles off: nobody is caught, and they fall back as ever" do
    t = tick(ours(20, 30, 30) ++ theirs(24, 38, 30))
    assert Roles.away?(t.group) and t.group.engaged == 0
    assert Enum.all?(201..220, &leaves?(t.orders[&1]))
  end

  test "half of ours caught is all of us caught: the ones behind come in too" do
    t = tick(ours(10, 30, 30) ++ (for i <- 11..20, do: unit(200 + i, "Soldier", 26, 30)) ++ theirs(24, 31, 30))
    assert Roles.away?(t.group) and t.group.engaged == 10
    assert Enum.all?(201..220, &attacks?(t.orders[&1]))
  end

  test "a few of ours in their reach and most of us not: we fall back" do
    t = tick(ours(4, 30, 30) ++ (for i <- 5..20, do: unit(200 + i, "Soldier", 25, 30)) ++ theirs(24, 31, 30))
    assert Roles.away?(t.group) and t.group.engaged == 4
    assert Enum.any?(205..220, &leaves?(t.orders[&1]))
    refute Enum.any?(205..220, &attacks?(t.orders[&1]))
  end

  test "hopelessly behind, we still run" do
    t = tick(ours(20, 30, 30) ++ theirs(70, 31, 30))
    assert t.group.all < -0.7
    assert Enum.all?(201..220, &leaves?(t.orders[&1]))
  end

  test "a handful caught by an army run: this is for an army of ours" do
    t = tick(ours(5, 30, 30) ++ theirs(7, 31, 30))
    assert Roles.away?(t.group)
    assert Enum.all?(201..205, &leaves?(t.orders[&1]))
  end
end
