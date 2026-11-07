defmodule Swarm.BrainTest do
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, View}

  # A scout has just looked at player 1 (the enemy in a 1v1), so waves don't wait for a look; the
  # look itself is tested under "a look before attacking".
  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  test "gathers while the army is small" do
    assert {%{mode: :gather, rally: {10, 10}}, _, _} = plan(units: workers(5) ++ soldiers(2))
  end

  test "trains a worker when there is ore and few workers" do
    {_, commands, _} = plan(units: workers(3), ore: 60)
    assert [%{"type" => "Produce", "unitType" => "Worker", "buildingId" => 1}] = commands
  end

  test "builds a Barracks with seven workers and 150 ore, and waits for it" do
    {_, commands, memory} = plan(units: workers(7), ore: 150, tick: 100)
    # The first Barracks gets three builders.
    assert [%{"type" => "Build", "buildingType" => "Barracks", "unitIds" => [builder, _, _]}] = commands
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

  describe "Guard Tower sites" do
    # Neighbors at (56, 7) and (7, 56), player 3 across the map at (56, 56).
    defp four(buildings \\ [], eliminated \\ []) do
      corners = [{1, 56, 7}, {2, 7, 56}, {3, 56, 56}]

      Map.update!(state(buildings: buildings), "players", fn [me | _] ->
        [me | for({slot, x, y} <- corners, do: %{"slot" => slot, "eliminated" => slot in eliminated, "startPosition" => %{"x" => x, "y" => y}})]
      end)
      |> View.new()
    end

    test "close to the Command Center, so the tower covers the base" do
      {x, y} = Brain.site(terrain(), four(), :front)
      assert View.dist({x, y}, {7, 7}) in 3..4
    end

    test "facing the nearest neighbor, then the other one" do
      {x, y} = first = Brain.site(terrain(), four(), :front)
      # Player 1 at (56, 7) and player 2 at (7, 56) are as near; the lower slot goes first: east.
      assert x > 7 and y <= 8

      {x, y} = Brain.site(terrain(), four([building(2, "GuardTower", elem(first, 0), elem(first, 1))]), :front)
      assert y > 7 and x <= 8
    end

    test "with a neighbor gone, toward the one still in" do
      {_x, y} = Brain.site(terrain(), four([], [1]), :front)
      assert y > 9
    end

    test "no neighbor left: toward the middle" do
      {x, y} = Brain.site(terrain(), four([], [1, 2, 3]), :front)
      assert x > 8 and y > 8
    end
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
    buildings = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), tower, backup_cc()]

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
    # 21 fighters: 7 guards, 14 attackers. Not yet.
    assert {%{mode: :gather, wave: nil}, _, _} = plan(units: soldiers(21))

    # 22 fighters: 7 guards (the newest), 15 attackers (the oldest) go.
    {strategy, _, memory} = plan(units: soldiers(22))
    assert %{mode: :attack, target: {56, 56}, wave: %{id: 1, members: members}} = strategy
    assert members == Enum.to_list(201..215)
    assert memory.next_wave == 2
  end

  test "attackers who weren't at the rally point don't go" do
    away = for s <- soldiers(22), do: %{s | "x" => 30, "y" => 30}
    assert {%{wave: nil}, _, _} = plan(units: away)
  end

  test "units trained after the launch follow the wave once five are at the rally point" do
    # Wave 1 is 201..215; seven guards stay home.
    {_, _, memory} = plan(units: soldiers(22))

    # 26 soldiers: guards 220..226, and 216..219 wait: four isn't enough.
    assert {%{wave: %{id: 1, members: members}, hold: "reinforcements: 4 of 5 at the rally point"}, _, memory} =
             plan([units: soldiers(26)], memory)

    assert members == Enum.to_list(201..215)

    # 27: 216..220 go after it, and are part of it.
    assert {%{wave: %{id: 1, members: members}, why: [{:wave_reinforced, why}]}, _, _} = plan([units: soldiers(27)], memory)
    assert members == Enum.to_list(201..220)
    assert why == "wave 1: 5 more follow it (20 in all)"
  end

  describe "why no wave leaves (strategy.hold)" do
    test "too few at the rally point" do
      assert {%{wave: nil, hold: "3 attackers at the rally point (3 in all), want 15 while nothing is scouted"}, _, _} =
               plan(units: soldiers(10))
    end

    test "not strong enough against what we know of them" do
      strong = %{Brain.new_memory() | enemies: Map.new(1..12, &{900 + &1, %{"id" => 900 + &1, "type" => "Soldier", "owner" => 1, "hp" => 110, "x" => 56, "y" => 56, "seen" => 100}})}
      assert {%{wave: nil, hold: hold}, _, _} = plan([units: soldiers(22)], strong)
      assert hold == "15 attackers at the rally point (15 in all), strength 14850 vs 1.5 x 11880 = 17820 known of player 1"
    end

    test "home couldn't hold without them" do
      raiders = for i <- 1..8, do: unit(900 + i, "Soldier", 12, 9, owner: 1)
      assert {%{wave: nil, hold: "home couldn't hold the raid without them" <> _}, _, _} = plan(units: soldiers(22) ++ raiders)
    end

    test "nothing to say once a wave leaves" do
      assert {%{wave: %{id: 1}, hold: nil}, _, _} = plan(units: soldiers(22))
    end
  end

  describe "a look before attacking" do
    # No look yet. The spot: six tiles short of their start at (56, 56), toward us.
    defp fresh(opts, memory \\ Brain.new_memory()), do: Brain.plan(View.new(state(opts)), memory, terrain())

    test "once five attackers wait, a scout is sent to look, and the wave waits for it" do
      {s, _, memory} = fresh(units: soldiers(22))
      assert %{wave: nil, look: {50, 50}, why: [{:scout_sent, "scout looking at player 1 by (50,50)"}]} = s
      assert s.hold =~ "scout looking at player 1"
      assert %{look: %{owner: 1, pos: {50, 50}, at: 100, done: nil}} = memory
    end

    test "not with fewer than five waiting" do
      assert {%{look: nil, why: []}, _, %{look: nil}} = fresh(units: soldiers(11))
    end

    test "when a scout gets there, it reports what it sees and the wave goes" do
      {_, _, memory} = fresh(units: soldiers(22))
      scout = unit(300, "Scout", 50, 51)
      enemies = for i <- 1..2, do: unit(900 + i, "Soldier", 55, 55, owner: 1)

      assert {%{wave: %{id: 1}, look: nil, why: [{:scouted, "scouted player 1: 2 fighters, strength 1980"} | _]}, _, %{look: %{done: 110}}} =
               fresh([units: [scout | soldiers(22) ++ enemies], tick: 110], memory)
    end

    test "if no scout gets there in 40 ticks, the wave goes on what we know" do
      {_, _, memory} = fresh(units: [unit(300, "Scout", 20, 20) | soldiers(22)])
      assert {%{wave: nil}, _, memory} = fresh([units: [unit(300, "Scout", 25, 25) | soldiers(22)], tick: 120], memory)

      assert {%{wave: %{id: 1}, why: [{:scouted, "no look at player 1" <> _} | _]}, _, _} =
               fresh([units: [unit(300, "Scout", 25, 25) | soldiers(22)], tick: 140], memory)
    end

    test "with no scout at all, it doesn't wait" do
      {_, _, memory} = fresh(units: soldiers(22))
      assert {%{wave: %{id: 1}}, _, _} = fresh([units: soldiers(22), tick: 101], memory)
    end

    test "a counterattack doesn't wait for one" do
      {attackers, guards} = Enum.split(soldiers(22), 15)
      near = Enum.map(attackers, &%{&1 | "x" => 14, "y" => 14}) ++ guards
      memory = %{Brain.new_memory() | raid: %{at: 95, kills: 3}}
      assert {%{wave: %{id: 1}}, _, _} = fresh([units: near], memory)
    end

    test "with a wave out on a new player, no look: a scout is in front of the wave already" do
      # The wave went after player 1 (eliminated now); player 2 at (7, 56) is next.
      wave = %{id: 1, members: Enum.to_list(201..215), owner: 1, released: true}
      memory = %{looked(nil) | wave: wave, next_wave: 2}

      two =
        Map.update!(state(units: soldiers(22)), "players", fn [me, them] ->
          [me, Map.put(them, "eliminated", true), %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56}}]
        end)

      assert {%{wave: %{id: 1}, target: {7, 56}, look: nil, why: []}, _, _} = Brain.plan(View.new(two), memory, terrain())
    end
  end

  describe "what we remember of the enemy" do
    test "enemies we should see where we last saw them, and don't, are forgotten" do
      # Our soldiers at (10, 10) see five tiles; (12, 12) is in sight, (40, 40) isn't.
      near = %{"id" => 900, "type" => "Soldier", "owner" => 1, "hp" => 110, "x" => 12, "y" => 12, "seen" => 90}
      far = %{"id" => 901, "type" => "Soldier", "owner" => 1, "hp" => 110, "x" => 40, "y" => 40, "seen" => 90}
      memory = %{Brain.new_memory() | enemies: %{900 => near, 901 => far}}
      assert {_, _, %{enemies: enemies}} = plan([units: soldiers(3)], memory)
      assert Map.keys(enemies) == [901]
    end
  end

  describe "the strongest single player" do
    defp army(owner, n, x, y, first), do: for(i <- 1..n, do: unit(first + i, "Soldier", x, y, owner: owner))

    test "two others fighting each other near the wave don't add up: it stays" do
      # Ten of ours at the front; eight each of players 2 and 3 there.
      wave = for s <- Enum.take(soldiers(10), 10), do: %{s | "x" => 45, "y" => 45}
      memory = %{Brain.new_memory() | wave: %{id: 1, members: Enum.to_list(201..210), released: true}, next_wave: 2}
      others = army(2, 8, 47, 47, 900) ++ army(3, 8, 46, 48, 950)
      assert {%{wave: %{id: 1}}, _, _} = plan([units: wave ++ others], memory)
    end

    test "one player stronger than the whole wave: it comes back, saying who" do
      wave = for s <- Enum.take(soldiers(10), 10), do: %{s | "x" => 45, "y" => 45}
      memory = %{Brain.new_memory() | wave: %{id: 1, members: Enum.to_list(201..210), released: true}, next_wave: 2}
      assert {%{wave: nil, why: [{:wave_recalled, "wave 1: outmatched by player 3, strength 9900 vs 11880 nearby"}]}, _, _} =
               plan([units: wave ++ army(3, 12, 47, 47, 900)], memory)
    end

    test "no wave leaves into a stronger army we can see on the way" do
      assert {%{wave: nil, hold: hold}, _, _} = plan(units: soldiers(22) ++ army(3, 20, 30, 30, 900))
      assert hold =~ "player 3's army is in the way (19800 vs our 14850)"
    end

    test "but two weaker ones on the way, likely fighting each other, don't stop it" do
      assert {%{wave: %{id: 1}}, _, _} = plan(units: soldiers(22) ++ army(2, 10, 30, 30, 900) ++ army(3, 10, 31, 31, 950))
    end
  end

  describe "a counterattack" do
    # Fifteen attackers near the rally point (10, 10), but not at it: (14, 14) is four tiles out.
    defp near_rally do
      {attackers, guards} = Enum.split(soldiers(22), 15)
      Enum.map(attackers, &%{&1 | "x" => 14, "y" => 14}) ++ guards
    end

    test "right after we beat a raid, everyone near the rally point goes" do
      memory = %{Brain.new_memory() | raid: %{at: 95, kills: 3}}
      assert {%{wave: %{members: members}, why: [{:wave_launched, "counterattack: " <> _}]}, _, %{raid: nil}} =
               plan([units: near_rally()], memory)

      assert length(members) == 15
    end

    test "not without the raid, or after only a kill or two, or long after" do
      assert {%{wave: nil}, _, _} = plan(units: near_rally())
      assert {%{wave: nil}, _, _} = plan([units: near_rally()], %{Brain.new_memory() | raid: %{at: 95, kills: 2}})
      assert {%{wave: nil}, _, _} = plan([units: near_rally(), tick: 140], %{Brain.new_memory() | raid: %{at: 95, kills: 3}})
    end

    test "raiders we kill at home are counted" do
      # An enemy soldier remembered by the base at (12, 9), killed this tick.
      enemy = %{"id" => 900, "type" => "Soldier", "owner" => 1, "hp" => 110, "x" => 12, "y" => 9, "seen" => 99}
      memory = %{Brain.new_memory() | enemies: %{900 => enemy}, raid: %{at: 99, kills: 2}}
      killed = state(units: soldiers(5)) |> Map.put("events", [%{"kind" => "UnitKilled", "entityId" => 900}])
      assert {_, _, %{raid: %{kills: 3}}} = Brain.plan(View.new(killed), memory, terrain())
    end
  end

  test "a wave whose front meets more than it is, with reinforcements on the way, stays out" do
    # Five in front at (45, 45) against eight; ten more walking up at (25, 25).
    front = for i <- 1..5, do: unit(200 + i, "Soldier", 45, 45)
    behind = for i <- 6..15, do: unit(200 + i, "Soldier", 25, 25)
    enemies = for i <- 1..8, do: unit(900 + i, "Soldier", 47, 47, owner: 1)
    memory = %{Brain.new_memory() | wave: %{id: 1, members: Enum.to_list(201..215), released: true}, next_wave: 2}
    assert {%{wave: %{id: 1}}, _, _} = plan([units: front ++ behind ++ enemies], memory)

    # Without them, it comes back.
    memory = %{memory | wave: %{memory.wave | members: Enum.to_list(201..205)}}
    assert {%{wave: nil, why: [{:wave_recalled, "wave 1: outmatched" <> _}]}, _, _} = plan([units: front ++ enemies], memory)
  end

  test "recalls the wave when fewer than five of it are left" do
    {_, _, memory} = plan(units: soldiers(22))
    # 201..205 still alive: five left, the wave stays out.
    survivors = Enum.take(soldiers(22), 5) ++ Enum.drop(soldiers(22), 15)
    assert {%{wave: %{members: [201, 202, 203, 204, 205]}}, _, _} = plan([units: survivors], memory)

    four_left = Enum.slice(soldiers(22), 1..4) ++ Enum.drop(soldiers(22), 15)
    assert {%{wave: nil}, _, %{wave: nil, next_wave: 2}} = plan([units: four_left], memory)
  end

  describe "the wave and attacks at home" do
    # Wave 1 (201..215) is out by the enemy; 216..220 are home.
    defp wave_out do
      {_, _, memory} = plan(units: soldiers(22))
      out = for s <- Enum.take(soldiers(22), 15), do: %{s | "x" => 45, "y" => 45}
      {out ++ Enum.drop(soldiers(22), 15), memory}
    end

    defp raiders(n, x, y), do: for(i <- 1..n, do: unit(900 + i, "Soldier", x, y, owner: 1))

    test "comes home when the base can't hold" do
      {ours, memory} = wave_out()
      assert {%{wave: nil, why: [{:wave_recalled, why}]}, _, %{recalled_at: 110}} =
               plan([units: ours ++ raiders(10, 12, 9), tick: 110], memory)

      assert why =~ "home under attack"
    end

    test "comes home for our workers out in the field too, not only the base" do
      {ours, memory} = wave_out()
      miners = for i <- 1..4, do: unit(100 + i, "Worker", 30, 8)
      assert {%{mode: :defend, threat: nil, wave: nil}, _, _} = plan([units: ours ++ miners ++ raiders(10, 31, 8)], memory)
    end

    test "stays out for a raid home can hold" do
      {ours, memory} = wave_out()
      assert {%{mode: :defend, wave: %{id: 1}}, _, _} = plan([units: ours ++ raiders(1, 12, 9)], memory)
    end

    test "no new wave until things have been quiet for a while" do
      {ours, memory} = wave_out()
      {_, _, memory} = plan([units: ours ++ raiders(10, 12, 9), tick: 110], memory)

      # Raid over, everyone back at the rally point.
      assert {%{mode: :gather, wave: nil}, _, memory} = plan([units: soldiers(22), tick: 120], memory)
      assert {%{mode: :attack, wave: %{id: 2}}, _, _} = plan([units: soldiers(22), tick: 130], memory)
    end
  end

  test "a wave still leaves when home can hold the raid without it" do
    enemy = unit(900, "Soldier", 12, 9, owner: 1)
    assert {%{mode: :defend, wave: %{id: 1}}, _, _} = plan(units: soldiers(22) ++ [enemy])
  end

  test "no wave leaves while the base is under an attack home can't hold without it" do
    enemies = for i <- 1..8, do: unit(900 + i, "Soldier", 12, 9, owner: 1)
    assert {%{mode: :defend, wave: nil}, _, _} = plan(units: soldiers(22) ++ enemies)
  end

  test "a scout poking at the base doesn't hold the wave" do
    scout = unit(900, "Scout", 15, 12, owner: 1)
    assert {%{wave: %{id: 1}}, _, _} = plan(units: soldiers(22) ++ [scout])
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

    test "two scouts, once a Barracks is done" do
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
      assert {%{wave: nil}, _, _} = plan([units: soldiers(22)], strong)

      # 12 attackers (7 guards stay) against 2 soldiers: go.
      weak = %{Brain.new_memory() | enemies: seen_enemies(2)}
      assert {%{wave: %{members: members}}, _, _} = plan([units: soldiers(19)], weak)
      assert length(members) == 12
    end

    test "with several opponents, only the one we attack counts" do
      # A third player at (40, 7) is closer than player 1 at (56, 56), so it is the target.
      three = Map.update!(state(units: soldiers(22)), "players", fn ps ->
        ps ++ [%{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 40, "y" => 7}}]
      end)

      # 12 soldiers of player 1, and 2 of player 2.
      armies =
        for {id, owner} <- Enum.map(1..12, &{900 + &1, 1}) ++ [{950, 2}, {951, 2}], into: %{} do
          {id, %{"id" => id, "owner" => owner, "type" => "Soldier", "hp" => 110, "x" => 56, "y" => 56, "seen" => 100}}
        end

      memory = %{Brain.new_memory() | enemies: armies}
      assert {%{target: {40, 7}, wave: %{}}, _, _} = Brain.plan(View.new(three), looked(memory, 2), terrain())
    end

    test "launches and recalls say why" do
      weak = %{Brain.new_memory() | enemies: seen_enemies(2)}
      {%{why: [{:wave_launched, why}]}, _, memory} = plan([units: soldiers(19)], weak)
      assert why == "wave 1 at player 1: 12 attackers, strength 11880 vs 1980 known"

      four_left = Enum.slice(soldiers(19), 0..3) ++ Enum.drop(soldiers(19), 12)
      assert {%{why: [{:wave_recalled, "wave 1: only 4 left"}]}, _, _} = plan([units: four_left], memory)
    end

    test "goes after the weaker of the two nearest opponents, never one across the map" do
      # Us at (7, 7). Neighbors at (56, 7) and (7, 56); across the map at (56, 56).
      four = fn survival ->
        Map.update!(state(units: soldiers(22)), "players", fn [me | _] ->
          [me |
             for {slot, x, y} <- [{1, 56, 7}, {2, 7, 56}, {3, 56, 56}] do
               %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y},
                 "score" => %{"survival" => survival[slot], "total" => 0}}
             end]
        end)
      end

      {s, _, _} = Brain.plan(View.new(four.(%{1 => 3000, 2 => 1200, 3 => 100})), looked(nil, 2), terrain())
      assert %{target: {7, 56}, wave: %{owner: 2}} = s

      {s, _, _} = Brain.plan(View.new(four.(%{1 => 900, 2 => 1200, 3 => 100})), looked(nil, 1), terrain())
      assert %{target: {56, 7}, wave: %{owner: 1}} = s
    end

    test "a wave sticks to the opponent it went after" do
      two = fn survival ->
        Map.update!(state(units: soldiers(22)), "players", fn [me, them] ->
          [me, Map.put(them, "score", %{"survival" => survival[1], "total" => 0}),
           %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56},
             "score" => %{"survival" => survival[2], "total" => 0}}]
        end)
      end

      {%{wave: %{owner: 2}}, _, memory} = Brain.plan(View.new(two.(%{1 => 3000, 2 => 500})), looked(nil, 2), terrain())
      # Player 1 is now the weaker; the wave out stays on player 2.
      assert {%{target: {7, 56}, wave: %{owner: 2}}, _, _} =
               Brain.plan(View.new(two.(%{1 => 100, 2 => 500})), memory, terrain())
    end

    test "the target is that opponent's building nearest us" do
      buildings = [building(9, "Barracks", 40, 40, 1), building(8, "Barracks", 30, 30, 1)]
      assert {%{target: {30, 30}}, _, _} = plan(units: soldiers(6), buildings: buildings)
    end

    test "two Trebuchets at the rally point go with the wave; it holds short of the target for them" do
      # None stay home: both go.
      trebs = for i <- 1..2, do: unit(300 + i, "Trebuchet", 10, 10)
      {s, _, memory} = plan(units: trebs ++ soldiers(22))
      assert %{wave: %{staging: {47, 47}, released: false, members: members}} = s
      assert 301 in members and 302 in members
      assert [{:wave_launched, "wave 1 at player 1: 15 attackers and 2 trebuchets, nothing scouted yet"}] = s.why

      # Not there yet: still holding.
      assert {%{wave: %{released: false}}, _, _} = plan([units: trebs ++ soldiers(22), tick: 110], memory)

      # There: the wave goes in.
      arrived = Enum.map(trebs, &%{&1 | "x" => 47, "y" => 47})
      assert {%{wave: %{released: true}, why: [{:wave_released, _}]}, _, _} =
               plan([units: arrived ++ soldiers(22), tick: 120], memory)

      # Or stuck: it goes in after 60 ticks anyway.
      assert {%{wave: %{released: true}}, _, _} = plan([units: trebs ++ soldiers(22), tick: 160], memory)
    end

    test "one Trebuchet at the rally point isn't enough: the wave goes without it" do
      {s, _, _} = plan(units: [unit(301, "Trebuchet", 10, 10) | soldiers(22)])
      assert %{wave: %{released: true, members: members}} = s
      refute 301 in members
    end

    test "never fewer than twelve in a wave" do
      weak = %{Brain.new_memory() | enemies: seen_enemies(1)}
      # 18 soldiers: 7 guards, 11 attackers.
      assert {%{wave: nil, hold: hold}, _, _} = plan([units: soldiers(18)], weak)
      assert hold =~ "want 12"
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

  test "no wave leaves while an outpost is under an attack home can't hold without it" do
    miners = for i <- 1..6, do: unit(400 + i, "Worker", 31, 31, activity: "Gathering")
    enemies = for i <- 1..12, do: unit(900 + i, "Soldier", 34, 34, owner: 1)
    {strategy, _, _} = plan(units: soldiers(25) ++ miners ++ enemies, buildings: [building(50, "ResourceDepot", 30, 30)])
    assert %{mode: :defend, wave: nil} = strategy
  end

  test "no wave leaves while our workers out in the field are attacked by more than home can hold" do
    miner = unit(101, "Worker", 42, 40, activity: "Gathering")
    enemies = for i <- 1..10, do: unit(900 + i, "Soldier", 40, 40, owner: 1)
    assert {%{mode: :defend, wave: nil}, _, _} = plan(units: [miner | enemies ++ soldiers(25)])
  end

  describe "who builds" do
    defp build_of(commands, type), do: Enum.find(commands, &match?(%{"type" => "Build", "buildingType" => ^type}, &1))

    test "a depot: the workers mining the ore it will serve, up to five" do
      # Seven mining the field at (40, 40); the depot goes by it.
      {_, commands, _} = plan(units: far_miners(7), deposits: far_field(), ore: 200)
      assert %{"unitIds" => ids} = build_of(commands, "ResourceDepot")
      assert length(ids) == 5 and Enum.all?(ids, &(&1 in 101..107))
    end

    test "a depot with nobody mining there yet: the closest worker" do
      # Ten workers by the Command Center, short of ore at home: a depot by the closest other ore.
      deposits = [%{"id" => 4, "x" => 2, "y" => 7, "remaining" => 100}, %{"id" => 60, "x" => 20, "y" => 20, "remaining" => 900}]
      memory = %{Brain.new_memory() | ore_short_since: 50}
      {_, commands, _} = plan([units: workers(10), deposits: deposits, ore: 200, tick: 100], memory)
      assert %{"unitIds" => [_]} = build_of(commands, "ResourceDepot")
    end

    test "the second Barracks: the usual one builder" do
      barracks = building(2, "Barracks", 11, 7)
      depot = building(3, "ResourceDepot", 4, 11)
      tower = building(5, "GuardTower", 12, 12)
      lab = building(6, "TechLab", 7, 12)
      # Soldiers enough to be past the army floor, which would take the ore first.
      {_, commands, _} = plan(units: workers(15) ++ soldiers(10), buildings: [barracks, depot, tower, lab, backup_cc()], ore: 160)
      assert %{"unitIds" => [_]} = build_of(commands, "Barracks")
    end
  end

  describe "co-ops where the workers are" do
    # A field 30+ tiles out, past any drop-off's reach; the home deposit by the Command Center is gone.
    defp far_field, do: for(i <- 0..2, do: %{"id" => 60 + i, "x" => 40 + i, "y" => 40, "remaining" => 900})
    defp far_miners(n), do: for(i <- 1..n, do: unit(100 + i, "Worker", 41, 41, activity: "Gathering", target_id: 60))

    defp depot_builds(commands),
      do: for(%{"type" => "Build", "buildingType" => "ResourceDepot"} = c <- commands, do: c)

    test "three workers mining a far field get a depot by it, right away" do
      {_, commands, _} = plan(units: far_miners(3), deposits: far_field(), ore: 200)
      assert [%{"x" => x, "y" => y}] = depot_builds(commands)
      assert View.dist({x, y}, {41, 40}) <= 4
    end

    test "not for two" do
      {_, commands, _} = plan(units: far_miners(2), deposits: far_field(), ore: 200)
      assert depot_builds(commands) == []
    end

    test "not when one is already going up there" do
      site = Map.put(building(50, "ResourceDepot", 41, 43), "completed", false)
      {_, commands, _} = plan(units: far_miners(3), deposits: far_field(), buildings: [site], ore: 200)
      # Only a worker sent to finish that one, no second depot.
      assert Enum.all?(depot_builds(commands), &({&1["x"], &1["y"]} == {41, 43}))
    end
  end

  describe "a backup Command Center" do
    test "goes up after the first tower, with two builders, hidden behind our base" do
      start = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 11), building(4, "GuardTower", 12, 12)]
      {_, commands, _} = plan(units: workers(12) ++ soldiers(10), buildings: start, ore: 1000)
      assert [%{"buildingType" => "CommandCenter", "unitIds" => [_, _], "x" => x, "y" => y}] =
               for(%{"type" => "Build"} = c <- commands, do: c)

      # Us at (7, 7), the enemy at (56, 56), the middle at (32, 32): 10–25 from us, on our side,
      # and no nearer the middle than our base is.
      assert View.dist({x, y}, {7, 7}) in 10..25
      assert View.dist({x, y}, {56, 56}) > View.dist({x, y}, {7, 7})
      assert View.dist({x, y}, {32, 32}) >= View.dist({7, 7}, {32, 32})
    end

    test "on a big map, behind our base toward our corner, not in the middle" do
      # 112 x 112 like a 15-player brawl: us at (22, 22), neighbors along the ring.
      starts = [{1, 56, 10}, {2, 10, 56}, {3, 90, 22}, {4, 22, 90}, {5, 102, 56}, {6, 56, 102}, {7, 90, 90}]

      big_map =
        state()
        |> Map.merge(%{"mapWidth" => 112, "mapHeight" => 112})
        |> Map.update!("players", fn [me | _] ->
          [put_in(me, ["startPosition"], %{"x" => 22, "y" => 22}) |
             for({slot, x, y} <- starts, do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}})]
        end)
        |> Map.update!("buildings", fn [_cc | rest] -> [building(1, "CommandCenter", 22, 22) | rest] end)

      terrain = List.duplicate(String.duplicate(".", 112), 112)
      {x, y} = Brain.site(terrain, View.new(big_map), :hideout)
      assert View.dist({x, y}, {22, 22}) in 18..30
      # Behind us: farther from the middle (56, 56) than our base, toward the corner.
      assert x < 22 or y < 22
      assert View.dist({x, y}, {56, 56}) > View.dist({22, 22}, {56, 56})
    end

    test "on a crowded map, still on our side and out of the middle" do
      more = [{2, 31, 7}, {3, 56, 7}, {4, 7, 31}, {5, 56, 31}, {6, 7, 56}, {7, 31, 56}]

      v =
        Map.update!(state(), "players", fn ps ->
          ps ++ for({slot, x, y} <- more, do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}})
        end)
        |> View.new()

      site = Brain.site(terrain(), v, :hideout)
      assert View.dist(site, {7, 7}) in 6..30
      assert View.dist(site, {32, 32}) >= 10
      assert Enum.all?([{31, 7}, {7, 31}], &(View.dist(site, &1) >= View.dist(site, {7, 7})))
    end

    test "is rebuilt if lost" do
      start = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 11), building(4, "GuardTower", 12, 12)]
      {_, commands, _} = plan(units: workers(20) ++ soldiers(10), buildings: start ++ [backup_cc()], ore: 1000)
      refute Enum.any?(commands, &(&1["buildingType"] == "CommandCenter"))

      {_, commands, _} = plan(units: workers(20) ++ soldiers(10), buildings: start, ore: 1000)
      assert Enum.any?(commands, &(&1["buildingType"] == "CommandCenter"))
    end

    test "workers don't mine by it: it isn't one of our drop-offs while our base stands" do
      v = View.new(state(buildings: [backup_cc()]))
      assert View.drop_offs(v) == [{7, 7}]
    end
  end

  describe "the serum" do
    # A wave of ten soldiers out at (45, 45); ten more at home by the rally point.
    defp wave_at_front, do: for(s <- soldiers(10), do: %{s | "x" => 45, "y" => 45})
    defp at_home, do: for(i <- 11..20, do: unit(200 + i, "Soldier", 10, 10))
    defp wave_memory(serum \\ nil), do: %{looked(nil) | wave: %{id: 1, members: Enum.to_list(201..210), released: true}, next_wave: 2, serum: serum}
    defp raiders(n), do: for(i <- 1..n, do: unit(900 + i, "Soldier", 12, 9, owner: 1))

    test "taken when home is overrun: the raid is stronger than all that can meet it there" do
      # Twelve raiders against the ten soldiers at home.
      assert {%{serum: :take}, _, _} = plan([units: wave_at_front() ++ at_home() ++ raiders(12)], wave_memory())
    end

    test "not for the wave's own fights, however big" do
      army = for i <- 1..20, do: unit(900 + i, "Soldier", 47, 47, owner: 1)
      assert {%{serum: nil}, _, _} = plan([units: wave_at_front() ++ at_home() ++ army], wave_memory())
    end

    test "not for a raid home can hold, nor twice, nor when it's off" do
      assert {%{serum: nil}, _, _} = plan([units: wave_at_front() ++ at_home() ++ raiders(8)], wave_memory())

      overrun = wave_at_front() ++ at_home() ++ raiders(12)
      assert {%{serum: nil}, _, _} = plan([units: overrun], wave_memory(:spent))
      assert {%{serum: nil}, _, _} = plan([units: overrun], wave_memory({:until, 140}))
      assert {%{serum: nil}, _, _} = plan([units: overrun], wave_memory(:off))
    end

    test "not with too few soldiers to be worth it" do
      few = for i <- 1..5, do: unit(200 + i, "Soldier", 10, 10)
      assert {%{serum: nil}, _, _} = plan(units: few ++ raiders(12))
    end
  end

  describe "an enemy tower at our door" do
    # Player 1's finished tower at (16, 12), 9 tiles from our Command Center at (7, 7).
    defp their_tower, do: building(800, "GuardTower", 16, 12, 1)

    test "no strike with fewer than eight: it says so, and no wave leaves meanwhile" do
      # 7 soldiers at home: not enough to go at it.
      assert {%{wave: nil, hold: hold}, _, _} = plan(units: soldiers(7), buildings: [their_tower()])
      assert hold =~ "strike at player 1's tower at (16,12): 7 fighters at home, want 8"
    end

    test "then everyone at home goes at it together, and it is the target" do
      assert {%{wave: %{kind: :strike, members: members}, target: {16, 12}, why: [{:wave_launched, "strike at " <> _}]}, _, _} =
               plan(units: soldiers(10), buildings: [their_tower()])

      assert length(members) == 10
    end

    test "more when it is guarded" do
      guards = for i <- 1..6, do: unit(900 + i, "Soldier", 17, 13, owner: 1)
      assert {%{wave: nil, hold: "strike at" <> _}, _, _} = plan(units: soldiers(10) ++ guards, buildings: [their_tower()])
    end

    test "the strike comes home once the tower is down" do
      {_, _, memory} = plan(units: soldiers(10), buildings: [their_tower()])
      at_it = for s <- soldiers(10), do: %{s | "x" => 15, "y" => 11}
      assert {%{wave: nil, why: [{:wave_recalled, "strike: player 1's tower at (16,12) is down"}]}, _, _} =
               plan([units: at_it, tick: 130], memory)
    end

    test "a site going up by our base is razed now, unless a tower covers it" do
      site = Map.put(building(801, "Barracks", 18, 7, 1), "completed", false)
      assert {%{raze: 801}, _, _} = plan(units: soldiers(5), buildings: [site])

      covered = Map.put(building(802, "Barracks", 16, 14, 1), "completed", false)
      assert {%{raze: nil}, _, _} = plan(units: soldiers(5), buildings: [their_tower(), covered])
    end
  end

  # A backup Command Center out of the way, as the build order puts one.
  defp backup_cc, do: building(19, "CommandCenter", 40, 20)

  describe "a big game (six players or more)" do
    # Eight players: us at (7, 7), player 1 at (56, 56), and six more around the edge.
    defp big(state) do
      more = [{2, 31, 7}, {3, 56, 7}, {4, 7, 31}, {5, 56, 31}, {6, 7, 56}, {7, 31, 56}]

      Map.update!(state, "players", fn ps ->
        ps ++ for({slot, x, y} <- more, do: %{"slot" => slot, "eliminated" => false, "startPosition" => %{"x" => x, "y" => y}})
      end)
    end

    defp big_plan(opts, memory \\ Brain.new_memory()), do: Brain.plan(View.new(big(state(opts))), memory, terrain())

    # Ten towers around the base at (7, 7).
    defp square, do: for({x, y} <- [{1, 1}, {7, 1}, {13, 1}, {1, 7}, {13, 7}, {1, 13}, {7, 13}, {13, 13}, {4, 13}, {13, 4}], do: building(500 + x * 20 + y, "GuardTower", x, y))

    test "no first wave before eighteen attackers" do
      # 24 soldiers: 7 guards, 17 attackers.
      assert {%{wave: nil, hold: hold}, _, _} = big_plan(units: soldiers(24))
      assert hold =~ "want 18"

      # 25, but no tower square yet: still waiting.
      assert {%{wave: nil, hold: hold}, _, _} = big_plan(units: soldiers(25))
      assert hold =~ "tower square first (0 of 10)"

      # With the square up: a scout looks first, then the wave of 18 goes.
      {_, _, memory} = big_plan(units: soldiers(25), buildings: square())
      memory = %{memory | look: %{memory.look | done: 100}}
      assert {%{wave: %{members: members}}, _, _} = big_plan([units: soldiers(25), buildings: square()], memory)
      assert length(members) == 18
    end

    test "after the first, at least fifteen a wave" do
      # 21 soldiers: 7 guards, 14 attackers; wave 1 has been and gone.
      {_, _, memory} = big_plan(units: soldiers(21))
      memory = %{memory | next_wave: 2, look: memory.look && %{memory.look | done: 100}}
      assert {%{wave: nil, hold: hold}, _, _} = big_plan([units: soldiers(21)], memory)
      assert hold =~ "want 15"
    end

    test "thirty workers, not twenty" do
      trains_worker? = fn commands -> Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Worker"}, &1)) end
      {_, commands, _} = big_plan(units: workers(25) ++ soldiers(10), ore: 1000)
      assert trains_worker?.(commands)

      {_, commands, _} = big_plan(units: workers(30) ++ soldiers(10), ore: 1000)
      refute trains_worker?.(commands)

      # A small game stops at twenty.
      {_, commands, _} = plan(units: workers(20) ++ soldiers(10), ore: 1000)
      refute trains_worker?.(commands)
    end

    test "army first: Barracks early, the backup at 10 fighters, the rest of the square at 15" do
      builds = fn commands -> for %{"type" => "Build", "buildingType" => t} <- commands, do: t end
      start = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 11)]

      # A first tower, then a second Barracks before more towers.
      {_, commands, _} = big_plan(units: workers(13) ++ soldiers(10), buildings: start, ore: 1000)
      assert builds.(commands) == ["GuardTower"]

      tower = building(4, "GuardTower", 10, 10)
      {_, commands, _} = big_plan(units: workers(13) ++ soldiers(10), buildings: [tower | start], ore: 1000)
      assert builds.(commands) == ["Barracks"]

      # The early part done: nothing more until the army is 10 strong, then the backup.
      early = start ++ [tower, building(5, "Barracks", 12, 3), building(6, "TechLab", 7, 12), building(7, "GuardTower", 4, 4),
                        building(8, "Barracks", 3, 7), building(9, "GuardTower", 13, 4)]
      {_, commands, _} = big_plan(units: workers(20) ++ soldiers(9), buildings: early, ore: 300)
      assert builds.(commands) == []

      {_, commands, _} = big_plan(units: workers(20) ++ soldiers(10), buildings: early, ore: 1000)
      assert builds.(commands) == ["CommandCenter"]

      # With the backup: the rest of the square only from 15 fighters.
      {_, commands, _} = big_plan(units: workers(20) ++ soldiers(14), buildings: [backup_cc() | early], ore: 300)
      assert builds.(commands) == []

      {_, commands, _} = big_plan(units: workers(20) ++ soldiers(15), buildings: [backup_cc() | early], ore: 300)
      assert builds.(commands) == ["GuardTower"]
    end

    test "towers go on a square around the whole base, spread out" do
      v = View.new(big(state()))
      {x1, y1} = first = Brain.site(terrain(), v, :square)
      assert View.dist(first, {7, 7}) in 5..6

      v = View.new(big(state(buildings: [building(4, "GuardTower", x1, y1)])))
      second = Brain.site(terrain(), v, :square)
      assert View.dist(second, {7, 7}) in 5..6 and View.dist(second, first) >= 5
    end

    test "no co-op away from home before fifteen fighters" do
      deposits = for i <- 0..2, do: %{"id" => 60 + i, "x" => 40 + i, "y" => 40, "remaining" => 900}
      miners = for i <- 1..3, do: unit(100 + i, "Worker", 41, 41, activity: "Gathering", target_id: 60)
      depots = fn commands -> for %{"type" => "Build", "buildingType" => "ResourceDepot"} = c <- commands, do: c end

      {_, commands, _} = big_plan(units: miners ++ soldiers(14), deposits: deposits, ore: 200)
      assert depots.(commands) == []

      {_, commands, _} = big_plan(units: miners ++ soldiers(15), deposits: deposits, ore: 200)
      assert [_] = depots.(commands)
    end

    test "a co-op's tower comes before the rest of the build order" do
      outpost = building(20, "ResourceDepot", 30, 30)
      miners = for i <- 1..6, do: unit(100 + i, "Worker", 31, 31, activity: "Gathering")
      start = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 11)]
      {_, commands, _} = big_plan(units: miners ++ workers(6) ++ soldiers(10), buildings: [outpost | start], ore: 300)
      assert [%{"buildingType" => "GuardTower", "x" => x, "y" => y}] = for(%{"type" => "Build"} = c <- commands, do: c)
      assert View.dist({x, y}, {30, 30}) <= 4
    end
  end

  test "a co-op goes two tiles from as much of its ore as it can: mining with no walking" do
    # A row of ore at (18..20, 7), 11 tiles from the Command Center at (7, 7).
    ore = for x <- 18..20, do: %{"id" => 40 + x, "x" => x, "y" => 7, "remaining" => 900}
    {x, y} = Brain.site(terrain(), View.new(state(deposits: ore)), :ore)
    assert Enum.all?(ore, &(View.dist({&1["x"], &1["y"]}, {x, y}) == 2))
  end

  test "Barracks and the TechLab go behind the Command Center, away from the neighbors" do
    # Us at (7, 7), the enemy at (56, 56): behind is up and to the left.
    {x, y} = Brain.site(terrain(), View.new(state()), :base)
    assert (x - 56) ** 2 + (y - 56) ** 2 > (7 - 56) ** 2 + (7 - 56) ** 2
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
        building(9, "ResourceDepot", 3, 3),
        backup_cc()
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

    test "the SiegeWorkshop waits for an army of twenty-five" do
      researched = fn units ->
        View.new(put_in(state(units: units, buildings: built(), ore: 1000), ["you", "upgrades"], ["SiegeEngineering"]))
      end

      {_, commands, _} = Brain.plan(researched.(workers(20) ++ soldiers(24)), nil, terrain())
      refute Enum.any?(builds(commands), &(&1["buildingType"] == "SiegeWorkshop"))

      {_, commands, _} = Brain.plan(researched.(workers(20) ++ soldiers(25)), nil, terrain())
      assert [%{"buildingType" => "SiegeWorkshop"}] = builds(commands)
    end

    test "SiegeEngineering is skipped in the research order until then" do
      done = ["Harvesting1", "Weapons1", "Armor1"]
      v = fn units -> View.new(put_in(state(units: units, buildings: built(), ore: 1000), ["you", "upgrades"], done)) end
      research = fn cmds -> Enum.find_value(cmds, &(&1["type"] == "Research" && &1["upgrade"])) end

      {_, commands, _} = Brain.plan(v.(workers(20) ++ soldiers(10)), nil, terrain())
      assert research.(commands) == "Harvesting2"

      {_, commands, _} = Brain.plan(v.(workers(20) ++ soldiers(25)), nil, terrain())
      assert research.(commands) == "SiegeEngineering"
    end

    test "a SiegeWorkshop trains Trebuchets for the waves, up to two, only with an army of 25" do
      shop = building(10, "SiegeWorkshop", 3, 10)
      {_, commands, _} = plan(units: workers(20) ++ soldiers(24), buildings: [shop | built()], ore: 1000)
      refute Enum.any?(commands, &(&1["unitType"] == "Trebuchet"))

      {_, commands, _} = plan(units: workers(20) ++ soldiers(25), buildings: [shop | built()], ore: 1000)
      assert Enum.any?(commands, &match?(%{"buildingId" => 10, "unitType" => "Trebuchet"}, &1))

      trebs = for i <- 1..2, do: unit(300 + i, "Trebuchet", 9, 9)
      {_, commands, _} = plan(units: trebs ++ workers(20) ++ soldiers(25), buildings: [shop | built()], ore: 1000)
      refute Enum.any?(commands, &(&1["unitType"] == "Trebuchet"))
    end

    test "an outpost gets a Guard Tower, without needing to be rich" do
      outpost = building(20, "ResourceDepot", 30, 30)
      {_, commands, _} = plan(units: workers(20) ++ soldiers(30), buildings: [outpost | built()], ore: 300)
      assert [%{"buildingType" => "GuardTower", "x" => x, "y" => y}] = builds(commands)
      assert View.dist({x, y}, {30, 30}) in 2..4

      # Once it has one, no more until we are rich; then a second.
      tower = building(21, "GuardTower", 32, 32)
      {_, commands, _} = plan(units: workers(20) ++ soldiers(30), buildings: [outpost, tower | built()], ore: 300)
      assert builds(commands) == []

      {_, commands, _} = plan(units: workers(20) ++ soldiers(30), buildings: [outpost, tower | built()], ore: 1000)
      assert [%{"buildingType" => "GuardTower", "x" => x, "y" => y}] = builds(commands)
      assert View.dist({x, y}, {30, 30}) in 2..4

      tower2 = building(22, "GuardTower", x, y)
      {_, commands, _} = plan(units: workers(20) ++ soldiers(30), buildings: [outpost, tower, tower2 | built()], ore: 1000)
      refute Enum.any?(builds(commands), &(&1["buildingType"] == "GuardTower" and View.dist({&1["x"], &1["y"]}, {30, 30}) <= 6))
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
