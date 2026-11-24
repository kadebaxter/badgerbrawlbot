defmodule Swarm.Reads do
  @moduledoc """
  What kind of opponent each player is, read from what we have seen of them and the scoreboard:

  - `:boom`: a late army and a big economy (hundreds of workers, many Command Centers or towers,
    no fighters to speak of): open to an attack on a base before its towers are up
  - `:flood`: an army near ours or bigger: held at our towers, as ever
  - `:siege`: a smaller, balanced army with Trebuchets or many Archers
  - `:harass`: Scouts and little else
  - `:unknown`: not looked at yet, too early to say, or none of the above

  A read is kept per player (`%{owner => read}`, in the leader's memory) and only changes once
  what we see has said the same thing for `@hold` ticks: one sighting doesn't flip it.
  """

  # Nothing is read before this tick: everyone looks the same with five workers.
  @from 120
  @hold 30

  @type kind :: :boom | :flood | :siege | :harass | :unknown

  @typedoc """
  What we know of a player this tick: `army` (their fighters as we know them, in Soldiers),
  `soldiers`, `archers`, `scouts`, `trebuchets` (remembered, by count), `ccs` and `towers` (known
  buildings), `economy` (ore banked, by the scoreboard), `looked` (a scout got to them just now).
  """
  @type facts :: %{optional(atom()) => number() | boolean()}

  @doc "The kind player `owner` reads as (`:unknown` with no read)."
  @spec kind(map(), integer() | nil) :: kind()
  def kind(reads, owner), do: get_in(reads || %{}, [owner, :kind]) || :unknown

  @doc """
  `reads` with player `owner`'s brought up to date from `facts`; `ours` is our own army in
  Soldiers and `mined` our ore banked. Returns `{reads, notes}`: a note for the decision log each
  time a read changes.
  """
  @spec update(map(), integer(), integer(), facts(), number(), number()) :: {map(), [{atom(), String.t()}]}
  def update(reads, tick, owner, facts, ours, mined) do
    read = Map.get(reads, owner, %{kind: :unknown, candidate: :unknown, since: tick, looked: false, scouts: 0, trebuchets: 0})

    read = %{
      read
      | looked: read.looked or Map.get(facts, :looked, false),
        scouts: max(read.scouts, Map.get(facts, :scouts, 0)),
        trebuchets: max(read.trebuchets, Map.get(facts, :trebuchets, 0))
    }

    now = classify(read, facts, ours, mined, tick)

    cond do
      now == read.kind ->
        {Map.put(reads, owner, %{read | candidate: now, since: tick}), []}

      now != read.candidate ->
        {Map.put(reads, owner, %{read | candidate: now, since: tick}), []}

      tick - read.since >= @hold ->
        why = "player #{owner} reads as #{now} (was #{read.kind}): #{evidence(read, facts, ours, mined)}"
        {Map.put(reads, owner, %{read | kind: now, since: tick}), [{:read, why}]}

      true ->
        {Map.put(reads, owner, read), []}
    end
  end

  @doc "The kind `facts` say, for a player we have `read` so far."
  @spec classify(map(), facts(), number(), number(), integer()) :: kind()
  def classify(read, facts, ours, mined, tick) do
    army = Map.get(facts, :army, 0)
    soldiers = Map.get(facts, :soldiers, 0)
    archers = Map.get(facts, :archers, 0)
    ccs = Map.get(facts, :ccs, 0)
    towers = Map.get(facts, :towers, 0)
    economy = Map.get(facts, :economy, 0)

    cond do
      not read.looked or tick < @from -> :unknown
      read.scouts >= 6 and soldiers + archers < 6 and ccs <= 1 -> :harass
      army <= max(3, 0.3 * ours) and (ccs >= 2 or towers >= 5 or economy >= 1.25 * mined) -> :boom
      read.trebuchets >= 1 or (soldiers + archers >= 5 and archers >= 0.4 * (soldiers + archers) and army < ours) -> :siege
      army >= 6 and army >= 0.7 * ours -> :flood
      true -> :unknown
    end
  end

  defp evidence(read, facts, ours, mined) do
    "#{Float.round(Map.get(facts, :army, 0) * 1.0, 1)} Soldiers' worth of army against our #{Float.round(ours * 1.0, 1)}, " <>
      "#{Map.get(facts, :soldiers, 0)} Soldiers and #{Map.get(facts, :archers, 0)} Archers remembered, " <>
      "#{read.scouts} Scouts and #{read.trebuchets} Trebuchets at most, " <>
      "#{Map.get(facts, :ccs, 0)} Command Centers and #{Map.get(facts, :towers, 0)} towers known, " <>
      "#{Map.get(facts, :economy, 0)} ore banked against our #{mined}"
  end
end
