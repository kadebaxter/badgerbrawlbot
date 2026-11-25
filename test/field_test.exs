defmodule Swarm.FieldTest do
  @moduledoc """
  From the game won on a field we took 350 ticks late: home was mined out, 43 workers walked to
  the field in the middle, an Archer or two came into reach and they all walked home, again and
  again, banking nothing. Driven off the ore, a guard takes the field at once (the rest of the
  army stays at the towers), the workers mine behind it, and a few Archers send nobody home.
  """
  use ExUnit.Case, async: true
  import Swarm.Test.GameState
  alias Swarm.{Brain, UnitBrain, View}

  @built [building(2, "Barracks", 11, 7), building(3, "ResourceDepot", 4, 9), building(5, "GuardTower", 11, 11)]
  @field for {id, x, y} <- [{31, 34, 34}, {32, 35, 34}, {33, 34, 35}, {34, 35, 35}], into: %{}, do: {id, %{"id" => id, "x" => x, "y" => y, "remaining" => 800, "seen" => 300}}

  defp in_sight, do: for({_id, d} <- @field, do: Map.delete(d, "seen"))
  defp scout, do: unit(300, "Scout", 10, 12)
  defp home(ids \\ 1..40), do: for(i <- ids, do: unit(200 + i, "Soldier", 10, 10))
  defp at_field(ids), do: for(i <- ids, do: unit(200 + i, "Soldier", 33, 33))
  defp archers(ids, x, y), do: for(i <- ids, do: unit(900 + i, "Archer", x, y, owner: 1))
  defp soldiers_of_theirs(ids, x, y), do: for(i <- ids, do: unit(900 + i, "Soldier", x, y, owner: 1))

  # Ten workers on their way out to the field, or back from it: "Moving", all they ever were.
  defp walking(x \\ 20, y \\ 20), do: for(i <- 1..10, do: unit(100 + i, "Worker", x, y, activity: "Moving", target_id: 31))
  defp on_field, do: for(i <- 1..10, do: unit(100 + i, "Worker", 33, 34))

  # We banked our last ore at tick 350.
  defp start, do: %{Brain.new_memory() | map_ore: 72_000, income_at: {9_000, 350}, ore: @field}

  defp tick(tick, units, memory, opts \\ []) do
    state =
      state(units: units, buildings: @built ++ Keyword.get(opts, :buildings, []), deposits: Keyword.get(opts, :deposits, []), ore: Keyword.get(opts, :ore, 60), tick: tick)
      |> Map.update!("players", fn [me, them] ->
        [Map.put(me, "score", %{"economy" => 9_000, "total" => 9_000}), Map.put(them, "score", %{"economy" => 20_000, "total" => 20_000, "survival" => Keyword.get(opts, :alive, 1500)})]
      end)

    {v, memory} = Brain.see(View.new(state), memory)
    {strategy, commands, memory} = Brain.plan(v, looked(memory, 1, tick), terrain())
    prepared = UnitBrain.prepare(v, strategy.wave)
    orders = for u <- v.my_units, {cmd, _} = UnitBrain.decide(u["id"], prepared, strategy), is_map(cmd), into: %{}, do: {u["id"], cmd}
    %{v: v, strategy: strategy, commands: commands, memory: memory, orders: orders, log: for({:claim, text} <- strategy.why, do: text)}
  end

  defp to_field?(order), do: match?(%{"x" => x, "y" => y} when x in 24..40 and y in 24..40, order)
  defp mines?(order), do: match?(%{"type" => "Gather", "targetId" => id} when id in 31..34, order)

  describe "driven off the ore" do
    test "walking to it with nothing banked for forty ticks, Archers by them or not: the field is taken" do
      # Two Archers three tiles from the workers, as they turn back: a raid on them, every time.
      t = tick(400, [scout() | walking(30, 30) ++ home()] ++ archers(1..2, 33, 31), start())
      assert t.strategy.claim == {34, 34}
      assert [said] = t.log
      assert said =~ "driven off the ore for 50 ticks" and said =~ "a guard of 10 takes the field at (34,34)" and said =~ "the rest stay home"

      # And with nobody near them at all.
      t = tick(400, [scout() | walking() ++ home()], start())
      assert t.strategy.claim == {34, 34}
    end

    test "not while any of them is mining or carrying ore" do
      mining = [unit(101, "Worker", 33, 34, activity: "Gathering", target_id: 31) | tl(walking())]
      assert tick(400, [scout() | mining ++ home()], start()).strategy.claim == nil

      carrying = [unit(101, "Worker", 20, 20, activity: "Returning") | tl(walking())]
      assert tick(400, [scout() | carrying ++ home()], start()).strategy.claim == nil
    end

    test "not within forty ticks of banking: the walk out to a far field takes that long" do
      assert tick(389, [scout() | walking() ++ home()], start()).strategy.claim == nil
      assert tick(390, [scout() | walking() ++ home()], start()).strategy.claim == {34, 34}
    end

    test "not with an enemy at our base, and not with home fallen back to the towers or just out of it" do
      raid = soldiers_of_theirs(1..3, 9, 9)
      assert tick(400, [scout() | walking() ++ home()] ++ raid, start()).strategy.claim == nil

      assert tick(400, [scout() | walking() ++ home()], %{start() | fall_back: true, fall_back_at: 395}).strategy.claim == nil
      assert tick(400, [scout() | walking() ++ home()], %{start() | fall_back_at: 380}).strategy.claim == nil
      assert tick(430, [scout() | walking() ++ home()], %{start() | fall_back_at: 380}).strategy.claim == {34, 34}
    end

    test "not a field with more on it than home can take" do
      army = soldiers_of_theirs(1..60, 35, 35)
      assert tick(400, [unit(300, "Scout", 30, 30) | walking() ++ home()] ++ army, start(), alive: 8000).strategy.claim == nil
    end
  end

  describe "the field's guard" do
    test "ten at least, three times what is there, of home's attackers nearest it; the rest stay home" do
      t = tick(400, [scout() | walking() ++ home()], start())
      assert length(t.strategy.claim_guard) == 10
      assert Enum.all?(t.strategy.claim_guard, &to_field?(t.orders[&1]))
      rest = Enum.to_list(201..240) -- t.strategy.claim_guard
      refute Enum.any?(rest, &to_field?(t.orders[&1]))
      # No help is called for the whole of home: the field is the guard's.
      assert t.strategy.help == nil

      # Six Soldiers on it, in sight of our scout: eighteen.
      t = tick(400, [unit(300, "Scout", 30, 30) | walking() ++ home()] ++ soldiers_of_theirs(1..6, 35, 35), start())
      assert length(t.strategy.claim_guard) == 18
    end

    test "it grows with what comes, keeps its size for forty ticks after they go, and its dead are replaced" do
      t = tick(400, [scout() | walking() ++ home()], start())
      guard = t.strategy.claim_guard
      assert length(guard) == 10
      there = at_field(1..10) ++ home(11..40)

      # Five Archers come: 5 x 1.25 x 3 = 19.
      t = tick(420, [scout() | walking() ++ there] ++ archers(1..5, 37, 37), t.memory, deposits: in_sight())
      assert length(t.strategy.claim_guard) == 19
      assert Enum.all?(guard, &(&1 in t.strategy.claim_guard))
      bigger = t.strategy.claim_guard

      # They step out of sight: the guard is who it was.
      t = tick(440, [scout() | walking() ++ there], t.memory, deposits: in_sight())
      assert t.strategy.claim_guard == bigger

      # Two of the guard die: two more of home's attackers take their place.
      alive = Enum.reject(there, &(&1["id"] in [201, 202]))
      t = tick(441, [scout() | walking() ++ alive], t.memory, deposits: in_sight())
      assert length(t.strategy.claim_guard) == 19
      refute 201 in t.strategy.claim_guard or 202 in t.strategy.claim_guard
    end

    test "no more than home's attackers: the base's own guards stay at the base" do
      # Twelve Soldiers at home: some guard the base (`Roles`), the rest attack. Only those go.
      t = tick(400, [scout() | walking() ++ home(1..12)], start())
      attackers = for {id, :attacker} <- Swarm.Roles.home_roles(t.v, nil), do: id
      assert length(attackers) in 1..9
      assert Enum.sort(t.strategy.claim_guard) == Enum.sort(attackers)
    end

    test "with nobody at home who could guard it, no field is taken; with an attacker again, it is" do
      # Five Soldiers: all of them the base's own guards.
      t = tick(400, [scout() | walking() ++ home(1..5)], start())
      assert Swarm.Roles.home_roles(t.v, nil) |> Map.values() |> Enum.all?(&(&1 == :guard))
      assert t.strategy.claim == nil and t.log == []

      t = tick(401, [scout() | walking() ++ home(1..12)], t.memory)
      assert t.strategy.claim == {34, 34} and t.strategy.claim_guard != []
    end

    test "Archers at the held field pull nobody else out from home" do
      t = tick(400, [scout() | walking() ++ home()], start())
      there = at_field(1..10) ++ home(11..40)
      # The workers are on the field with the guard; two Archers come at them.
      t = tick(420, [scout() | on_field() ++ there] ++ archers(1..2, 38, 36), t.memory, deposits: in_sight())
      t = tick(421, [scout() | on_field() ++ there] ++ archers(1..2, 38, 36), t.memory, deposits: in_sight())
      assert t.strategy.claim == {34, 34}
      refute Enum.any?(211..240, &to_field?(t.orders[&1]))
      # The guard goes for them.
      assert Enum.any?(201..210, &match?(%{"type" => "Attack", "targetId" => id} when id in [901, 902], t.orders[&1]))
    end

    test "with no field taken, a raid on our workers out there still pulls home's attackers" do
      # The same Archers by the same workers, mining there with nothing claimed (ore banked a tick ago).
      mining = for w <- on_field(), do: %{w | "activity" => "Gathering", "targetId" => 31}
      memory = %{start() | income_at: {9_000, 419}}
      t = tick(420, [scout() | mining ++ home()] ++ archers(1..2, 36, 36), memory, deposits: in_sight())
      assert t.strategy.claim == nil
      assert Enum.any?(211..240, &to_field?(t.orders[&1]))
    end
  end

  describe "workers on a held field" do
    setup do
      t = tick(400, [scout() | walking() ++ home()], start())
      %{memory: t.memory, there: at_field(1..10) ++ home(11..40)}
    end

    test "Archers seven tiles from the ore: they mine on behind the guard", %{memory: memory, there: there} do
      idle = for(i <- 1..10, do: unit(100 + i, "Worker", 31, 33))
      t = tick(420, [scout() | idle ++ there] ++ archers(1..2, 41, 41), memory, deposits: in_sight())
      assert Enum.all?(101..110, &mines?(t.orders[&1]))
    end

    test "the same Archers with no guard on the field: nobody mines it", %{memory: memory} do
      idle = for(i <- 1..10, do: unit(100 + i, "Worker", 31, 33))
      # The guard is still on its way: two of them there.
      t = tick(420, [scout() | idle ++ at_field(1..2) ++ home(3..40)] ++ archers(1..2, 41, 41), memory, deposits: in_sight())
      refute Enum.any?(101..110, &mines?(t.orders[&1]))
    end

    test "a pile an Archer could hit a worker at is left; the others are mined", %{memory: memory, there: there} do
      # Archers at (40, 35): piles at x = 35 are five tiles off (reach 4 and two steps), x = 34 six... all within 6 but the far column.
      idle = for(i <- 1..10, do: unit(100 + i, "Worker", 26, 34))
      t = tick(420, [scout() | idle ++ there] ++ archers(1..2, 41, 35), memory, deposits: in_sight())
      targets = for i <- 101..110, %{"type" => "Gather", "targetId" => id} <- [t.orders[i]], uniq: true, do: id
      assert targets != [] and Enum.all?(targets, &(&1 in [31, 33]))
    end

    test "a worker in an Archer's reach steps back behind the guard, not home to the tower", %{memory: memory, there: there} do
      workers = [unit(101, "Worker", 36, 35, activity: "Gathering", target_id: 34) | for(i <- 2..10, do: unit(100 + i, "Worker", 31, 33))]
      t = tick(420, [scout() | workers ++ there] ++ archers(1..2, 41, 36), memory, deposits: in_sight())
      assert %{"type" => "Move", "x" => x, "y" => y} = t.orders[101]
      assert View.dist({x, y}, {34, 34}) <= 8
      # The others, out of reach, carry on.
      assert Enum.all?(102..110, &mines?(t.orders[&1]))

      # With the guard itself in their reach (all in the fight): a few tiles straight back, still not home.
      t = tick(420, [scout() | workers ++ there] ++ archers(1..2, 39, 36), memory, deposits: in_sight())
      assert %{"type" => "Move", "x" => x, "y" => y} = t.orders[101]
      assert View.dist({x, y}, {36, 35}) <= 7 and View.dist({x, y}, {39, 36}) > 4
    end

    test "the same worker with no field held runs for the tower at home", %{there: there} do
      workers = [unit(101, "Worker", 36, 35, activity: "Gathering", target_id: 34) | for(i <- 2..10, do: unit(100 + i, "Worker", 31, 33))]
      t = tick(420, [scout() | workers ++ there] ++ archers(1..2, 41, 36), %{start() | income_at: {9_000, 419}}, deposits: in_sight())
      assert t.strategy.claim == nil
      assert %{"type" => "Move", "x" => x, "y" => y} = t.orders[101]
      assert View.dist({x, y}, {34, 34}) > 8
    end

    test "an army comes: the field is given up and the workers leave it", %{memory: memory, there: there} do
      army = soldiers_of_theirs(1..70, 37, 37)
      t = tick(420, [scout() | on_field() ++ there] ++ army, memory, deposits: in_sight(), alive: 9000)
      assert t.strategy.claim == nil and t.strategy.claim_guard == []
      assert [said] = t.log
      assert said =~ "is given up"
      refute Enum.any?(101..110, &mines?(t.orders[&1]))
      # And the guard doesn't stand and die: nobody is sent at them.
      refute Enum.any?(201..210, &match?(%{"type" => "Attack"}, t.orders[&1]))
    end
  end

  test "the whole thing: driven off, the guard goes, Archers come and go, the ore is mined, and home never leaves" do
    # Tick 400: fifty ticks of walking and nothing banked.
    t = tick(400, [scout() | walking(30, 30) ++ home()] ++ archers(1..2, 33, 31), start())
    assert t.strategy.claim == {34, 34}
    guard = t.strategy.claim_guard
    stayers = Enum.to_list(201..240) -- guard
    there = at_field(1..10) ++ home(11..40)
    assert Enum.sort(guard) == Enum.to_list(201..210)

    # Tick after tick: Archers in sight seven tiles off, gone, in reach of one pile, gone.
    idle = for(i <- 1..10, do: unit(100 + i, "Worker", 31, 33))

    {memory, seen} =
      Enum.reduce(1..12, {t.memory, []}, fn n, {memory, seen} ->
        raiders =
          case rem(n, 4) do
            1 -> archers(1..2, 41, 41)
            3 -> archers(1..2, 41, 35)
            _ -> []
          end

        t = tick(420 + n, [scout() | idle ++ there] ++ raiders, memory, deposits: in_sight())
        {t.memory, [{t.strategy.claim, Enum.count(101..110, &mines?(t.orders[&1])), Enum.count(stayers, &to_field?(t.orders[&1]))} | seen]}
      end)

    # Held throughout; somebody mines every tick; nobody else ever sets out from home.
    assert Enum.all?(seen, fn {claim, mining, out} -> claim == {34, 34} and mining > 0 and out == 0 end)
    assert Enum.sort(memory.claim.guard) == Enum.to_list(201..210) or length(memory.claim.guard) >= 10
  end
end
