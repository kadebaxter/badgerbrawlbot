defmodule Swarm.MatchTest do
  use ExUnit.Case, async: true
  alias Swarm.Match

  test "a match id is a UUID; anything else is a name" do
    assert Match.id?("a9cb5fe1-4ec0-4aa1-a4c9-72fbe60aa50f")
    refute Match.id?("season-week3")
    refute Match.id?("a9cb5fe1-4ec0-4aa1-a4c9")
  end

  describe "submit" do
    # A server that takes at most 100 commands a request, like the real one, and says deposit 77 is
    # gone. Each request's commands go to the test process.
    defp client do
      test = self()

      Req.new(
        base_url: "http://netrts.test",
        retry: false,
        plug: fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          commands = Jason.decode!(body)["commands"]
          send(test, {:request, commands})

          results =
            for {c, i} <- Enum.with_index(commands) do
              cond do
                length(commands) > 100 -> %{index: i, accepted: false, error: %{code: "TOO_MANY_COMMANDS", message: ""}}
                c["targetId"] == 77 -> %{index: i, accepted: false, error: %{code: "RESOURCE_NOT_FOUND", message: ""}}
                true -> %{index: i, accepted: true}
              end
            end

          conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(%{results: results}))
        end
      )
    end

    defp moves(n), do: for(i <- 1..n, do: %{"type" => "Move", "unitIds" => [i], "x" => 1, "y" => 1})

    test "one request a tick, never more than 100: the server runs no more than that a tick" do
      assert {:ok, []} = Match.submit(client(), "m", 1, moves(130))
      assert_received {:request, sent}
      assert sent == moves(100)
      refute_received {:request, _}
    end

    test "a Gather on a deposit the server says is gone comes back, to be forgotten" do
      gather = %{"type" => "Gather", "unitIds" => [500], "targetId" => 77}
      assert {:ok, [77]} = Match.submit(client(), "m", 1, moves(3) ++ [gather, gather])
    end
  end

  test "hosting asks for every seat, our house bots, and the name if there is one" do
    assert %{maxPlayers: 6, houseBots: ["rusher"], name: "kaden-brawl"} =
             Match.host_body(%{seats: 6, bots: ["rusher"], name: "kaden-brawl"})

    body = Match.host_body(%{seats: 4, bots: [], name: nil})
    assert %{maxPlayers: 4, houseBots: []} = body
    refute Map.has_key?(body, :name)
  end
end
