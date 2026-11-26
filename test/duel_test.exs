defmodule Swarm.DuelTest do
  @moduledoc """
  One on one, from two games lost to a Formics at tick 390 with 72 workers and 51 fighters to its
  50 and 54: the workers don't outnumber the fighters (no worker, no further base and no
  second-tier research until the army has caught up), there are up to 110 workers on the ore two
  players share, and the wave is weighed against the scoreboard as in every other game.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  # Plenty of ore by home: 20 piles of 900.
  @ore for i <- 1..20, do: %{"id" => 400 + i, "x" => 2 + rem(i, 5), "y" => 2 + div(i, 5), "remaining" => 900}
  @built [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(6, "TechLab", 7, 12)]
  @first ["Harvesting1", "Weapons1", "Armor1", "Weapons2"]

  defp miners(n), do: for(i <- 1..n, do: unit(1000 + i, "Worker", 8, 8, activity: "Gathering", target_id: 401))
  defp army(n), do: for(i <- 1..n, do: unit(200 + i, "Soldier", 10, 10))

  defp plan(workers, fighters, opts \\ []) do
    s =
      state(units: [unit(300, "Scout", 10, 12) | miners(workers) ++ army(fighters)], buildings: @built, deposits: @ore, ore: Keyword.get(opts, :ore, 2000), tick: Keyword.get(opts, :tick, 250))
      |> put_in(["you", "upgrades"], Keyword.get(opts, :upgrades, @first))

    s = if opts[:third], do: update_in(s, ["players"], &(&1 ++ [%{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56}}])), else: s
    {_, commands, _} = Brain.plan(View.new(s), looked(Brain.new_memory(), 1, Keyword.get(opts, :tick, 250)), terrain())
    commands
  end

  defp worker?(commands), do: Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Worker"}, &1))
  defp soldier?(commands), do: Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Soldier"}, &1))
  defp research(commands), do: Enum.find_value(commands, &(&1["type"] == "Research" && &1["upgrade"]))

  describe "the workers don't outnumber the fighters" do
    test "forty workers and thirty fighters: no worker is trained, and the Barracks are" do
      commands = plan(40, 30)
      refute worker?(commands)
      assert soldier?(commands)
    end

    test "the army caught up: workers again" do
      assert worker?(plan(40, 41))
    end

    test "under thirty workers it doesn't apply: the opening is the opening" do
      assert worker?(plan(25, 5))
    end

    test "with a third player in the game it doesn't apply" do
      assert worker?(plan(40, 30, third: true))
    end

    test "and nothing past Weapons2 is researched until the army has caught up" do
      assert research(plan(40, 30, tick: 400)) == nil
      assert research(plan(40, 41, tick: 400)) == "Harvesting2"
      # The first tier is never held back.
      assert research(plan(40, 30, tick: 400, upgrades: ["Harvesting1"])) == "Weapons1"
    end

    test "step by step from tick 300: the workers stand still while the army grows past them, then both grow" do
      # Each step: what was ordered joins us (a worker, or a Soldier from the one Barracks).
      {workers, fighters, log} =
        Enum.reduce(1..30, {46, 38, []}, fn _, {w, f, log} ->
          commands = plan(w, f, tick: 300)
          {w2, f2} = {if(worker?(commands), do: w + 1, else: w), if(soldier?(commands), do: f + 1, else: f)}
          {w2, f2, [{w2, f2} | log]}
        end)

      log = Enum.reverse(log)
      # No worker until there are 47 fighters to the 46 workers...
      assert Enum.take_while(log, fn {_w, f} -> f <= 46 end) |> Enum.all?(fn {w, _f} -> w == 46 end)
      # ...and from then on never more workers than fighters by more than the one being trained.
      assert Enum.all?(log, fn {w, f} -> w <= max(46, f + 1) end)
      assert workers > 46 and fighters > 46
    end
  end

  describe "the ore two players share" do
    test "one on one, up to 110 workers while there is the ore for them" do
      # 18,000 ore by home: 120 at one for every 150, capped at 110.
      assert worker?(plan(100, 101))
      assert worker?(plan(109, 110))
      refute worker?(plan(110, 111))
    end

    test "with three players or more, eighty as before" do
      assert worker?(plan(79, 80, third: true))
      refute worker?(plan(80, 81, third: true))
    end
  end

  describe "the wave and the scoreboard" do
    # Thirty-one at the rally point, a look at their base that counted ten.
    defp wave(alive) do
      seen = for i <- 1..10, into: %{}, do: {900 + i, %{"id" => 900 + i, "owner" => 1, "type" => "Soldier", "x" => 50, "y" => 50, "hp" => 110, "seen" => 240}}
      s = state(units: [unit(300, "Scout", 10, 12) | miners(10) ++ army(31)], buildings: [building(2, "Barracks", 11, 7)], deposits: @ore, tick: 250)
      s = update_in(s, ["players"], fn [me, them] -> [me, Map.put(them, "score", %{"survival" => alive, "economy" => 9000, "total" => 9000})] end)
      {strategy, _, _} = Brain.plan(View.new(s), looked(%{Brain.new_memory() | enemies: seen}, 1, 250), terrain())
      strategy
    end

    test "ten seen at their base and fifty on the scoreboard: thirty-one don't go" do
      # 5,000 beyond a base like ours and ten workers.
      s = wave(550 + 500 + 5000)
      assert s.wave == nil
      assert s.hold =~ "1.5 x"
    end

    test "ten seen and the scoreboard agreeing: they go" do
      s = wave(550 + 500 + 1000)
      assert %{wave: %{owner: 1}} = s
    end
  end
end
