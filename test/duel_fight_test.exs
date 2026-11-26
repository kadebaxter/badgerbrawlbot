defmodule Swarm.DuelFightTest do
  @moduledoc """
  From a fight lost 46 for 11 at a base of ours with three towers: their 54 were seen coming for
  fifteen ticks, we had 60 fighters and 45 of them there, and their serum was on two ticks before
  ours. An army about our size that still has its serum gets ours first, before it arrives; and
  one on one, with their army coming, nobody stays at a post somewhere else.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, View}

  @tower building(5, "GuardTower", 11, 11)

  defp ours(n, x \\ 8, y \\ 10), do: for(i <- 1..n, do: unit(200 + i, "Soldier", x, y))
  defp theirs(n, x, y, effects \\ nil), do: for(i <- 1..n, do: unit(900 + i, "Soldier", x, y, owner: 1) |> Map.put("effects", effects))

  defp plan(units, memory \\ Brain.new_memory(), opts \\ []) do
    s = state(units: workers(10) ++ units, buildings: [@tower], tick: 390)
    s = if opts[:third], do: update_in(s, ["players"], &(&1 ++ [%{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56}}])), else: s
    {v, memory} = Brain.see(View.new(s), memory)
    {strategy, _, memory} = Brain.plan(v, looked(memory, 1, 390), terrain())
    %{v: v, strategy: strategy, memory: memory}
  end

  describe "the serum, first" do
    test "twenty of theirs coming into our base, eight tiles from our twenty: ours is taken now" do
      t = plan(ours(20) ++ theirs(20, 16, 12))
      assert t.strategy.serum == :take
    end

    test "still twelve tiles off: not yet" do
      assert plan(ours(20, 4, 12) ++ theirs(20, 16, 12)).strategy.serum == nil
    end

    test "theirs already spent: there is no race, and the old measure holds (not at eight tiles)" do
      spent = %{Brain.new_memory() | serum_theirs: [1]}
      assert plan(ours(20) ++ theirs(20, 16, 12), spent).strategy.serum == nil
    end

    test "we know theirs is spent from the moment we see one of them on it" do
      t = plan(ours(20, 40, 40) ++ theirs(3, 44, 40, ["serum"]))
      assert t.memory.serum_theirs == [1]
      # And it stays known.
      t = plan(ours(20) ++ theirs(20, 16, 12), t.memory)
      assert t.memory.serum_theirs == [1] and t.strategy.serum == nil
    end

    test "a raid well under our size is not what it is for" do
      assert plan(ours(20) ++ theirs(9, 16, 12)).strategy.serum == nil
    end

    test "nor an army we would lose to with it on" do
      assert plan(ours(20) ++ theirs(70, 16, 12)).strategy.serum == nil
    end

    test "nor one out in the field, eight tiles from our army and at no base of ours" do
      assert plan(ours(20, 30, 30) ++ theirs(20, 38, 30)).strategy.serum == nil
    end

    test "once taken it isn't taken again" do
      t = plan(ours(20) ++ theirs(20, 16, 12), %{Brain.new_memory() | serum: {:until, 380}})
      assert t.strategy.serum == nil
    end
  end

  describe "one on one, everyone goes to their army" do
    defp jobs(v), do: v |> Roles.home_roles(nil) |> Map.values() |> Enum.frequencies()

    test "their army eighteen tiles from our base: nobody guards the main base, all are attackers" do
      t = plan(ours(20, 10, 10) ++ theirs(20, 25, 25))
      assert Roles.mustering?(t.v)
      assert jobs(t.v) == %{attacker: 20}
    end

    test "with nobody coming, the base keeps its guards" do
      t = plan(ours(20, 10, 10))
      refute Roles.mustering?(t.v)
      assert jobs(t.v)[:guard] > 0
    end

    test "their army across the map, or a handful near us: the guards stay" do
      t = plan(ours(20, 10, 10) ++ theirs(20, 45, 45))
      refute Roles.mustering?(t.v)
      assert jobs(t.v)[:guard] > 0

      t = plan(ours(20, 10, 10) ++ theirs(5, 25, 25))
      refute Roles.mustering?(t.v)
    end

    test "with a third player in the game there may be another army: the guards stay" do
      t = plan(ours(20, 10, 10) ++ theirs(20, 25, 25), Brain.new_memory(), third: true)
      refute Roles.mustering?(t.v)
      assert jobs(t.v)[:guard] > 0
    end

    test "and no wave leaves while they are coming, with everyone at the rally point" do
      t = plan(ours(30, 10, 10) ++ theirs(12, 25, 25))
      assert Roles.mustering?(t.v)
      assert t.strategy.wave == nil
    end
  end
end
