defmodule Swarm.ResearchFirstTest do
  @moduledoc """
  Harvesting1, Weapons1 and Armor1 come ahead of everything else the ore could go to; the second
  tier of each waits for tick 320, and until then the ore is spent on everything else.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  @buildings [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(6, "TechLab", 7, 12)]

  defp plan(opts), do: Brain.plan(View.new(state(opts)), looked(Brain.new_memory(), 1, 100), terrain())
  defp done(s, upgrades), do: put_in(s, ["you", "upgrades"], upgrades)

  test "with a Tech Lab free, the next of them is the first thing ordered" do
    {_, [cmd | _], _} = plan(units: workers(15) ++ soldiers(10), buildings: @buildings, ore: 400)
    assert %{"type" => "Research", "buildingId" => 6, "upgrade" => "Harvesting1"} = cmd
  end

  test "short of its ore, nothing else is spent meanwhile" do
    # Tick 400, Armor2 (250) is next; with 200 nothing is built or trained.
    s = state(units: [unit(300, "Scout", 10, 12) | workers(15) ++ soldiers(10)], buildings: @buildings, ore: 200, tick: 400) |> done(["Harvesting1", "Weapons1", "Armor1", "Harvesting2"])
    {_, commands, _} = Brain.plan(View.new(s), looked(Brain.new_memory(), 1, 400), terrain())
    assert Enum.filter(commands, &(&1["type"] in ["Research", "Build", "Produce"])) == []
  end

  test "with all of them done the rest of the research waits its turn, and the ore goes on as before" do
    all = ["Harvesting1", "Harvesting2", "Weapons1", "Armor1", "Armor2", "Weapons2", "Armor3"]
    s = state(units: workers(15) ++ soldiers(10), buildings: @buildings, ore: 200) |> done(all)
    {_, commands, _} = Brain.plan(View.new(s), looked(Brain.new_memory(), 1, 100), terrain())
    assert Enum.any?(commands, &(&1["type"] in ["Build", "Produce"]))
  end

  defp next_at(tick, upgrades, ore \\ 1000) do
    s = state(units: [unit(300, "Scout", 10, 12) | workers(15) ++ soldiers(15)], buildings: @buildings, ore: ore, tick: tick) |> done(upgrades)
    {_, commands, _} = Brain.plan(View.new(s), looked(Brain.new_memory(), 1, tick), terrain())
    {Enum.find_value(commands, &(&1["type"] == "Research" && &1["upgrade"])), commands}
  end

  test "after Harvesting1 come Weapons1 and Armor1, not the second Harvesting" do
    assert {"Weapons1", _} = next_at(100, ["Harvesting1"])
    assert {"Armor1", _} = next_at(150, ["Harvesting1", "Weapons1"])
  end

  test "Weapons2 comes straight after the first tier, at any tick" do
    assert {"Weapons2", _} = next_at(230, ["Harvesting1", "Weapons1", "Armor1"])
    assert {"Weapons2", _} = next_at(400, ["Harvesting1", "Weapons1", "Armor1"])
  end

  test "before tick 320 nothing else past the first tier is researched, and its ore is not kept back: it is spent on the rest as usual" do
    for tick <- [200, 319] do
      # (Not SiegeEngineering or a Fortify in their place either: fifteen Soldiers and 1,000 ore here.)
      assert {nil, _} = next_at(tick, ["Harvesting1", "Weapons1", "Armor1", "Weapons2"], 1000)
      assert {nil, commands} = next_at(tick, ["Harvesting1", "Weapons1", "Armor1", "Weapons2"], 300)
      assert Enum.any?(commands, &(&1["type"] in ["Build", "Produce"]))
    end
  end

  test "from tick 320: Harvesting2, then Armor2 and Armor3, in that order" do
    done = ["Harvesting1", "Weapons1", "Armor1", "Weapons2"]
    assert {"Harvesting2", _} = next_at(320, done)
    assert {"Armor2", _} = next_at(360, done ++ ["Harvesting2"])
    assert {"Armor3", _} = next_at(440, done ++ ["Harvesting2", "Armor2"])
  end

  test "the first tier is not held up by the wait: Armor1 at tick 100 with Weapons1 still being researched elsewhere" do
    s = state(units: workers(15) ++ soldiers(10), buildings: @buildings, ore: 1000, tick: 100) |> done(["Harvesting1"]) |> put_in(["you", "researching"], [%{"upgrade" => "Weapons1"}])
    {_, commands, _} = Brain.plan(View.new(s), looked(Brain.new_memory(), 1, 100), terrain())
    assert Enum.find_value(commands, &(&1["type"] == "Research" && &1["upgrade"])) == "Armor1"
  end

  test "the first Tech Lab is ordered at ten workers, with two builders" do
    buildings = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9)]
    lab = fn n -> Enum.find(elem(plan(units: workers(n) ++ soldiers(10), buildings: buildings, ore: 400), 1), &(&1["buildingType"] == "TechLab")) end
    assert lab.(9) == nil
    assert %{"unitIds" => [_, _]} = lab.(10)
  end

  test "a lab is given one thing a tick" do
    {_, commands, _} = plan(units: workers(15) ++ soldiers(10), buildings: @buildings, ore: 2000)
    assert [_] = for(%{"type" => "Research"} = c <- commands, do: c)
  end
end
