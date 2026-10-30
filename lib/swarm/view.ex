defmodule Swarm.View do
  @moduledoc """
  The game state from one `GET .../state`, sorted into what the brains need.

  Units, buildings and deposits stay as the JSON maps the server sent (string keys).
  This is what the leader sends to every unit process each tick, so it holds no terrain.
  """

  defstruct [
    :tick,
    :status,
    :me,
    :ore,
    :map_width,
    :map_height,
    :cc,
    max_ticks: 1800,
    my_score: 0,
    enemy_score: 0,
    my_units: [],
    my_buildings: [],
    enemy_units: [],
    enemy_buildings: [],
    remembered: [],
    upgrades: [],
    researching: [],
    events: [],
    shells: [],
    deposits: [],
    enemy_starts: [],
    # start position => player slot, for the opponents still in
    start_owner: %{},
    # player slot => survival score (the ore value of everything they have alive), opponents only
    enemy_survival: %{}
  ]

  @type t :: %__MODULE__{}
  @type pos :: {integer(), integer()}

  # Ore farther than this from a drop-off isn't worth the walk.
  @drop_off_reach 10

  @spec new(map()) :: t()
  def new(state) do
    me = state["you"]["slot"]
    {my_units, enemy_units} = Enum.split_with(state["units"], &(&1["owner"] == me))
    {my_buildings, enemy_buildings} = Enum.split_with(state["buildings"], &(&1["owner"] == me))
    {mine, others} = Enum.split_with(state["players"], &(&1["slot"] == me))
    score = fn p -> get_in(p, ["score", "total"]) || 0 end

    %__MODULE__{
      tick: state["tick"],
      status: state["status"],
      me: me,
      ore: state["you"]["resources"],
      upgrades: state["you"]["upgrades"] || [],
      researching: for(r <- state["you"]["researching"] || [], do: r["upgrade"]),
      events: state["events"] || [],
      # Siege shots in flight: ours, and any landing where we can see.
      shells: state["shells"] || [],
      map_width: state["mapWidth"],
      map_height: state["mapHeight"],
      max_ticks: state["maxTicks"] || 1800,
      my_score: mine |> Enum.map(score) |> Enum.max(fn -> 0 end),
      # The best opponent's: that is who we have to beat on time.
      enemy_score: others |> Enum.map(score) |> Enum.max(fn -> 0 end),
      cc: Enum.find(my_buildings, &(&1["type"] == "CommandCenter")),
      my_units: my_units,
      my_buildings: my_buildings,
      enemy_units: enemy_units,
      enemy_buildings: enemy_buildings,
      remembered: state["rememberedBuildings"] || [],
      deposits: state["resources"],
      enemy_starts:
        for(
          p <- state["players"],
          p["slot"] != me and not p["eliminated"],
          do: pos(p["startPosition"])
        ),
      start_owner:
        for(
          p <- state["players"],
          p["slot"] != me and not p["eliminated"],
          into: %{},
          do: {pos(p["startPosition"]), p["slot"]}
        ),
      enemy_survival:
        for(
          p <- others,
          not p["eliminated"],
          into: %{},
          do: {p["slot"], get_in(p, ["score", "survival"]) || 0}
        )
    }
  end

  @doc "Chebyshev distance: the game's notion of range and adjacency."
  def dist({ax, ay}, {bx, by}), do: max(abs(ax - bx), abs(ay - by))

  def pos(%{"x" => x, "y" => y}), do: {x, y}

  def my_unit(%__MODULE__{my_units: units}, id), do: Enum.find(units, &(&1["id"] == id))

  def units_of(%__MODULE__{my_units: units}, type), do: Enum.filter(units, &(&1["type"] == type))

  def buildings_of(%__MODULE__{my_buildings: buildings}, type),
    do: Enum.filter(buildings, &(&1["type"] == type))

  def military(%__MODULE__{my_units: units}), do: Enum.reject(units, &(&1["type"] == "Worker"))

  @doc "Where ore can be dropped off: our finished Command Center and Resource Depots."
  def drop_offs(%__MODULE__{my_buildings: buildings}) do
    for b <- buildings, b["type"] in ["CommandCenter", "ResourceDepot"], b["completed"], do: pos(b)
  end

  @doc "How far a deposit is from the nearest drop-off: the walk a miner repeats. Nil with none."
  def trip(%__MODULE__{} = v, deposit) do
    v |> drop_offs() |> Enum.map(&dist(&1, pos(deposit))) |> Enum.min(fn -> nil end)
  end

  @doc "Deposits worth mining: within #{@drop_off_reach} tiles of a drop-off."
  def near_deposits(%__MODULE__{} = v) do
    Enum.filter(v.deposits, fn d ->
      trip = trip(v, d)
      trip != nil and trip <= @drop_off_reach
    end)
  end

  def completed?(%__MODULE__{status: status}), do: status == "Completed"
end
