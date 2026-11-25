defmodule Swarm.MiddleTest do
  @moduledoc """
  Taking the middle: the first base goes there, the army lives at it, and Trebuchets go after
  their workers, who stand many to a tile by their drop-offs.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  # Us at (7, 7), the enemy at (56, 56), a 64x64 map: its middle is within 16 of (32, 32).
  @barracks building(2, "Barracks", 11, 7)
  @depot building(3, "ResourceDepot", 4, 9)
  @home_ore %{"id" => 4, "x" => 2, "y" => 7, "remaining" => 900}
  defp field(id, x, y), do: for(i <- 0..2, do: %{"id" => id + i, "x" => x + i, "y" => y, "remaining" => 1000})
  defp plan(opts, memory \\ Brain.new_memory()), do: Brain.plan(View.new(state(opts)), looked(memory, 1, opts[:tick] || 100), terrain())
  defp ccs(commands), do: for(%{"type" => "Build", "buildingType" => "CommandCenter"} = c <- commands, do: c)

  describe "the first base" do
    # A field in the middle at (26, 26) and a safer one nearer home at (6, 22); both seen.
    @seeing [unit(300, "Scout", 24, 24), unit(301, "Scout", 8, 20)]

    test "goes to the middle, not the safest field" do
      opts = [units: @seeing ++ workers(16) ++ soldiers(12), buildings: [@barracks, @depot], deposits: [@home_ore | field(30, 26, 26) ++ field(40, 6, 22)], ore: 1200]
      {_, commands, _} = plan(opts)
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {27, 26}) <= 4
    end

    test "with one of ours in the middle already, the next goes to the safest again" do
      middle = building(60, "CommandCenter", 28, 28)
      more = field(50, 34, 26)
      opts = [units: @seeing ++ [unit(302, "Scout", 34, 24)] ++ workers(30) ++ soldiers(12), buildings: [@barracks, @depot, middle],
              deposits: [@home_ore | more ++ field(40, 6, 22)], ore: 1200]
      {_, commands, _} = plan(opts, %{Brain.new_memory() | bases: [{28, 28}]})
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {7, 22}) <= 4
    end
  end

  describe "with three or four players, the nearest field first" do
    # The same game with a third player, at (7, 56).
    defp three(opts, memory \\ Brain.new_memory()) do
      s = state(opts)
      third = %{"slot" => 2, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 56}}
      Brain.plan(View.new(%{s | "players" => s["players"] ++ [third]}), looked(memory, 1, opts[:tick] || 100), terrain())
    end

    defp towers(commands), do: for(%{"type" => "Build", "buildingType" => "GuardTower", "x" => x, "y" => y} <- commands, do: {x, y})

    defp opts, do: [units: @seeing ++ workers(16) ++ soldiers(12), buildings: [@barracks, @depot], deposits: [@home_ore | field(30, 26, 26) ++ field(40, 6, 22)]]

    test "the nearest field comes first: the middle is a field like any other" do
      # The field at (6, 22) is 15 tiles from home, the one in the middle 19.
      {_, commands, _} = three(opts() ++ [ore: 1200])
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {7, 22}) <= 4
      # With one opponent the middle comes first, as ever.
      {_, commands, _} = plan(opts() ++ [ore: 1200])
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {27, 26}) <= 4
    end

    test "short of its price the Barracks go on training: nothing is held for the middle" do
      {_, commands, _} = three(opts() ++ [ore: 350])
      assert Enum.any?(commands, &match?(%{"type" => "Produce", "unitType" => "Soldier"}, &1))
    end

    defp depots(commands), do: for(%{"type" => "Build", "buildingType" => "ResourceDepot", "x" => x, "y" => y} <- commands, do: {x, y})
    # Four of ours mining the pile at `{x, y}` (deposit `id`), a long walk from any drop-off.
    defp far_miners(id, x, y), do: for(i <- 1..4, do: unit(150 + i, "Worker", x + 1, y + 1, activity: "Gathering", target_id: id))

    test "a depot in the middle only by a Command Center of ours, while there is ore by our drop-offs" do
      units = far_miners(30, 26, 26) ++ workers(12) ++ soldiers(12)
      ore = [@home_ore | field(30, 26, 26)]
      # Home ore left, no Command Center of ours by the field: no depot there.
      {_, commands, _} = three(units: units, buildings: [@barracks, @depot], deposits: ore, ore: 300)
      assert depots(commands) == []
      # A finished Command Center of ours six tiles from it: one goes up.
      base = building(60, "CommandCenter", 32, 26)
      {_, commands, _} = three([units: units, buildings: [@barracks, @depot, base], deposits: ore, ore: 300], %{Brain.new_memory() | bases: [{32, 26}]})
      assert [spot] = depots(commands)
      assert View.dist(spot, {27, 26}) <= 3
      # No Command Center by it, but it is the field our army is taking for the workers: one goes up.
      {_, commands, _} = three([units: units, buildings: [@barracks, @depot], deposits: ore, ore: 300], %{Brain.new_memory() | claim: %{pos: {27, 26}, at: 90}})
      assert [spot] = depots(commands)
      assert View.dist(spot, {27, 26}) <= 3
      # With one opponent it goes up either way.
      {_, commands, _} = plan(units: units, buildings: [@barracks, @depot], deposits: ore, ore: 300)
      assert [_] = depots(commands)
    end

    test "with no ore left by any drop-off of ours, a depot goes to the middle all the same: that ore is all there is" do
      # The same, the home ore gone: the miners at the field in the middle are all the income we have.
      units = far_miners(30, 26, 26) ++ soldiers(12)
      {_, commands, _} = three(units: units, buildings: [@barracks, @depot], deposits: field(30, 26, 26), ore: 300)
      assert [spot] = depots(commands)
      assert View.dist(spot, {27, 26}) <= 3
    end

    test "a depot by ore our workers walk for comes ahead of the fighters, the research and the rest" do
      # A field along the edge at (30, 8), out of the middle; two Soldiers (under the army floor),
      # a free Tech Lab with research to do, and 120 ore: the depot gets it, with three builders or more.
      lab = building(6, "TechLab", 7, 12)
      units = far_miners(30, 30, 8) ++ workers(12) ++ soldiers(2)
      {_, commands, _} = three(units: units, buildings: [@barracks, @depot, lab], deposits: [@home_ore | field(30, 30, 8)], ore: 120)
      assert [%{"buildingType" => "ResourceDepot", "unitIds" => builders}] = for(%{"type" => type} = c <- commands, type in ["Build", "Research", "Produce"], do: c)
      assert length(builders) >= 3
    end

    test "with buildings of theirs on every tile right by the ore, ours goes up a step farther, next to them" do
      units = far_miners(30, 30, 8) ++ workers(12) ++ soldiers(12)
      opts = fn more -> [units: units, buildings: [@barracks, @depot] ++ more, deposits: [@home_ore | field(30, 30, 8)], ore: 300] end
      {_, commands, _} = plan(opts.([]))
      assert [near] = depots(commands)
      assert View.dist(near, {30, 8}) == 2

      # Theirs around the pile our miners are at: no open tile two from it is left.
      theirs = for {{x, y}, i} <- Enum.with_index([{29, 6}, {32, 6}, {29, 10}, {32, 10}, {27, 8}]), do: building(800 + i, "ResourceDepot", x, y, 1)
      {_, commands, _} = plan(opts.(theirs))
      assert [spot] = depots(commands)
      assert View.dist(spot, {30, 8}) == 3
      assert Enum.all?(theirs, &(View.dist(View.pos(&1), spot) >= 2))
    end

    test "no base farther from home than the middle while every opponent is in" do
      # Only a field along the edge at (40, 10), seen: 33 tiles from home, the middle is 25.
      far = [units: [unit(300, "Scout", 40, 8) | workers(16) ++ soldiers(12)], buildings: [@barracks, @depot], deposits: [@home_ore | field(30, 40, 10)], ore: 1200]
      {_, commands, _} = three(far)
      assert ccs(commands) == []
      # With one opponent it goes there.
      {_, commands, _} = plan(far)
      assert [_] = ccs(commands)
    end

    test "it goes by the field in the middle nearest us, and waits for a scout to have seen that one" do
      # Two fields in the middle: (20, 24), 17 tiles from home, and (44, 40) across the map.
      ore = [@home_ore | field(30, 20, 24) ++ field(40, 44, 40)]
      army = workers(16) ++ soldiers(12)
      # A scout has only seen the far one: no base yet.
      {_, commands, _} = three(units: [unit(300, "Scout", 44, 38) | army], buildings: [@barracks, @depot], deposits: ore, ore: 1200)
      assert ccs(commands) == []
      # The near one seen: it goes there.
      {_, commands, _} = three(units: [unit(300, "Scout", 44, 38), unit(301, "Scout", 20, 22) | army], buildings: [@barracks, @depot], deposits: ore, ore: 1200)
      assert [%{"x" => x, "y" => y}] = ccs(commands)
      assert View.dist({x, y}, {21, 24}) <= 4
    end

    test "its towers start while it is going up, before the Barracks get the ore" do
      going_up = %{building(60, "CommandCenter", 28, 28) | "completed" => false}
      opts = Keyword.merge(opts(), buildings: [@barracks, @depot, going_up], ore: 600)
      memory = %{Brain.new_memory() | bases: [{28, 28}]}
      {_, commands, _} = three(opts, memory)
      assert [spot] = towers(commands)
      assert View.dist(spot, {28, 28}) <= 6
      # With one opponent they wait for it to be up.
      {_, commands, _} = plan(opts, memory)
      assert towers(commands) == []
    end
  end

  describe "with a base of ours in the middle" do
    @middle building(60, "CommandCenter", 28, 28)
    defp held, do: %{Brain.new_memory() | bases: [{28, 28}]}

    test "the army lives there: the rally point is three tiles from it, toward the enemy" do
      {strategy, _, _} = plan([units: soldiers(5), buildings: [@barracks, @depot, @middle]], held())
      assert strategy.rally == {31, 31}

      # Without the mark it is a hidden backup, and the army waits at home as before.
      {strategy, _, _} = plan(units: soldiers(5), buildings: [@barracks, @depot, @middle])
      assert strategy.rally == {10, 10}
    end

    test "called home: a raid on the main base that home's few can't meet and all of ours with its towers can" do
      home_tower = building(5, "GuardTower", 11, 11)
      buildings = [@barracks, @depot, @middle, home_tower]
      # Eight guards at home, thirty of ours out at the middle base.
      guards = for i <- 1..8, do: unit(400 + i, "Soldier", 9, 9)
      army = for i <- 1..30, do: unit(200 + i, "Soldier", 30, 30)
      raid = fn n, x, y -> for i <- 1..n, do: unit(900 + i, "Soldier", x, y, owner: 1) end

      # Thirty coming at home, ten tiles off it: the army's rally point is home's again.
      {strategy, _, memory} = plan([units: guards ++ army ++ raid.(30, 17, 16), buildings: buildings], held())
      assert strategy.rally == {10, 10} and memory.home_call == 100
      assert Enum.any?(strategy.why, &match?({:home_call, _}, &1))

      # Five of them: the guards and the tower see to that. Sixty: not a fight for all of ours either.
      {strategy, _, _} = plan([units: guards ++ army ++ raid.(5, 17, 16), buildings: buildings], held())
      assert strategy.rally == {31, 31}
      {strategy, _, _} = plan([units: guards ++ army ++ raid.(60, 17, 16), buildings: buildings], held())
      assert strategy.rally == {31, 31}
      # Thirty by the middle base, nearer to it than to home: that is the army's fight where it is.
      {strategy, _, _} = plan([units: guards ++ army ++ raid.(30, 24, 24), buildings: buildings], held())
      assert strategy.rally == {31, 31}

      # Called, it stays while they are there, though the army at home now meets them...
      at_home = for i <- 1..30, do: unit(200 + i, "Soldier", 10, 10)
      {strategy, _, memory} = plan([units: guards ++ at_home ++ raid.(30, 14, 14), buildings: buildings, tick: 130], memory)
      assert strategy.rally == {10, 10} and memory.home_call == 130
      # ...and twenty ticks after the last of them; then back to the middle.
      {strategy, _, memory} = plan([units: guards ++ at_home, buildings: buildings, tick: 145], memory)
      assert strategy.rally == {10, 10}
      {strategy, _, memory} = plan([units: guards ++ at_home, buildings: buildings, tick: 151], memory)
      assert strategy.rally == {31, 31} and memory.home_call == nil
    end

    test "the home guard is the same fixed number, however big the army in the middle is (seven in these tests, nine in a game)" do
      roles = fn n ->
        v = %{View.new(state(units: soldiers(n), buildings: [@barracks, @depot, @middle])) | bases: [{28, 28}]}
        Enum.frequencies(Map.values(Swarm.Roles.home_roles(v, nil)))
      end

      assert roles.(40) == %{guard: 7, attacker: 33}
      assert roles.(60) == %{guard: 7, attacker: 53}
      assert roles.(20) == %{guard: 7, attacker: 13}

      # Without a base in the middle: seven guards, as ever.
      v = View.new(state(units: soldiers(40), buildings: [@barracks, @depot]))
      assert Enum.frequencies(Map.values(Swarm.Roles.home_roles(v, nil))) == %{guard: 7, attacker: 33}
    end

    test "the guards stand at home, behind the home tower nearest the enemy, not out at the middle base" do
      home_tower = building(5, "GuardTower", 11, 11)
      forward_tower = building(70, "GuardTower", 30, 30)
      {strategy, _, _} = plan([units: soldiers(20), buildings: [@barracks, @depot, @middle, home_tower, forward_tower]], held())
      assert strategy.post == {10, 10}
      assert strategy.rally == {31, 31}

      # No tower at home yet: by the Command Center, on the enemy's side.
      {strategy, _, _} = plan([units: soldiers(20), buildings: [@barracks, @depot, @middle, forward_tower]], held())
      assert strategy.post == {10, 10}
    end

    test "it gets four towers, where another base gets two" do
      towers = for {id, x, y} <- [{70, 30, 30}, {71, 26, 30}], do: building(id, "GuardTower", x, y)
      home = [building(5, "GuardTower", 11, 11), building(6, "TechLab", 7, 12), building(7, "Barracks", 12, 3), building(8, "Barracks", 1, 10)]
      opts = [units: workers(12) ++ soldiers(8), buildings: labs_busy([@barracks, @depot, @middle] ++ home ++ towers), ore: 300]
      {_, commands, _} = plan(opts, held())
      assert [%{"x" => x, "y" => y}] = for(%{"type" => "Build", "buildingType" => "GuardTower"} = c <- commands, do: c)
      assert View.dist({x, y}, {28, 28}) <= 4
    end
  end

  describe "a Trebuchet out with a wave" do
    @hunt %{mode: :attack, target: {50, 50}, rally: {10, 10}, post: {9, 9}, threat: nil,
            wave: %{id: 1, members: [201, 301], released: true, staging: nil, at: 100, party: true}}
    defp decide(units), do: elem(UnitBrain.decide(301, View.new(state(units: [unit(301, "Trebuchet", 40, 40) | units])), @hunt), 0)
    defp miners(ids, x, y, activity \\ "Gathering"), do: for(id <- ids, do: unit(id, "Worker", x, y, owner: 1, activity: activity))

    test "shells the biggest stack of their workers in its reach, by name" do
      # Five on one tile six tiles off, three on another; a lone Soldier nearer than either.
      units = miners(901..905, 46, 40) ++ miners(911..913, 44, 44) ++ [unit(950, "Soldier", 44, 40, owner: 1)]
      assert %{"type" => "Attack", "targetId" => 901} = decide(units)
    end

    test "not workers on the move (the shell would miss), nor a couple, nor ones out of its reach" do
      refute match?(%{"targetId" => id} when id in 901..905, decide(miners(901..905, 46, 40, "Moving")))
      refute match?(%{"targetId" => id} when id in 901..902, decide(miners(901..902, 46, 40)))
      refute match?(%{"targetId" => id} when id in 901..905, decide(miners(901..905, 49, 40)))
      refute match?(%{"targetId" => id} when id in 901..905, decide(miners(901..905, 42, 40)))
    end
  end

  describe "a hunting party" do
    # Their army (twenty, counted lately) stands by their base in the middle; their corner base at
    # (59, 4) has nobody of theirs we know of near it.
    @their_middle building(720, "CommandCenter", 33, 33, 1)
    @their_corner building(721, "CommandCenter", 59, 4, 1)
    defp army_in_the_middle do
      seen = for i <- 1..20, into: %{}, do: {900 + i, %{"id" => 900 + i, "owner" => 1, "type" => "Soldier", "hp" => 110, "x" => 34, "y" => 34, "seen" => 95}}
      %{Brain.new_memory() | enemies: seen, army_seen: %{1 => {20 * 990.0, 95}}}
    end

    test "Trebuchets and an escort of four or more go for the base their army isn't at" do
      trebs = for i <- 1..2, do: unit(300 + i, "Trebuchet", 10, 10)
      {strategy, _, _} = plan([units: trebs ++ soldiers(12), buildings: [@their_middle, @their_corner]], army_in_the_middle())
      assert %{wave: %{party: true, goal: {59, 4}, members: members}, target: {59, 4}} = strategy
      assert 301 in members and 302 in members and length(members) == 7
      assert Enum.any?(strategy.why, fn {kind, text} -> kind == :wave_launched and text =~ "siege party at their base by (59,4)" end)
    end

    test "not when we don't know where their army is: twenty counted, none of them remembered anywhere" do
      trebs = for i <- 1..2, do: unit(300 + i, "Trebuchet", 10, 10)
      nowhere = %{army_in_the_middle() | enemies: %{}}
      assert {%{wave: nil}, _, _} = plan([units: trebs ++ soldiers(12), buildings: [@their_middle, @their_corner]], nowhere)
    end

    test "not with their army by every base of theirs, nor with too small an escort" do
      trebs = for i <- 1..2, do: unit(300 + i, "Trebuchet", 10, 10)
      assert {%{wave: nil}, _, _} = plan([units: trebs ++ soldiers(12), buildings: [@their_middle]], army_in_the_middle())
      # Ten soldiers: seven guards, three attackers at the rally point.
      assert {%{wave: nil}, _, _} = plan([units: trebs ++ soldiers(10), buildings: [@their_middle, @their_corner]], army_in_the_middle())
    end
  end
end
