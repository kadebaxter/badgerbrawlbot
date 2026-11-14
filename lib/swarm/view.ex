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
    # Guard tower shots on the last tick: ours, and any where we can see the tower or its target
    # (`towerShots`: towerId, owner, fromX/fromY, targetId, x/y). A tower hits at once.
    tower_shots: [],
    # Where the last opponent's Command Center we leave standing is (set by `Swarm.Brain.plan/3`),
    # or nil: no tower of ours goes up in reach of it.
    spared: nil,
    # In sight, plus remembered ones once `with_known_ore/2` has run (those have a "seen" tick).
    deposits: [],
    enemy_starts: [],
    # start position => player slot, for the opponents still in
    start_owner: %{},
    # Where opponents who have been eliminated started: their ore is ours to take.
    fallen_starts: [],
    # How many players the game started with (eliminated ones too).
    players: 2,
    # Enemy fighters seen in the last few ticks and out of sight now, where we last saw them (set
    # by `Swarm.Brain.see/2`). Only danger counts them (`Swarm.Roles.danger_at/2`): nobody targets
    # what it can't see.
    recent_enemies: [],
    # The backup Command Center we regroup at while the main base is overrun, or nil (set by
    # `Swarm.Brain.see/2`): its own two workers mine by it, in secret (`Swarm.UnitBrain`).
    regroup: nil,
    # Team-wide answers worked out once per tick on each node (`Swarm.Roles.share/2`), or nil.
    shared: nil,
    # player slot => survival score (the ore value of everything they have alive), opponents only
    enemy_survival: %{}
  ]

  @type t :: %__MODULE__{}
  @type pos :: {integer(), integer()}

  # Ore farther than this from a drop-off isn't worth the walk.
  @drop_off_reach 10
  # Depots this close to the Command Center are home (see `home_drop_offs/1`); one farther out is an
  # outpost, as `Swarm.Roles` has it.
  @home_ore 6

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
      tower_shots: state["towerShots"] || [],
      map_width: state["mapWidth"],
      players: length(state["players"]),
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
      fallen_starts:
        for(
          p <- state["players"],
          p["slot"] != me and p["eliminated"] and p["startPosition"] != nil,
          do: pos(p["startPosition"])
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
  # Our Command Center and our depots; not a backup Command Center (another one, far from home),
  # so workers never go mining by it and give it away. It becomes the Command Center if we lose ours.
  def drop_offs(%__MODULE__{my_buildings: buildings, cc: cc} = v) do
    cached(v, :drop_offs, fn ->
      for b <- buildings, b["completed"], b["type"] == "ResourceDepot" or b == cc, do: pos(b)
    end)
  end

  @doc "How far a deposit is from the nearest drop-off: the walk a miner repeats. Nil with none."
  def trip(%__MODULE__{shared: %{trips: trips}} = v, deposit) do
    case Map.fetch(trips, deposit["id"]) do
      {:ok, trip} -> trip
      :error -> v |> drop_offs() |> Enum.map(&dist(&1, pos(deposit))) |> Enum.min(fn -> nil end)
    end
  end

  def trip(%__MODULE__{} = v, deposit) do
    v |> drop_offs() |> Enum.map(&dist(&1, pos(deposit))) |> Enum.min(fn -> nil end)
  end

  @doc """
  Deposits by a Resource Depot of ours that is still being built: worth mining once it is done,
  and the place to head for while it goes up.
  """
  def soon_near_deposits(%__MODULE__{my_buildings: buildings, deposits: deposits} = v) do
    cached_ids(v, :soon_near_ids, fn ->
      sites = for b <- buildings, b["type"] == "ResourceDepot", not b["completed"], do: pos(b)
      Enum.filter(deposits, fn d -> Enum.any?(sites, &(dist(&1, pos(d)) <= @drop_off_reach)) end)
    end)
  end

  @doc "Drop-offs at home: the Command Center and depots within #{@home_ore} of it."
  def home_drop_offs(%__MODULE__{cc: nil}), do: []
  def home_drop_offs(%__MODULE__{cc: cc} = v), do: Enum.filter(drop_offs(v), &(dist(&1, pos(cc)) <= @home_ore))

  @doc "Deposits worth mining from a drop-off at home (`home_drop_offs/1`)."
  def home_deposits(%__MODULE__{} = v) do
    cached_ids(v, :home_ids, fn ->
      home = home_drop_offs(v)
      Enum.filter(v.deposits, fn d -> Enum.any?(home, &(dist(&1, pos(d)) <= @drop_off_reach)) end)
    end)
  end

  @doc "How far ore can be from a drop-off and still be worth mining."
  def drop_off_reach, do: @drop_off_reach

  @doc "Deposits worth mining: within #{@drop_off_reach} tiles of a drop-off."
  def near_deposits(%__MODULE__{} = v) do
    cached_ids(v, :near_ids, fn ->
      Enum.filter(v.deposits, fn d ->
        trip = trip(v, d)
        trip != nil and trip <= @drop_off_reach
      end)
    end)
  end

  @doc """
  The economy's answers worked out once for every worker (`Swarm.Roles.share/2` puts them in
  `shared`): the drop-offs, each deposit's walk to the nearest one, and which deposits are by a
  drop-off, by home, or by a depot going up.
  """
  def share_economy(%__MODULE__{shared: shared} = v) do
    shared = shared || %{}
    v = %{v | shared: Map.put(shared, :drop_offs, drop_offs(%{v | shared: nil}))}
    v = %{v | shared: Map.put(v.shared, :trips, Map.new(v.deposits, &{&1["id"], trip(v, &1)}))}

    # As ids: the view already carries the deposits, and it is copied to every unit.
    ids = &MapSet.new(&1, fn d -> d["id"] end)

    %{
      v
      | shared:
          Map.merge(v.shared, %{
            near_ids: ids.(near_deposits(v)),
            soon_near_ids: ids.(soon_near_deposits(v)),
            home_ids: ids.(home_deposits(v))
          })
    }
  end

  # The deposits whose ids `shared[key]` holds, in the view's order, when worked out; else `fun.()`.
  defp cached_ids(%__MODULE__{shared: %{} = shared, deposits: deposits}, key, fun) do
    case shared do
      %{^key => ids} -> Enum.filter(deposits, &MapSet.member?(ids, &1["id"]))
      _ -> fun.()
    end
  end

  defp cached_ids(_v, _key, fun), do: fun.()

  @doc "`shared[key]` when it has been worked out (`share_economy/1`, `Swarm.Roles.share/2`), else `fun.()`."
  def cached(%__MODULE__{shared: %{} = shared}, key, fun) do
    case shared do
      %{^key => value} -> value
      _ -> fun.()
    end
  end

  def cached(_v, _key, fun), do: fun.()

  def completed?(%__MODULE__{status: status}), do: status == "Completed"

  @doc """
  The deposits we can see plus those we remember (`known`: id => deposit as last seen, with
  "seen", the tick) that are out of sight now. The server only sends the ore in sight, but
  deposits never move and a Gather may name one in the fog. A remembered one keeps its "seen".
  """
  def with_known_ore(%__MODULE__{deposits: visible} = v, known) do
    ids = MapSet.new(visible, & &1["id"])
    remembered = for {id, d} <- Enum.sort(known), not MapSet.member?(ids, id), do: d
    %{v | deposits: visible ++ remembered}
  end

  @doc """
  Our finished Command Centers other than the main one: backups, kept secret. Nobody mines by one
  but its own workers while we regroup there.
  """
  def backups(%__MODULE__{cc: cc} = v) do
    for b <- buildings_of(v, "CommandCenter"), b["completed"], cc == nil or b["id"] != cc["id"], do: pos(b)
  end

  @doc "Deposits in sight right now (not remembered ones)."
  def deposits_in_sight(%__MODULE__{deposits: deposits}), do: Enum.reject(deposits, &Map.has_key?(&1, "seen"))

  @doc """
  Whether we can see `pos` now, by the game's rule (Euclidean, each unit and finished building
  by its own vision), one tile short to be safe.
  """
  def in_sight?(%__MODULE__{} = v, {x, y}) do
    eyes = v.my_units ++ Enum.filter(v.my_buildings, & &1["completed"])

    Enum.any?(eyes, fn e ->
      r = sight(e) - 1
      (e["x"] - x) ** 2 + (e["y"] - y) ** 2 <= r * r
    end)
  end

  # From the bot guide's tables.
  @sight %{"Worker" => 5, "Soldier" => 5, "Archer" => 6, "Scout" => 8, "Trebuchet" => 7, "GuardTower" => 7}
  defp sight(e), do: Map.get(@sight, e["type"], 6)

  @doc """
  Whether `pos` is on our side of the map: closer to our Command Center than to any opponent's
  start. Everything is, with no Command Center.
  """
  def ours?(%__MODULE__{cc: nil}, _pos), do: true

  def ours?(%__MODULE__{cc: cc} = v, pos) do
    home = dist(pos, pos(cc))
    Enum.all?(v.enemy_starts, &(home < dist(pos, &1)))
  end
end
