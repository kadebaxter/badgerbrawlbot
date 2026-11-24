defmodule Swarm.TurnaroundTest do
  @moduledoc """
  Fixes from the first game against the Formics: a Command Center away from an opponent's start
  isn't their last while the start may still have one; the serum is only taken when it turns the
  fight, and then the Soldiers go in; and more Barracks go up while the ore piles up.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  defp plan(opts, memory \\ Brain.new_memory()),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  describe "the last opponent's Command Center" do
    # The enemy started at (56, 56).
    test "one in the middle of the map isn't it: their start may still have one" do
      middle = building(900, "CommandCenter", 33, 33, 1)
      {strategy, _, memory} = plan(units: soldiers(5), buildings: [middle])
      assert strategy.spare == nil and memory.kill == nil
    end

    test "it is, once we have seen their start with none on it" do
      middle = building(900, "CommandCenter", 33, 33, 1)
      # A scout stands by their start and sees no Command Center there.
      {_, _, memory} = plan(units: [unit(300, "Scout", 54, 54)], buildings: [middle])
      assert memory.empty_starts == [{56, 56}]

      {strategy, _, _} = plan([units: soldiers(5), buildings: [middle]], memory)
      assert %{id: 900} = strategy.spare
    end

    test "the one they started with is, as before" do
      {strategy, _, _} = plan(units: soldiers(5), buildings: [building(900, "CommandCenter", 56, 56, 1)])
      assert %{id: 900} = strategy.spare
    end
  end

  describe "the serum" do
    defp raiders(n), do: for(i <- 1..n, do: unit(900 + i, "Soldier", 9, 9, owner: 1))

    test "taken when doubling our Soldiers turns the fight; not against a raid it can't beat" do
      # Ten Soldiers at home: with the serum they are worth twenty.
      assert {%{serum: :take, serum_on: true}, _, _} = plan(units: soldiers(10) ++ raiders(16))
      assert {%{serum: nil, serum_on: false}, _, _} = plan(units: soldiers(10) ++ raiders(30))
    end

    test "a Soldier on the serum counts for two, theirs or ours, in strength and in the fight's estimate" do
      plain = unit(901, "Soldier", 14, 14, owner: 1)
      juiced = Map.put(plain, "effects", ["serum"])
      assert Swarm.Roles.serum?(juiced) and not Swarm.Roles.serum?(plain)
      assert Swarm.Roles.strength([juiced]) == 2 * Swarm.Roles.strength([plain])
      # An Archer isn't boosted, whatever it is marked.
      refute Swarm.Roles.serum?(Map.put(unit(902, "Archer", 14, 14, owner: 1), "effects", ["serum"]))

      # Eight of ours against six of theirs is ours to win; against six on the serum it isn't.
      ours = for i <- 1..8, do: unit(200 + i, "Soldier", 12, 12)
      raid = fn effects -> for i <- 1..6, do: Map.put(unit(900 + i, "Soldier", 14, 12, owner: 1), "effects", effects) end
      estimate = fn theirs -> View.new(state(units: ours ++ theirs)) |> Swarm.Roles.groups(nil) |> Map.fetch!(:groups) |> Map.values() |> hd() |> Map.fetch!(:all) end
      assert estimate.(raid.(nil)) > 0
      assert estimate.(raid.(["serum"])) < 0
    end

    test "theirs on the serum in our base: we take ours, whatever the odds" do
      juiced = for i <- 1..30, do: Map.put(unit(900 + i, "Soldier", 9, 9, owner: 1), "effects", ["serum"])
      plain = for i <- 1..30, do: unit(900 + i, "Soldier", 9, 9, owner: 1)

      # Thirty against our ten is nothing ours could turn: not taken. The same thirty on theirs: answered.
      assert {%{serum: nil}, _, _} = plan(units: soldiers(10) ++ plain)
      assert {%{serum: :take, serum_on: true}, _, _} = plan(units: soldiers(10) ++ juiced)
      # Still only with eight Soldiers of our own or more.
      assert {%{serum: nil}, _, _} = plan(units: soldiers(7) ++ juiced)
    end

    test "while it lasts our Soldiers hit twice as hard in the estimate: one call, Archers go in with them" do
      # Eight raiders in the base by five Soldiers and three Archers of ours: not a fight to take, plain.
      raid = for i <- 1..8, do: unit(900 + i, "Soldier", 14, 12, owner: 1)
      archers = for i <- 1..3, do: unit(260 + i, "Archer", 11, 12)
      ours = for i <- 1..5, do: unit(200 + i, "Soldier", 12, 12)
      strategy = %{mode: :defend, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
      v = View.new(state(units: ours ++ archers ++ raid))
      attacks? = fn id, v, s -> match?({%{"type" => "Attack"}, _}, UnitBrain.decide(id, v, s)) end

      # (The Archers shoot what is in their reach either way; the Soldiers would have to walk in.)
      refute attacks?.(201, v, strategy)
      assert v |> Swarm.Roles.groups(nil) |> Map.fetch!(:groups) |> Map.values() |> hd() |> Swarm.Roles.call() == :away

      # The serum on (the view says so from the tick after it is taken): the same fight is ours,
      # and the Archers are in it with the Soldiers.
      on = %{v | serum_on: true}
      assert on |> Swarm.Roles.groups(nil) |> Map.fetch!(:groups) |> Map.values() |> hd() |> Swarm.Roles.call() == :go
      assert attacks?.(201, on, Map.put(strategy, :serum_on, true))
      assert attacks?.(261, on, Map.put(strategy, :serum_on, true))
    end

    test "the view has our serum on from the tick after it is taken until it wears off" do
      v = View.new(state(units: soldiers(10), tick: 101))
      assert {%{serum_on: true}, _} = Brain.see(v, %{Brain.new_memory() | serum: {:until, 130}})
      assert {%{serum_on: false}, _} = Brain.see(v, %{Brain.new_memory() | serum: {:until, 100}})
      assert {%{serum_on: false}, _} = Brain.see(v, Brain.new_memory())
    end

    test "the tick it is taken, a fight we were going into stays on, for Soldiers and Archers alike" do
      # Twelve raiders: more than five Soldiers and three Archers take on, plain.
      raid = for i <- 1..12, do: unit(900 + i, "Soldier", 14, 12, owner: 1)
      archers = for i <- 1..3, do: unit(260 + i, "Archer", 8, 12)
      ours = for i <- 1..5, do: unit(200 + i, "Soldier", 12, 12)
      strategy = %{mode: :defend, target: {56, 56}, rally: {10, 10}, post: {9, 9}, threat: nil, wave: nil}
      was_in = %{View.new(state(units: ours ++ archers ++ raid)) | going_in: MapSet.new([901])}
      attacks? = fn id, v, s -> match?({%{"type" => "Attack"}, _}, UnitBrain.decide(id, v, s)) end

      # Clearly against us, the sticky call lets go of it...
      refute attacks?.(201, was_in, strategy)
      refute attacks?.(261, was_in, strategy)
      # ...but not on the tick the serum is taken: it isn't in the estimate until the next one.
      take = Map.put(strategy, :serum, :take)
      assert attacks?.(201, was_in, take)
      assert attacks?.(261, was_in, take)
      # A fight we weren't in isn't started by it.
      refute attacks?.(261, %{was_in | going_in: MapSet.new()}, take)
    end
  end

  describe "more Barracks" do
    @built [
      building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 12, 12),
      building(6, "TechLab", 7, 12), building(7, "Barracks", 12, 3), building(8, "GuardTower", 14, 9),
      building(9, "CommandCenter", 40, 4), building(20, "Barracks", 3, 3), building(21, "Barracks", 3, 11),
      building(22, "GuardTower", 10, 13), building(23, "GuardTower", 13, 6), building(24, "GuardTower", 4, 13),
      building(25, "GuardTower", 13, 13), building(26, "GuardTower", 1, 13), building(27, "GuardTower", 13, 1)
    ]
    defp busy(buildings), do: for(b <- buildings, do: if(b["type"] == "Barracks", do: %{b | "production" => [%{"unitType" => "Soldier"}, %{"unitType" => "Soldier"}]}, else: b))
    defp builds(commands), do: for(%{"type" => "Build", "buildingType" => t} <- commands, do: t)

    test "a fifth when all four are busy and we can pay for it, rich or not" do
      {_, commands, _} = plan(units: workers(20) ++ soldiers(12), buildings: busy(@built), ore: 1500)
      assert builds(commands) == ["Barracks"]

      {_, commands, _} = plan(units: workers(20) ++ soldiers(12), buildings: busy(@built), ore: 300)
      assert builds(commands) == ["Barracks"]
    end

    test "on its own order: it goes up while another building is on its way, and only one at a time" do
      # A tower was ordered ten ticks ago and its builder is still walking.
      walking = %{type: "GuardTower", builder: 101, at: 90, had: 8, site: {20, 20}}
      memory = %{Brain.new_memory() | pending: walking}
      {_, commands, memory} = plan([units: workers(20) ++ soldiers(12), buildings: busy(@built), ore: 1500], memory)
      assert builds(commands) == ["Barracks"]
      assert %{type: "Barracks", site: site} = memory.barracks_order
      assert memory.pending == walking

      # Its own builder walking: no second one ordered, and its builder isn't given another job.
      {_, commands, memory2} = plan([units: workers(20) ++ soldiers(12), buildings: busy(@built), ore: 1500, tick: 105], memory)
      assert builds(commands) == []
      assert memory2.barracks_order == memory.barracks_order

      # It has broken ground: the slot is free again.
      up = %{building(40, "Barracks", elem(site, 0), elem(site, 1)) | "completed" => false}
      builder = unit(memory.barracks_order.builder, "Worker", elem(site, 0) + 1, elem(site, 1), activity: "Building", target_id: 40)
      others = Enum.reject(workers(20), &(&1["id"] == builder["id"]))
      {_, _, memory3} = plan([units: [builder | others] ++ soldiers(12), buildings: [up | busy(@built)], ore: 100, tick: 110], memory)
      assert memory3.barracks_order == nil
    end

    test "before the build order is done too" do
      early = busy([building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9)])
      {_, commands, _} = plan(units: workers(10) ++ soldiers(8), buildings: early, ore: 300, tick: 60)
      assert builds(commands) == ["Barracks"]
    end

    test "not while one has room in its queue, and never saved up for" do
      {_, commands, _} = plan(units: workers(20) ++ soldiers(12), buildings: @built, ore: 1500)
      assert builds(commands) == []

      # 200 ore: not enough for one and the workers' reserve. The Barracks train with it.
      {_, commands, _} = plan(units: workers(20) ++ soldiers(12), buildings: busy(@built), ore: 200)
      assert builds(commands) == []
    end
  end
end

defmodule Swarm.RecentCountTest do
  @moduledoc """
  The most we have known of an opponent's army lately counts, whatever is in sight now: for
  launching a wave, for going out to help, and for keeping the army together (no escorts) while
  theirs is the bigger one. And a second TechLab, so the upgrades get done.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, Roles, View}

  defp plan(opts, memory),
    do: Brain.plan(View.new(state(opts)), looked(memory, 1, Keyword.get(opts, :tick, 100)), terrain())

  defp army(n), do: for(i <- 1..n, do: unit(900 + i, "Soldier", 40, 40, owner: 1))

  describe "their army as last counted" do
    test "a wave doesn't leave against an army seen a while ago and out of sight now" do
      # 22 soldiers: 15 attackers (14850). Twenty of theirs seen at tick 100.
      {_, _, memory} = plan([units: soldiers(22) ++ army(20), tick: 100], Brain.new_memory())
      assert {20 * 990.0, 100} == memory.army_seen[1]

      # A scout stands where they were and sees nobody: forgotten as units, not as a count.
      scout = unit(300, "Scout", 40, 40)
      {strategy, _, memory} = plan([units: [scout | soldiers(22)], tick: 140], memory)
      assert memory.enemies == %{}
      assert strategy.wave == nil
      assert Brain.enemy_strength(View.new(state(units: soldiers(22))), memory, 1) == 20 * 990.0

      # 150 ticks after the count, it no longer holds.
      {_, _, memory} = plan([units: [scout | soldiers(22)], tick: 251], memory)
      assert Brain.enemy_strength(View.new(state(units: soldiers(22))), memory, 1) == 0
    end

    test "what we kill of it comes off the count" do
      {_, _, memory} = plan([units: soldiers(22) ++ army(20), tick: 100], Brain.new_memory())
      killed = for i <- 1..15, do: %{"tick" => 101, "kind" => "UnitKilled", "entityId" => 900 + i}
      v = View.new(Map.put(state(units: soldiers(22) ++ Enum.drop(army(20), 15), tick: 101), "events", killed))
      {_, _, memory} = Brain.plan(v, memory, terrain())
      assert elem(memory.army_seen[1], 0) == 5 * 990.0
    end

    test "home doesn't go out to two raiders with forty counted behind them" do
      miners = for i <- 1..4, do: unit(100 + i, "Worker", 25, 7, activity: "Gathering")
      pair = for i <- 1..2, do: unit(900 + i, "Soldier", 27, 7, owner: 1)
      {%{help: {27, 7}}, _, _} = plan([units: miners ++ pair ++ soldiers(10)], Brain.new_memory())

      memory = %{Brain.new_memory() | army_seen: %{1 => {40 * 990.0, 80}}}
      assert {%{help: nil}, _, _} = plan([units: miners ++ pair ++ soldiers(10)], memory)
    end
  end

  describe "keeping together" do
    # An outpost at (30, 30) with miners, and three of our fighters by it.
    @outpost building(20, "ResourceDepot", 30, 30)
    defp miners, do: for(i <- 1..4, do: unit(100 + i, "Worker", 31, 31, activity: "Gathering"))
    defp ours, do: for(i <- 1..3, do: unit(250 + i, "Soldier", 31, 30)) ++ soldiers(12)

    test "with their army the bigger one, nobody escorts an outpost; with ours bigger again, they do" do
      v = View.new(state(units: miners() ++ ours(), buildings: [@outpost]))
      assert {:escort, {30, 30}} == Roles.role(v, nil, 251)
      refute match?({:escort, _}, Roles.role(%{v | together: true}, nil, 251))

      # Twenty of theirs known against our fifteen: together, and the view the units get says so.
      memory = %{Brain.new_memory() | army_seen: %{1 => {20 * 990.0, 90}}}
      {_, _, memory} = plan([units: miners() ++ ours(), buildings: [@outpost]], memory)
      assert memory.together
      assert {%View{together: true}, _} = Brain.see(View.new(state(units: ours())), memory)

      # Down to thirteen (under 0.8 of ours, not just under it): back to normal.
      {_, _, memory} = plan([units: miners() ++ ours(), buildings: [@outpost]], %{memory | army_seen: %{1 => {13 * 990.0, 90}}})
      assert memory.together
      {_, _, memory} = plan([units: miners() ++ ours(), buildings: [@outpost]], %{memory | army_seen: %{1 => {11 * 990.0, 90}}})
      refute memory.together
    end
  end

  describe "upgrades" do
    test "a second TechLab at 25 workers, once the first is up, so two are researched at a time" do
      built = [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(6, "TechLab", 7, 12)]
      builds = fn commands -> for %{"type" => "Build", "buildingType" => t} <- commands, do: t end

      {_, commands, _} = plan([units: workers(24) ++ soldiers(8), buildings: built, ore: 400], Brain.new_memory())
      refute "TechLab" in builds.(commands)
      {_, commands, _} = plan([units: workers(25) ++ soldiers(8), buildings: built, ore: 400], Brain.new_memory())
      assert builds.(commands) == ["TechLab"]

      labs = [building(9, "TechLab", 3, 12) | built]
      state = put_in(state(units: workers(25) ++ soldiers(8), buildings: labs, ore: 1000), ["you", "upgrades"], ["Harvesting1"])
      state = put_in(state, ["you", "researching"], [%{"upgrade" => "Weapons1"}])
      lab_busy = for b <- state["buildings"], do: if(b["id"] == 6, do: Map.put(b, "research", "Weapons1"), else: b)
      {_, commands, _} = Brain.plan(View.new(%{state | "buildings" => lab_busy}), looked(nil), terrain())
      assert [%{"buildingId" => 9, "upgrade" => "Armor1"}] = for(%{"type" => "Research"} = c <- commands, do: c)
    end
  end
end
