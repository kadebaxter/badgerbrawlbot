defmodule Swarm.HelpHomeTest do
  @moduledoc """
  From the game lost 12 tiles out from our towers: help committed before a fight at home is over
  once home has fallen back (it is not picked up again when the fall-back lifts), and between two
  armies the army leaves where it lives only if it is a match for the bigger of them as well.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  # Our second base by the field: a Command Center and its tower. Four workers mine there.
  @base [building(40, "GuardTower", 25, 9), building(41, "CommandCenter", 23, 6)]
  defp miners, do: for(i <- 1..4, do: unit(100 + i, "Worker", 25, 7, activity: "Gathering"))
  defp raiders(n, owner \\ 1), do: for(i <- 1..n, do: unit(900 + i, "Soldier", 27, 7, owner: owner))

  defp plan(opts, memory \\ Brain.new_memory()) do
    s = state(Keyword.put_new(opts, :buildings, @base))
    s = if opts[:players], do: %{s | "players" => Enum.filter(s["players"], &(&1["slot"] == 0)) ++ opts[:players]}, else: s
    Brain.plan(View.new(s), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())
  end

  defp helped(s), do: for({:help, text} <- s.why, do: text)

  describe "a fall-back ends help" do
    test "committed, then a pack home would lose to: called off, and not picked up when the fall-back lifts" do
      {s, _, memory} = plan(units: miners() ++ raiders(2) ++ soldiers(10))
      assert s.help == {27, 7}

      # Tick 101: twenty of theirs by more of our workers, seven tiles on. Home falls back.
      far = for i <- 1..3, do: unit(110 + i, "Worker", 33, 9, activity: "Gathering")
      pack = for i <- 1..20, do: unit(920 + i, "Soldier", 34, 7, owner: 1)
      {s, _, memory} = plan([units: miners() ++ far ++ pack ++ soldiers(10), tick: 101], memory)
      assert s.fall_back and s.help == nil
      assert helped(s) == ["help at (27,7) called off: home has fallen back to its towers"]
      assert memory.help == nil

      # Tick 102 to 110: they have gone, the fall-back lifts sooner or later. Nobody sets off for (27, 7).
      for tick <- 102..110, reduce: memory do
        memory ->
          {s, _, memory} = plan([units: miners() ++ soldiers(10), tick: tick], memory)
          assert s.help == nil and helped(s) == []
          memory
      end
    end

    test "fallen back, no new help is committed to either" do
      # Two raiders by the second base, and a pack home would lose to elsewhere by our workers.
      far = for i <- 1..3, do: unit(110 + i, "Worker", 40, 20, activity: "Gathering")
      pack = for i <- 1..20, do: unit(920 + i, "Soldier", 41, 21, owner: 1)
      {s, _, memory} = plan(units: miners() ++ far ++ raiders(2) ++ pack ++ soldiers(10))
      assert s.fall_back and s.help == nil and memory.help == nil
    end
  end

  describe "between two armies" do
    # Us at (7, 7); players 1 and 2 beside us, player 3 across the map. The two raiders are player 3's.
    defp other(slot, x, y, alive),
      do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}, "score" => %{"survival" => alive, "economy" => 5000, "total" => 9000}}

    defp players(beside_1, beside_2), do: [other(1, 56, 7, beside_1), other(2, 7, 56, beside_2), other(3, 56, 56, 1300)]

    test "an army each side bigger than ours: nobody goes out to the second base for two raiders" do
      # Each has some 19 Soldiers' worth by the scoreboard; we have twelve and the tower there.
      {s, _, memory} = plan(units: miners() ++ raiders(2, 3) ++ soldiers(12), players: players(3000, 3000))
      assert s.hold =~ "between two armies"
      assert s.help == nil and memory.help == nil
    end

    test "with one of them spent, or neither an army: help goes as ever" do
      {s, _, _} = plan(units: miners() ++ raiders(2, 3) ++ soldiers(12), players: players(1200, 3000))
      assert s.help == {27, 7}
      {s, _, _} = plan(units: miners() ++ raiders(2, 3) ++ soldiers(12), players: players(1200, 1200))
      assert s.help == {27, 7}
    end

    test "between two armies we are a match for: help goes" do
      {s, _, _} = plan(units: miners() ++ raiders(2, 3) ++ soldiers(22), players: players(3000, 3000))
      assert s.hold =~ "between two armies"
      assert s.help == {27, 7}
    end

    test "out helping when an army around us outgrows us: called off, and it says whose" do
      {s, _, memory} = plan(units: miners() ++ raiders(2, 3) ++ soldiers(12), players: players(1200, 1200))
      assert s.help == {27, 7}

      # Still a match for it (within the margin help is called off at): it stays.
      {s, _, _} = plan([units: miners() ++ raiders(2, 3) ++ soldiers(12), players: players(3000, 3000), tick: 101], memory)
      assert s.help == {27, 7} and helped(s) == []

      {s, _, _} = plan([units: miners() ++ raiders(2, 3) ++ soldiers(12), players: players(3000, 3700), tick: 101], memory)
      assert s.help == nil
      assert [said] = helped(s)
      assert said =~ "help at (27,7) called off: player 2's army around us is" and said =~ "home can bring"
    end
  end
end
