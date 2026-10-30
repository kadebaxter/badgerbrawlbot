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
    {_, [cmd | _], _} = plan(units: workers(9) ++ soldiers(7), buildings: [building(2, "Barracks", 11, 7)], ore: 100)
    assert %{"type" => "Build", "buildingType" => "ResourceDepot", "x" => x, "y" => y} = cmd
    assert View.dist({x, y}, {2, 7}) in 2..3
    assert View.dist({x, y}, {7, 7}) < View.dist({x, y}, {0, 7})
  end

  test "puts the Guard Tower between our base and the enemy" do
    buildings = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9)]
    {_, [cmd | _], _} = plan(units: workers(11) ++ soldiers(7), buildings: buildings, ore: 125)
    assert %{"type" => "Build", "buildingType" => "GuardTower", "x" => x, "y" => y} = cmd
    assert View.dist({x, y}, {56, 56}) < View.dist({7, 7}, {56, 56})
  end

  test "builds a Resource Depot by the closest other ore when ours runs low" do
    far = for {id, x, y} <- [{30, 30, 30}, {31, 31, 30}, {32, 30, 31}, {33, 50, 50}],
              do: %{"id" => id, "x" => x, "y" => y, "remaining" => 900}

    # Short of ore from tick 100, but not for long enough yet.
    {_, commands, memory} = plan(units: workers(5), deposits: far, ore: 100, tick: 100)
    assert memory.ore_short_since == 100
    refute Enum.any?(commands, &(&1["buildingType"] == "ResourceDepot"))

    {_, commands, _} = plan([units: workers(5), deposits: far, ore: 100, tick: 130], memory)
    assert %{"x" => x, "y" => y} = Enum.find(commands, &(&1["buildingType"] == "ResourceDepot"))
    assert View.dist({x, y}, {30, 30}) in 2..3
  end

  test "a new Resource Depot once home is crowded, even with ore left" do
    home = for {id, x, y} <- [{4, 2, 7}, {5, 2, 9}], do: %{"id" => id, "x" => x, "y" => y, "remaining" => 5000}
    far = [%{"id" => 30, "x" => 30, "y" => 30, "remaining" => 900}]

    # Ten workers on two deposits: more than three each. (That first tick also orders the
    # Barracks; forget it, so this is only about the depot.)
    {_, _, memory} = plan(units: workers(10), deposits: home ++ far, ore: 200, tick: 100)
    assert memory.ore_short_since == 100
    {_, commands, _} = plan([units: workers(10), deposits: home ++ far, ore: 200, tick: 130], %{memory | pending: nil})
    assert Enum.any?(commands, &(&1["buildingType"] == "ResourceDepot"))

    # Six on two is fine.
    {_, _, memory} = plan(units: workers(6), deposits: home ++ far, ore: 200, tick: 100)
    assert memory.ore_short_since == nil
  end

  test "the build order has one Resource Depot; more only when home runs short" do
    buildings = [
      building(2, "Barracks", 11, 7),
      building(3, "ResourceDepot", 4, 11),
      building(5, "GuardTower", 12, 12),
      building(6, "TechLab", 7, 12),
      building(7, "Barracks", 12, 3),
      building(8, "GuardTower", 14, 9)
    ]

    home = for {id, x, y} <- [{4, 2, 7}, {40, 2, 9}, {41, 3, 5}], do: %{"id" => id, "x" => x, "y" => y, "remaining" => 900}
    {_, commands, _} = plan(units: workers(9) ++ soldiers(7), buildings: buildings, deposits: home, ore: 400)
    refute Enum.any?(commands, &(&1["buildingType"] == "ResourceDepot"))
  end

  describe "where a new depot goes" do
    # Us at (7, 7); enemies at (7, 50) and (56, 56).
    defp two_enemies(state) do
      Map.update!(state, "players", fn [me, them] ->
        [me, them, %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 50}}]
      end)
    end

    defp ore(id, x, y), do: %{"id" => id, "x" => x, "y" => y, "remaining" => 900}

    test "never ore closer to an enemy than to us, even if it's the closest" do
      # (7, 29) is 22 from us but 21 from the enemy at (7, 50): contested. (30, 8) is ours.
      v = View.new(two_enemies(state(deposits: [ore(30, 7, 29), ore(31, 30, 8)])))
      {x, y} = Brain.site(terrain(), v, :expansion)
      assert View.dist({x, y}, {30, 8}) in 2..3
    end

    test "not where we just lost a building" do
      v = View.new(two_enemies(state(deposits: [ore(31, 30, 8), ore(32, 20, 20)])))
      {x, y} = Brain.site(terrain(), v, :expansion, [{20, 21}])
      assert View.dist({x, y}, {30, 8}) in 2..3
    end

    test "a building of ours that disappears is remembered as lost, for a while" do
      depot = building(50, "ResourceDepot", 29, 24)
      {_, _, memory} = plan(buildings: [depot], tick: 500)
      assert memory.buildings[50] == {29, 24}

      {_, _, memory} = plan([tick: 501], memory)
      assert memory.lost == %{{29, 24} => 501}

      assert {_, _, %{lost: lost}} = plan([tick: 900], memory)
      assert lost == %{}
    end
  end

  test "the 500 ore we start with isn't rich" do
    {_, commands, _} = plan(units: workers(5), ore: 500)
    refute Enum.any?(commands, &(&1["type"] == "Build"))
  end

  test "below the army floor, the Barracks train before anything is built" do
    {_, [first | _] = commands, _} =
      plan(units: workers(10), buildings: [building(2, "Barracks", 11, 7)], ore: 250, tick: 300)

    assert %{"type" => "Produce", "unitType" => "Soldier"} = first
    assert Enum.any?(commands, &(&1["buildingType"] == "ResourceDepot"))
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

    {_, commands, _} = plan(units: [miner | builders] ++ soldiers(7), buildings: buildings, ore: 150)
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

    test "a scout per neighbor plus one roaming: two in a 1v1, once a Barracks is done" do
      barracks = building(2, "Barracks", 11, 7)
      {_, commands, _} = plan(units: workers(20), buildings: [barracks], ore: 1000)
      assert Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Scout"}, &1))

      one = [unit(300, "Scout", 30, 30)]
      {_, commands, _} = plan(units: one ++ workers(20), buildings: [barracks], ore: 1000)
      assert Enum.any?(commands, &(&1["unitType"] == "Scout"))

      two = [unit(301, "Scout", 20, 20) | one]
      {_, commands, _} = plan(units: two ++ workers(20), buildings: [barracks], ore: 1000)
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

    test "launches and recalls say why" do
      weak = %{Brain.new_memory() | enemies: seen_enemies(2)}
      {%{why: [{:wave_launched, why}]}, _, memory} = plan([units: soldiers(12)], weak)
      assert why == "wave 1 at player 1: 9 attackers, strength 8910 vs 1980 known"

      four_left = Enum.slice(soldiers(12), 0..3) ++ Enum.slice(soldiers(12), 9..11)
      assert {%{why: [{:wave_recalled, "wave 1: only 4 left"}]}, _, _} = plan([units: four_left], memory)
    end

    test "goes after the weaker of the two nearest opponents, never one across the map" do
      # Us at (7, 7). Neighbors at (56, 7) and (7, 56); across the map at (56, 56).
      four = fn survival ->
        Map.update!(state(units: soldiers(20)), "players", fn [me | _] ->
          [me |
             for {slot, x, y} <- [{1, 56, 7}, {2, 7, 56}, {3, 56, 56}] do
               %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y},
                 "score" => %{"survival" => survival[slot], "total" => 0}}
             end]
        end)
      end

      {s, _, _} = Brain.plan(View.new(four.(%{1 => 3000, 2 => 1200, 3 => 100})), nil, terrain())
      assert %{target: {7, 56}, wave: %{owner: 2}} = s

      {s, _, _} = Brain.plan(View.new(four.(%{1 => 900, 2 => 1200, 3 => 100})), nil, terrain())
      assert %{target: {56, 7}, wave: %{owner: 1}} = s
    end

    test "a wave sticks to the opponent it went after" do
      two = fn survival ->
        Map.update!(state(units: soldiers(20)), "players", fn [me, them] ->
          [me, Map.put(them, "score", %{"survival" => survival[1], "total" => 0}),
           %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56},
             "score" => %{"survival" => survival[2], "total" => 0}}]
        end)
      end

      {%{wave: %{owner: 2}}, _, memory} = Brain.plan(View.new(two.(%{1 => 3000, 2 => 500})), nil, terrain())
      # Player 1 is now the weaker; the wave out stays on player 2.
      assert {%{target: {7, 56}, wave: %{owner: 2}}, _, _} =
               Brain.plan(View.new(two.(%{1 => 100, 2 => 500})), memory, terrain())
    end

    test "the target is that opponent's building nearest us" do
      buildings = [building(9, "Barracks", 40, 40, 1), building(8, "Barracks", 30, 30, 1)]
      assert {%{target: {30, 30}}, _, _} = plan(units: soldiers(6), buildings: buildings)
    end

    test "two Trebuchets at the rally point go with the wave; it holds short of the target for them" do
      # 301 and 302 are the oldest: they stay home. 303 and 304 go.
      trebs = for i <- 1..4, do: unit(300 + i, "Trebuchet", 10, 10)
      {s, _, memory} = plan(units: trebs ++ soldiers(20))
      assert %{wave: %{staging: {47, 47}, released: false, members: members}} = s
      assert 303 in members and 304 in members
      refute 301 in members or 302 in members
      assert [{:wave_launched, "wave 1 at player 1: 15 attackers and 2 trebuchets, nothing scouted yet"}] = s.why

      # Not there yet: still holding.
      assert {%{wave: %{released: false}}, _, _} = plan([units: trebs ++ soldiers(20), tick: 110], memory)

      # There: the wave goes in.
      arrived = Enum.map(trebs, fn t -> if t["id"] in [303, 304], do: %{t | "x" => 47, "y" => 47}, else: t end)
      assert {%{wave: %{released: true}, why: [{:wave_released, _}]}, _, _} =
               plan([units: arrived ++ soldiers(20), tick: 120], memory)

      # Or stuck: it goes in after 60 ticks anyway.
      assert {%{wave: %{released: true}}, _, _} = plan([units: trebs ++ soldiers(20), tick: 160], memory)
    end

    test "one Trebuchet at the rally point isn't enough: the wave goes without it" do
      trebs = for i <- 1..3, do: unit(300 + i, "Trebuchet", 10, 10)
      {s, _, _} = plan(units: trebs ++ soldiers(20))
      assert %{wave: %{released: true, members: members}} = s
      refute 303 in members
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

    test "doesn't wait for workers in the build order, except for depots" do
      {_, commands, _} = plan(units: workers(8), buildings: [building(2, "Barracks", 11, 7)], ore: 1000)
      assert [%{"buildingType" => "GuardTower"}] = builds(commands)
    end

    test "the SiegeWorkshop waits for a defensive army of fifteen" do
      researched = fn units ->
        View.new(put_in(state(units: units, buildings: built(), ore: 1000), ["you", "upgrades"], ["SiegeEngineering"]))
      end

      {_, commands, _} = Brain.plan(researched.(workers(20) ++ soldiers(14)), nil, terrain())
      refute Enum.any?(builds(commands), &(&1["buildingType"] == "SiegeWorkshop"))

      {_, commands, _} = Brain.plan(researched.(workers(20) ++ soldiers(15)), nil, terrain())
      assert [%{"buildingType" => "SiegeWorkshop"}] = builds(commands)
    end

    test "SiegeEngineering is skipped in the research order until then" do
      done = ["Harvesting1", "Weapons1", "Armor1"]
      v = fn units -> View.new(put_in(state(units: units, buildings: built(), ore: 1000), ["you", "upgrades"], done)) end
      research = fn cmds -> Enum.find_value(cmds, &(&1["type"] == "Research" && &1["upgrade"])) end

      {_, commands, _} = Brain.plan(v.(workers(20) ++ soldiers(10)), nil, terrain())
      assert research.(commands) == "Harvesting2"

      {_, commands, _} = Brain.plan(v.(workers(20) ++ soldiers(15)), nil, terrain())
      assert research.(commands) == "SiegeEngineering"
    end

    test "a SiegeWorkshop trains Trebuchets, up to two" do
      shop = building(10, "SiegeWorkshop", 3, 10)
      {_, commands, _} = plan(units: workers(20), buildings: [shop | built()], ore: 1000)
      assert Enum.any?(commands, &match?(%{"buildingId" => 10, "unitType" => "Trebuchet"}, &1))

      trebs = for i <- 1..2, do: unit(300 + i, "Trebuchet", 9, 9)
      {_, commands, _} = plan(units: trebs ++ workers(20), buildings: [shop | built()], ore: 1000)
      refute Enum.any?(commands, &(&1["unitType"] == "Trebuchet"))
    end

    test "an outpost gets a Guard Tower, without needing to be rich" do
      outpost = building(20, "ResourceDepot", 30, 30)
      {_, commands, _} = plan(units: workers(20) ++ soldiers(30), buildings: [outpost | built()], ore: 300)
      assert [%{"buildingType" => "GuardTower", "x" => x, "y" => y}] = builds(commands)
      assert View.dist({x, y}, {30, 30}) in 2..4

      # Once it has one, no more.
      tower = building(21, "GuardTower", 32, 32)
      {_, commands, _} = plan(units: workers(20) ++ soldiers(30), buildings: [outpost, tower | built()], ore: 300)
      assert builds(commands) == []
    end

    test "short of ore for a Trebuchet, it saves up instead of training soldiers" do
      shop = building(10, "SiegeWorkshop", 3, 10)
      # By now: a scout out, and the TechLab busy, so only the Trebuchet wants the ore.
      units = [unit(300, "Scout", 40, 40), unit(301, "Scout", 20, 40) | workers(20) ++ soldiers(30)]
      lab = Map.put(building(6, "TechLab", 7, 12), "research", %{"upgrade" => "Harvesting2"})
      buildings = [shop, lab | Enum.reject(built(), &(&1["id"] == 6))]

      {_, commands, _} = plan(units: units, buildings: buildings, ore: 300)
      refute Enum.any?(commands, &(&1["type"] == "Produce" and &1["unitType"] in ["Trebuchet", "Soldier", "Archer"]))

      {_, commands, _} = plan(units: units, buildings: buildings, ore: 360)
      assert Enum.any?(commands, &(&1["unitType"] == "Trebuchet"))
    end

    test "but below the army floor, soldiers still come first" do
      shop = building(10, "SiegeWorkshop", 3, 10)
      {_, commands, _} = plan(units: workers(20), buildings: [shop | built()], ore: 300)
      assert Enum.any?(commands, &(&1["unitType"] == "Soldier"))
    end

    test "with an army of fifteen, four Trebuchets: two to keep home, two to send" do
      shop = building(10, "SiegeWorkshop", 3, 10)
      trebs = for i <- 1..2, do: unit(300 + i, "Trebuchet", 9, 9)
      scouts = [unit(310, "Scout", 40, 40), unit(311, "Scout", 20, 40)]
      lab = Map.put(building(6, "TechLab", 7, 12), "research", %{"upgrade" => "Harvesting2"})
      buildings = [shop, lab | Enum.reject(built(), &(&1["id"] == 6))]

      {_, commands, _} = plan(units: trebs ++ scouts ++ workers(20) ++ soldiers(15), buildings: buildings, ore: 400)
      assert Enum.any?(commands, &(&1["unitType"] == "Trebuchet"))

      four = for i <- 1..4, do: unit(300 + i, "Trebuchet", 9, 9)
      {_, commands, _} = plan(units: four ++ scouts ++ workers(20) ++ soldiers(15), buildings: buildings, ore: 400)
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
