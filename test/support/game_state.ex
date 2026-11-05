defmodule Swarm.Test.GameState do
  @moduledoc "Builds small game states (shaped like the server's JSON) for tests."

  def state(opts \\ []) do
    %{
      "tick" => Keyword.get(opts, :tick, 100),
      "status" => "Active",
      "mapWidth" => 64,
      "mapHeight" => 64,
      "tickIntervalMs" => 1000,
      "you" => %{"slot" => 0, "resources" => Keyword.get(opts, :ore, 0)},
      "players" => [
        %{"slot" => 0, "eliminated" => false, "startPosition" => %{"x" => 7, "y" => 7}},
        %{"slot" => 1, "eliminated" => false, "startPosition" => %{"x" => 56, "y" => 56}}
      ],
      "units" => Keyword.get(opts, :units, []),
      "buildings" => [cc() | Keyword.get(opts, :buildings, [])],
      "resources" => Keyword.get(opts, :deposits, [%{"id" => 4, "x" => 2, "y" => 7, "remaining" => 900}]),
      "rememberedBuildings" => []
    }
  end

  def cc, do: building(1, "CommandCenter", 7, 7)

  def building(id, type, x, y, owner \\ 0) do
    %{"id" => id, "owner" => owner, "type" => type, "x" => x, "y" => y, "completed" => true, "production" => []}
  end

  def unit(id, type, x, y, opts \\ []) do
    %{
      "id" => id,
      "owner" => Keyword.get(opts, :owner, 0),
      "type" => type,
      "x" => x,
      "y" => y,
      "activity" => Keyword.get(opts, :activity, "Idle"),
      "carrying" => 0,
      "targetId" => Keyword.get(opts, :target_id)
    }
  end

  def workers(n), do: for(i <- 1..n, do: unit(100 + i, "Worker", 8, 8, activity: "Gathering", target_id: 4))
  def soldiers(n, opts \\ []), do: for(i <- 1..n, do: unit(200 + i, "Soldier", 10, 10, opts))

  def terrain, do: List.duplicate(String.duplicate(".", 64), 64)

  @doc """
  Brain memory (or a fresh one, for nil) in which a scout has just looked at `owner`, so a wave
  may leave at `tick` without waiting for a look. Only one if the memory has no look yet.
  """
  def looked(memory, owner \\ 1, tick \\ 100) do
    memory = memory || Swarm.Brain.new_memory()
    if memory.look, do: memory, else: %{memory | look: %{owner: owner, pos: {50, 50}, at: tick - 10, done: tick}}
  end
end
