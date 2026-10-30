defmodule Swarm.BrainTest do
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), memory, terrain())

  test "gathers while the army is small" do
    assert {%{mode: :gather, rally: {10, 10}}, _, _} = plan(units: workers(5) ++ soldiers(2))
  end

  test "trains a worker when there is ore and few workers" do
    {_, commands, _} = plan(units: workers(3), ore: 60)
    assert [%{"type" => "Produce", "unitType" => "Worker", "buildingId" => 1}] = commands
  end

  test "builds a Barracks with seven workers and 150 ore, and waits for it" do
    {_, commands, memory} = plan(units: workers(7), ore: 150, tick: 100)
    assert [%{"type" => "Build", "buildingType" => "Barracks", "unitIds" => [builder]}] = commands
    assert %{type: "Barracks", builder: ^builder, at: 100} = memory.pending

    # Not again while the worker walks there, and its 150 ore stays set aside.
    {_, commands, _} = plan([units: workers(7), ore: 150, tick: 110], memory)
    assert commands == []
  end

  test "saves up for the next building instead of training workers" do
    assert {_, [], _} = plan(units: workers(7), ore: 100)
  end

  test "keeps training workers past the Barracks, up to twenty" do
    barracks = building(2, "Barracks", 11, 7)
    {_, commands, _} = plan(units: workers(8), buildings: [barracks], ore: 50)
    assert [%{"type" => "Produce", "unitType" => "Worker"}] = commands

    {_, commands, _} = plan(units: workers(20), buildings: [barracks], ore: 50)
    refute Enum.any?(commands, &(&1["unitType"] == "Worker"))
  end

  test "orders the building again as soon as the builder reports a failure" do
    {_, _, memory} = plan(units: workers(7), ore: 150, tick: 100)
    failed = %{"tick" => 104, "kind" => "CommandFailed", "entityId" => memory.pending.builder}

    v = View.new(Map.put(state(units: workers(7), ore: 150, tick: 105), "events", [failed]))
    assert {_, [%{"type" => "Build", "buildingType" => "Barracks"}], _} = Brain.plan(v, memory, terrain())
  end

  test "forgets the pending building once it is up" do
    {_, _, memory} = plan(units: workers(7), ore: 150, tick: 100)
    barracks = Map.put(building(2, "Barracks", 11, 7), "completed", false)
    assert {_, _, %{pending: nil}} = plan([units: workers(7), buildings: [barracks], tick: 120], memory)
  end

  test "puts the Resource Depot by the ore, on our side of it" do
    {_, [cmd | _], _} = plan(units: workers(9), buildings: [building(2, "Barracks", 11, 7)], ore: 100)
    assert %{"type" => "Build", "buildingType" => "ResourceDepot", "x" => x, "y" => y} = cmd
    assert View.dist({x, y}, {2, 7}) in 2..3
    assert View.dist({x, y}, {7, 7}) < View.dist({x, y}, {0, 7})
  end

  test "puts the Guard Tower between our base and the enemy" do
    buildings = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9)]
    {_, [cmd | _], _} = plan(units: workers(11), buildings: buildings, ore: 125)
    assert %{"type" => "Build", "buildingType" => "GuardTower", "x" => x, "y" => y} = cmd
    assert View.dist({x, y}, {56, 56}) < View.dist({7, 7}, {56, 56})
  end

  test "builds a Resource Depot by the closest other ore when ours runs low" do
    far = for {id, x, y} <- [{30, 30, 30}, {31, 31, 30}, {32, 30, 31}, {33, 50, 50}],
              do: %{"id" => id, "x" => x, "y" => y, "remaining" => 900}

    {_, [cmd | _], _} = plan(units: workers(5), deposits: far, ore: 100)
    assert %{"type" => "Build", "buildingType" => "ResourceDepot", "x" => x, "y" => y} = cmd
    assert View.dist({x, y}, {30, 30}) in 2..3
  end

  test "no new Resource Depot while there is enough ore close by" do
    home = for {id, x, y} <- [{4, 2, 7}, {5, 2, 9}, {6, 3, 5}], do: %{"id" => id, "x" => x, "y" => y, "remaining" => 900}
    far = [%{"id" => 30, "x" => 30, "y" => 30, "remaining" => 900}]
    {_, commands, _} = plan(units: workers(5), deposits: home ++ far, ore: 100)
    refute Enum.any?(commands, &(&1["buildingType"] == "ResourceDepot"))
  end

  test "with four players, the Guard Tower still faces the middle, not a map edge" do
    corners = [{1, 56, 7}, {2, 7, 56}, {3, 56, 56}]

    four =
      Map.update!(state(), "players", fn [me | _] ->
        [me | for({slot, x, y} <- corners, do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}})]
      end)

    {x, y} = Brain.site(terrain(), View.new(four), :front)
    # Diagonally out from the Command Center at (7, 7), toward (32, 32).
    assert x >= 12 and y >= 12
  end

  test "towers and the TechLab wait for a finished Barracks" do
    unfinished = Map.put(building(2, "Barracks", 11, 7), "completed", false)
    buildings = [unfinished, building(3, "ResourceDepot", 4, 9)]
    {_, commands, _} = plan(units: workers(13), buildings: buildings, ore: 1000)
    refute Enum.any?(commands, &(&1["buildingType"] in ["GuardTower", "TechLab"]))
  end

  test "the TechLab researches Harvesting1 first" do
    buildings = [
      building(2, "Barracks", 11, 7),
      building(3, "ResourceDepot", 4, 9),
      building(4, "GuardTower", 12, 12),
      building(5, "TechLab", 7, 11)
    ]

    {_, commands, _} = plan(units: workers(13), buildings: buildings, ore: 1000)
    assert %{"buildingId" => 5, "upgrade" => "Harvesting1"} = Enum.find(commands, &(&1["type"] == "Research"))
  end

  test "never pulls a worker off a building to start the next one" do
    tower = Map.put(building(14, "GuardTower", 12, 12), "completed", false)
    builders = for w <- workers(12), do: %{w | "activity" => "Building", "targetId" => 14}
    miner = unit(50, "Worker", 30, 30, activity: "Gathering", target_id: 6)
    buildings = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), tower]

    {_, commands, _} = plan(units: [miner | builders], buildings: buildings, ore: 150)
    assert [%{"type" => "Build", "buildingType" => "TechLab", "unitIds" => [50]}] =
             Enum.filter(commands, &(&1["type"] == "Build"))
  end

  test "sends a worker to finish a site nobody is working on, once" do
    tower = Map.put(building(14, "GuardTower", 12, 12), "completed", false)
    buildings = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), tower]

    {_, commands, memory} = plan(units: workers(11), buildings: buildings, tick: 100)
    assert [%{"type" => "Build", "buildingType" => "GuardTower", "x" => 12, "y" => 12}] = commands

    # The worker is on its way: don't send another one.
    {_, commands, _} = plan([units: workers(11), buildings: buildings, tick: 101], memory)
    assert commands == []
  end

  test "the Barracks site is open ground 3-6 tiles from the Command Center, off the ore" do
    {x, y} = Brain.site(terrain(), View.new(state()), :base)
    assert View.dist({x, y}, {7, 7}) in 3..6
    assert View.dist({x, y}, {2, 7}) > 1
  end

  test "launches a wave once fifteen attackers wait at the rally point" do
    # 18 fighters: 4 guards, 14 attackers. Not yet.
    assert {%{mode: :gather, wave: nil}, _, _} = plan(units: soldiers(18))

    # 20 fighters: 5 guards (the newest), 15 attackers (the oldest) go.
    {strategy, _, memory} = plan(units: soldiers(20))
    assert %{mode: :attack, target: {56, 56}, wave: %{id: 1, members: members}} = strategy
    assert members == Enum.to_list(201..215)
    assert memory.next_wave == 2
  end

  test "attackers who weren't at the rally point don't go" do
    away = for s <- soldiers(20), do: %{s | "x" => 30, "y" => 30}
    assert {%{wave: nil}, _, _} = plan(units: away)
  end

  test "units trained after the launch wait for the next wave" do
    {_, _, memory} = plan(units: soldiers(20))
    {%{wave: wave}, _, _} = plan([units: soldiers(30)], memory)
    assert wave.id == 1 and wave.members == Enum.to_list(201..215)
  end

  test "recalls the wave when fewer than five of it are left" do
    {_, _, memory} = plan(units: soldiers(20))
    # 201..205 still alive: five left, the wave stays out.
    survivors = Enum.drop(soldiers(20), -15) ++ Enum.slice(soldiers(20), 15..19)
    assert {%{wave: %{members: [201, 202, 203, 204, 205]}}, _, _} = plan([units: survivors], memory)

    four_left = Enum.slice(soldiers(20), 1..4) ++ Enum.slice(soldiers(20), 15..19)
    assert {%{wave: nil}, _, %{wave: nil, next_wave: 2}} = plan([units: four_left], memory)
  end

  test "no wave leaves while the base is under attack" do
    enemy = unit(900, "Soldier", 12, 9, owner: 1)
    assert {%{mode: :defend, wave: nil}, _, _} = plan(units: soldiers(20) ++ [enemy])
  end

  test "prefers a visible enemy building as the target" do
    {strategy, _, _} = plan(units: soldiers(6), buildings: [building(9, "Barracks", 40, 40, 1)])
    assert strategy.target == {40, 40}
  end

  test "reports enemies near the base as a threat" do
    enemies = [unit(900, "Soldier", 12, 9, owner: 1), unit(901, "Worker", 13, 9, owner: 1)]
    assert {%{mode: :defend, threat: %{pos: {12, 9}, size: 1}}, _, _} = plan(units: soldiers(6) ++ enemies)
  end

  test "guards stand behind the tower closest to the enemy" do
    {strategy, _, _} = plan(units: soldiers(3), buildings: [building(2, "GuardTower", 12, 12)])
    assert strategy.post == {11, 11}
  end

  describe "scouting and attack decisions" do
    defp seen_enemies(n, tick \\ 100) do
      for i <- 1..n, into: %{} do
        {900 + i, %{"id" => 900 + i, "type" => "Soldier", "hp" => 110, "x" => 56, "y" => 56, "seen" => tick}}
      end
    end

    defp scores(state, mine, theirs) do
      Map.update!(state, "players", fn [me, them] ->
        [Map.put(me, "score", %{"total" => mine}), Map.put(them, "score", %{"total" => theirs})]
      end)
    end

    test "trains one scout once a Barracks is done" do
      barracks = building(2, "Barracks", 11, 7)
      {_, commands, _} = plan(units: workers(20), buildings: [barracks], ore: 1000)
      assert Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Scout"}, &1))

      scout = unit(300, "Scout", 30, 30)
      {_, commands, _} = plan(units: [scout | workers(20)], buildings: [barracks], ore: 1000)
      refute Enum.any?(commands, &(&1["unitType"] == "Scout"))
    end

    test "one scout per opponent" do
      three = Map.update!(state(units: [unit(300, "Scout", 30, 30) | workers(20)], buildings: [building(2, "Barracks", 11, 7)], ore: 1000), "players", fn ps ->
        ps ++ [%{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 7}}]
      end)

      {_, commands, _} = Brain.plan(View.new(three), nil, terrain())
      assert Enum.any?(commands, &(&1["unitType"] == "Scout"))
    end

    test "remembers enemy fighters until we kill them or lose track" do
      enemy = unit(900, "Archer", 30, 30, owner: 1)
      {_, _, memory} = plan(units: [enemy], tick: 100)
      assert %{"type" => "Archer", "seen" => 100} = memory.enemies[900]

      # Out of sight: still remembered.
      assert {_, _, %{enemies: %{900 => _}}} = plan([tick: 200], memory)

      killed = %{"tick" => 201, "kind" => "UnitKilled", "entityId" => 900}
      v = View.new(Map.put(state(tick: 201), "events", [killed]))
      assert {_, _, %{enemies: enemies}} = Brain.plan(v, memory, terrain())
      assert enemies == %{}

      assert {_, _, %{enemies: enemies}} = plan([tick: 401], memory)
      assert enemies == %{}
    end

    test "waits while the enemy army is too strong; goes early against a weak one" do
      # 15 attackers against 12 remembered soldiers: not 1.5 times as strong.
      strong = %{Brain.new_memory() | enemies: seen_enemies(12)}
      assert {%{wave: nil}, _, _} = plan([units: soldiers(20)], strong)

      # 9 attackers (3 guards stay) against 2 soldiers: go.
      weak = %{Brain.new_memory() | enemies: seen_enemies(2)}
      assert {%{wave: %{members: members}}, _, _} = plan([units: soldiers(12)], weak)
      assert length(members) == 9
    end

    test "with several opponents, only the one we attack counts" do
      # A third player at (40, 7) is closer than player 1 at (56, 56), so it is the target.
      three = Map.update!(state(units: soldiers(20)), "players", fn ps ->
        ps ++ [%{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 40, "y" => 7}}]
      end)

      # 12 soldiers of player 1, and 2 of player 2.
      armies =
        for {id, owner} <- Enum.map(1..12, &{900 + &1, 1}) ++ [{950, 2}, {951, 2}], into: %{} do
          {id, %{"id" => id, "owner" => owner, "type" => "Soldier", "hp" => 110, "x" => 56, "y" => 56, "seen" => 100}}
        end

      memory = %{Brain.new_memory() | enemies: armies}
      assert {%{target: {40, 7}, wave: %{}}, _, _} = Brain.plan(View.new(three), memory, terrain())
    end

    test "never fewer than eight in a wave" do
      weak = %{Brain.new_memory() | enemies: seen_enemies(1)}
      assert {%{wave: nil}, _, _} = plan([units: soldiers(10)], weak)
    end

    test "the wave pulls back when it meets a stronger force" do
      wave = for s <- soldiers(6), do: %{s | "x" => 40, "y" => 40}
      enemies = for i <- 1..10, do: unit(900 + i, "Soldier", 43, 43, owner: 1)
      memory = %{Brain.new_memory() | wave: %{id: 1, members: Enum.to_list(201..206)}, next_wave: 2}
      assert {%{wave: nil}, _, _} = plan([units: wave ++ enemies], memory)
    end

    test "all in near the end when behind on score, guards too" do
      behind = state(units: soldiers(8), tick: 1500) |> scores(100, 200)
      assert {%{wave: %{all_in: true, members: members}}, _, _} = Brain.plan(View.new(behind), nil, terrain())
      assert members == Enum.to_list(201..208)

      ahead = state(units: soldiers(8), tick: 1500) |> scores(200, 100)
      assert {%{wave: nil}, _, _} = Brain.plan(View.new(ahead), nil, terrain())
    end
  end

  test "no wave leaves while an outpost is under attack" do
    miners = for i <- 1..6, do: unit(400 + i, "Worker", 31, 31, activity: "Gathering")
    enemy = unit(900, "Soldier", 34, 34, owner: 1)
    # 25 soldiers: 6 guards, 2 escorts, 17 attackers, against one enemy.
    {strategy, _, _} = plan(units: soldiers(25) ++ miners ++ [enemy], buildings: [building(50, "ResourceDepot", 30, 30)])
    assert %{mode: :defend, wave: nil} = strategy
  end

  test "no wave leaves while our workers are attacked out in the field" do
    miner = unit(101, "Worker", 42, 40, activity: "Gathering")
    enemy = unit(900, "Soldier", 40, 40, owner: 1)
    assert {%{mode: :defend, wave: nil}, _, _} = plan(units: [miner, enemy | soldiers(25)])
  end

  describe "with plenty of ore" do
    # The whole build order, finished.
    defp built do
      [
        building(2, "Barracks", 11, 7),
        building(3, "ResourceDepot", 4, 11),
        building(5, "GuardTower", 12, 12),
        building(6, "TechLab", 7, 12),
        building(7, "Barracks", 12, 3),
        building(8, "GuardTower", 14, 9),
        building(9, "ResourceDepot", 3, 3)
      ]
    end

    defp builds(commands), do: for(%{"type" => "Build"} = c <- commands, do: c)

    test "builds a third Barracks with two workers once the build order is done" do
      {_, commands, _} = plan(units: workers(20), buildings: built(), ore: 1000)
      assert [%{"buildingType" => "Barracks", "unitIds" => [_, _]}] = builds(commands)
    end

    test "builds nothing extra without the ore" do
      {_, commands, _} = plan(units: workers(20), buildings: built(), ore: 300)
      assert builds(commands) == []
    end

    test "doesn't wait for workers in the build order" do
      {_, commands, _} = plan(units: workers(8), buildings: [building(2, "Barracks", 11, 7)], ore: 1000)
      assert [%{"buildingType" => "ResourceDepot"}] = builds(commands)
    end

    test "the SiegeWorkshop comes once SiegeEngineering is researched" do
      v = View.new(put_in(state(units: workers(20), buildings: built(), ore: 1000), ["you", "upgrades"], ["SiegeEngineering"]))
      {_, commands, _} = Brain.plan(v, nil, terrain())
      assert [%{"buildingType" => "SiegeWorkshop"}] = builds(commands)
    end

    test "a SiegeWorkshop trains Trebuchets, up to two" do
      shop = building(10, "SiegeWorkshop", 3, 10)
      {_, commands, _} = plan(units: workers(20), buildings: [shop | built()], ore: 1000)
      assert Enum.any?(commands, &match?(%{"buildingId" => 10, "unitType" => "Trebuchet"}, &1))

      trebs = for i <- 1..2, do: unit(300 + i, "Trebuchet", 9, 9)
      {_, commands, _} = plan(units: trebs ++ workers(20), buildings: [shop | built()], ore: 1000)
      refute Enum.any?(commands, &(&1["unitType"] == "Trebuchet"))
    end

    test "Barracks queue up to five" do
      queued = for _ <- 1..4, do: %{"unitType" => "Soldier", "percent" => 0}
      barracks = %{building(2, "Barracks", 11, 7) | "production" => queued}
      {_, commands, _} = plan(units: workers(20), buildings: [barracks], ore: 1000)
      assert Enum.any?(commands, &match?(%{"buildingId" => 2, "type" => "Produce"}, &1))

      {_, commands, _} = plan(units: workers(20), buildings: [barracks], ore: 400)
      refute Enum.any?(commands, &match?(%{"buildingId" => 2, "type" => "Produce"}, &1))
    end
  end

  test "barracks train two soldiers for each archer" do
    barracks = building(2, "Barracks", 11, 7)
    {_, commands, _} = plan(units: workers(10) ++ soldiers(2), buildings: [barracks], ore: 1000)
    assert Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Archer", "buildingId" => 2}, &1))
  end
end
