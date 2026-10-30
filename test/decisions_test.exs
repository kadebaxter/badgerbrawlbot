defmodule Swarm.DecisionsTest do
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Decisions, View}

  test "a decision is one logfmt line" do
    assert Decisions.line(:wave_launched, 812, ~s(wave 3: "15" attackers)) ==
             ~s(decision kind=wave_launched tick=812 msg="wave 3: '15' attackers")
  end

  test "a launch, with its reason, and the mode change it causes" do
    v = View.new(state(units: soldiers(20)))
    {strategy, commands, _} = Brain.plan(v, nil, terrain())

    assert [{:wave_launched, "wave 1 at player 1: 15 attackers, nothing scouted yet"}, {:mode, "gather -> attack: wave 1 out with 15"}] =
             Decisions.from_tick(v, strategy, commands, :gather)
  end

  test "buildings and research are logged; soldiers aren't" do
    commands = [
      %{"type" => "Build", "buildingType" => "Barracks", "x" => 10, "y" => 4, "unitIds" => [1, 2]},
      %{"type" => "Research", "upgrade" => "Weapons1"},
      %{"type" => "Produce", "unitType" => "Soldier"},
      %{"type" => "Produce", "unitType" => "Trebuchet"}
    ]

    strategy = %{mode: :gather, why: []}

    assert Decisions.from_tick(View.new(state()), strategy, commands, :gather) == [
             {:build, "Barracks at (10,4) with 2 worker(s)"},
             {:research, "Weapons1"},
             {:train, "Trebuchet"}
           ]
  end
end
