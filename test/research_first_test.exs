defmodule Swarm.ResearchFirstTest do
  @moduledoc "Both Harvestings and every Weapons and Armor come ahead of everything else the ore could go to."
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
    # Armor2 (250) is next; with 200 nothing is built or trained.
    s = state(units: workers(15) ++ soldiers(10), buildings: @buildings, ore: 200) |> done(["Harvesting1", "Harvesting2", "Weapons1", "Armor1"])
    {_, commands, _} = Brain.plan(View.new(s), looked(Brain.new_memory(), 1, 100), terrain())
    assert Enum.filter(commands, &(&1["type"] in ["Research", "Build", "Produce"])) == []
  end

  test "with all of them done the rest of the research waits its turn, and the ore goes on as before" do
    all = ["Harvesting1", "Harvesting2", "Weapons1", "Armor1", "Armor2", "Weapons2", "Armor3"]
    s = state(units: workers(15) ++ soldiers(10), buildings: @buildings, ore: 200) |> done(all)
    {_, commands, _} = Brain.plan(View.new(s), looked(Brain.new_memory(), 1, 100), terrain())
    assert Enum.any?(commands, &(&1["type"] in ["Build", "Produce"]))
  end

  test "Harvesting2 comes right after Harvesting1, ahead of the Weapons and the Armor" do
    s = state(units: workers(15) ++ soldiers(10), buildings: @buildings, ore: 1000) |> done(["Harvesting1"])
    {_, [cmd | _], _} = Brain.plan(View.new(s), looked(Brain.new_memory(), 1, 100), terrain())
    assert %{"type" => "Research", "upgrade" => "Harvesting2"} = cmd
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
