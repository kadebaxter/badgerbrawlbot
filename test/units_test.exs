defmodule Swarm.UnitsTest do
  @moduledoc "Where new unit processes go: by units per core, not an even split."
  use ExUnit.Case, async: true
  alias Swarm.Units

  # Our three machines: galaxy 16 cores, nuc 4, sama 12.
  @nodes [:"swarm@swarm-0", :"swarm@swarm-1", :"swarm@swarm-2"]
  @cores %{:"swarm@swarm-0" => 16, :"swarm@swarm-1" => 4, :"swarm@swarm-2" => 12}

  defp place(n) do
    Enum.reduce(1..n, %{}, fn _, load ->
      Map.update(load, Units.pick_node(@nodes, load, @cores), 1, &(&1 + 1))
    end)
  end

  test "180 units split by cores: the 4-core machine carries an eighth, not a third" do
    load = place(180)
    assert load[:"swarm@swarm-0"] in 89..91
    assert load[:"swarm@swarm-1"] in 22..23
    assert load[:"swarm@swarm-2"] in 67..68
  end

  test "a node we couldn't ask counts as one core; ties go to the first by name; none, nil" do
    assert Units.pick_node(@nodes, %{}, %{}) == :"swarm@swarm-0"
    assert Units.pick_node([:b, :a], %{a: 1}, %{a: 16}) == :b
    assert Units.pick_node([], %{}, %{}) == nil
  end
end
