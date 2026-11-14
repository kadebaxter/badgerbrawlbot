defmodule Swarm.Fight do
  @moduledoc """
  How a fight between two sides would go, played out tick by tick: the one measure our fighters
  decide a fight by (`Swarm.Roles.groups/2`). Comparing prices (`Swarm.Roles.strength/2`) can't
  see what matters most in a fight: who hits first. Twenty-three archers stacked together shoot a
  Soldier walking in from out of their reach the whole way; twenty-six Soldiers that arrive
  together kill them all and keep eighteen, the same twenty-six arriving one a tick all die.

  Each side is a list of fighters: `hp`, `armor`, `damage` a hit, `cooldown` (ticks between
  hits), `delay` (ticks before it can hit at all: the walk into reach), `order` (who is hit first:
  lowest, then the least HP) and `value` (what one HP of it is worth). Every tick each side's
  fighters that can hit add up their damage against the armor of the other side's front fighter,
  and it falls on the front ones in turn (focus fire), both sides at once.

  The answer is the share of our side left minus the share of theirs (by value), from 1 (we lose
  nothing, they lose all) to -1. It is quick: a few thousand additions for a hundred a side.
  """

  @max_ticks 60

  @type fighter :: %{
          hp: number(),
          armor: number(),
          damage: number(),
          cooldown: number(),
          delay: non_neg_integer(),
          order: integer(),
          value: number()
        }

  @spec advantage([fighter()], [fighter()]) :: float()
  def advantage([], []), do: 0.0
  def advantage([], _theirs), do: -1.0
  def advantage(_ours, []), do: 1.0

  def advantage(ours, theirs) do
    ours = Enum.sort_by(ours, &{&1.order, &1.hp})
    theirs = Enum.sort_by(theirs, &{&1.order, &1.hp})
    {ours_left, theirs_left} = run(ours, theirs, 0)
    worth(ours_left) / worth(ours) - worth(theirs_left) / worth(theirs)
  end

  defp run(ours, theirs, tick) when tick >= @max_ticks or ours == [] or theirs == [], do: {ours, theirs}

  defp run(ours, theirs, tick) do
    to_theirs = hits(ours, hd(theirs).armor, tick)
    to_ours = hits(theirs, hd(ours).armor, tick)
    run(take(ours, to_ours), take(theirs, to_theirs), tick + 1)
  end

  defp hits(side, armor, tick) do
    Enum.reduce(side, 0.0, fn f, sum ->
      if f.delay <= tick, do: sum + max(1, f.damage - armor) / f.cooldown, else: sum
    end)
  end

  defp take(side, damage) when damage <= 0, do: side
  defp take([], _damage), do: []

  defp take([f | rest], damage) do
    if damage >= f.hp, do: take(rest, damage - f.hp), else: [%{f | hp: f.hp - damage} | rest]
  end

  defp worth(side), do: max(1.0e-9, Enum.sum_by(side, &(&1.hp * &1.value)))
end
