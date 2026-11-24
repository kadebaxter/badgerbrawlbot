defmodule Swarm.StickyFightTest do
  @moduledoc """
  A fight we were going into last tick is seen through: the call stays "go in" for everyone while
  all of ours in it come out no worse than -0.5, whatever this tick's swing in who is near.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, View}

  # A group's estimates as `Roles.groups/2` hands them out: `all` with everyone of ours in it,
  # `ready` with those close enough to go in now.
  defp group(all, ready, was_in),
    do: %{id: 900, ids: MapSet.new([900, 901]), all: all, ready: ready, was_in: was_in, gather: {30, 30}, size: 10, worth: 9900.0}

  @far unit(201, "Soldier", 10, 10)

  test "we were going in: a swing against us doesn't turn everyone round" do
    # The swings of the fight that was lost 25 to 20: -0.35, then +0.6 with few ready, then -0.34.
    for {all, ready} <- [{-0.35, -0.35}, {0.6, -0.35}, {-0.34, -0.85}] do
      assert Roles.call(group(all, ready, true)) == :go
      assert Roles.verdict(group(all, ready, true), @far) == :go
      assert Roles.going_in?(group(all, ready, true))
      refute Roles.away?(group(all, ready, true))
    end
  end

  test "clearly turned against us, it is called off, for everyone" do
    assert Roles.call(group(-0.51, -0.9, true)) == :away
    assert Roles.verdict(group(-0.51, -0.9, true), @far) == :away
    assert Roles.away?(group(-0.51, -0.9, true))
  end

  test "a fight we weren't in is judged as before: nobody is drawn into one by the margin" do
    assert Roles.call(group(-0.35, -0.35, false)) == :away
    assert Roles.call(group(0.6, -0.35, false)) == :gather
    assert Roles.call(group(0.2, 0.1, false)) == :go
  end

  test "the leader remembers which fights we went into, and every unit's view says so next tick" do
    # Twelve of ours right by five of theirs in our base: we go in.
    ours = for i <- 1..12, do: unit(200 + i, "Soldier", 12, 12)
    theirs = for i <- 1..5, do: unit(900 + i, "Soldier", 14, 12, owner: 1)
    {_, _, memory} = Brain.plan(View.new(state(units: ours ++ theirs)), looked(nil), terrain())
    assert Enum.sort(memory.going_in) == [901, 902, 903, 904, 905]

    {v, _} = Brain.see(View.new(state(units: ours ++ theirs, tick: 101)), memory)
    assert v.going_in == MapSet.new([901, 902, 903, 904, 905])
    assert Enum.all?(Map.values(Roles.groups(v, nil).groups), & &1.was_in)

    # A fight nobody of ours is in isn't one we are going into.
    {_, _, memory} = Brain.plan(View.new(state(units: theirs)), looked(nil), terrain())
    assert memory.going_in == []
  end
end
