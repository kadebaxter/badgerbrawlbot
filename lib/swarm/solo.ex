defmodule Swarm.Solo do
  @moduledoc """
  The bot without any concurrency: one loop asks the team brain and then every unit's brain,
  one after another, and posts the commands. Same decisions as the swarm, no processes, no
  cluster, no `ra`. Run it with `mix swarm.solo`.
  """

  require Logger
  alias Swarm.{Brain, Match, NetRts, UnitBrain, View}

  def run do
    client = NetRts.new(Match.config(:server), Match.api_key!())
    match_id = Match.create!(client)
    state = Match.wait_for_start!(client, match_id)
    terrain = Match.terrain!(client, match_id)

    loop(client, match_id, terrain, state, Brain.new_memory(), %{})
    Match.report(client, match_id)
  end

  # `minds` is unit id => that unit's own memory.
  defp loop(client, match_id, terrain, state, memory, minds) do
    view = View.new(state)

    if View.completed?(view) do
      :done
    else
      {strategy, commands, memory} = Brain.plan(view, memory, terrain)

      # Each unit decides for itself, but here they simply take turns.
      decisions =
        for unit <- view.my_units, into: %{} do
          id = unit["id"]
          {id, UnitBrain.decide(id, view, strategy, Map.get(minds, id, UnitBrain.new_memory()))}
        end

      unit_commands = for {_id, {cmd, _mind}} <- decisions, cmd != :no_change, do: cmd
      minds = Map.new(decisions, fn {id, {_cmd, mind}} -> {id, mind} end)

      # Team commands last: the latest order for a unit wins, so a builder keeps its Build.
      Match.submit(client, match_id, view.tick, unit_commands ++ commands)

      if rem(view.tick, 20) == 0 do
        Logger.info(
          "tick #{view.tick} | ore #{view.ore} | #{length(view.my_units)} units | #{strategy.mode}"
        )
      end

      {:ok, next} = NetRts.state(client, match_id, view.tick + 1, view.tick)
      loop(client, match_id, terrain, next, memory, minds)
    end
  end
end
