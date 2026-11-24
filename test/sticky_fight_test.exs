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

  test "their research is hidden: the estimate takes them to have the weapons and armor we have" do
    ours = for i <- 1..10, do: unit(200 + i, "Soldier", 12, 12)
    theirs = for i <- 1..10, do: unit(900 + i, "Soldier", 14, 12, owner: 1)
    estimate = fn upgrades ->
      v = %{View.new(state(units: ours ++ theirs)) | upgrades: upgrades}
      Roles.groups(v, nil).groups |> Map.values() |> hd() |> Map.fetch!(:all)
    end

    # Ten against ten is even with no research on either side, and stays even with ours done:
    # they will have done theirs. (It came out well ahead, and we went into fights we then lost.)
    assert_in_delta estimate.([]), 0.0, 0.01
    assert_in_delta estimate.(["Weapons1", "Weapons2", "Armor1", "Armor2", "Armor3"]), 0.0, 0.01
  end

  test "a fight we were staying out of is gathered for again only once we are clearly ahead" do
    out = fn all -> Map.put(group(all, -0.5, false), :was_out, true) end
    # The swings of the fight in the middle, 37 against 72: +0.14, +0.09, -0.29, +0.11, +0.28.
    for all <- [0.14, 0.09, -0.29, 0.11, 0.28] do
      assert Roles.call(out.(all)) == :away
      assert Roles.verdict(out.(all), @far) == :away
    end

    assert Roles.call(out.(0.3)) == :gather
    # Those ready winning it is still a fight to go into, stayed out of or not.
    assert Roles.call(Map.put(group(0.1, 0.05, false), :was_out, true)) == :go
    # And one we weren't staying out of is gathered for at even, as before.
    assert Roles.call(group(0.14, -0.5, false)) == :gather
  end

  test "the leader remembers which fights we stay out of, and every unit's view says so next tick" do
    ours = for i <- 1..4, do: unit(200 + i, "Soldier", 12, 12)
    theirs = for i <- 1..20, do: unit(900 + i, "Soldier", 14, 12, owner: 1)
    {_, _, memory} = Brain.plan(View.new(state(units: ours ++ theirs)), looked(nil), terrain())
    assert length(memory.staying_out) == 20 and memory.going_in == []

    {v, _} = Brain.see(View.new(state(units: ours ++ theirs, tick: 101)), memory)
    assert Enum.all?(Map.values(Roles.groups(v, nil).groups), &(&1.was_out and not &1.was_in))
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
