defmodule Swarm.MatchTest do
  use ExUnit.Case, async: true
  alias Swarm.Match

  test "a match id is a UUID; anything else is a name" do
    assert Match.id?("a9cb5fe1-4ec0-4aa1-a4c9-72fbe60aa50f")
    refute Match.id?("season-week3")
    refute Match.id?("a9cb5fe1-4ec0-4aa1-a4c9")
  end

  test "hosting asks for every seat, our house bots, and the name if there is one" do
    assert %{maxPlayers: 6, houseBots: ["rusher"], name: "kaden-brawl"} =
             Match.host_body(%{seats: 6, bots: ["rusher"], name: "kaden-brawl"})

    body = Match.host_body(%{seats: 4, bots: [], name: nil})
    assert %{maxPlayers: 4, houseBots: []} = body
    refute Map.has_key?(body, :name)
  end
end
