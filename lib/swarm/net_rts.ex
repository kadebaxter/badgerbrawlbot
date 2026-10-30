defmodule Swarm.NetRts do
  @moduledoc """
  HTTP client for the NetRTS (Badger Brawl) bot API. See the NetRTS repo's `docs/bot-guide.md`.

  Every call returns `{:ok, body}` or `{:error, reason}`. API errors come back as
  `{:error, %{status: 409, code: "MATCH_NOT_STARTED", message: "..."}}`.
  """

  @type client :: Req.Request.t()

  @spec new(String.t(), String.t()) :: client()
  def new(server, api_key) do
    # Long polls are held for up to ~30 s by the server.
    Req.new(
      base_url: server,
      headers: [authorization: "Bearer #{api_key}"],
      receive_timeout: 40_000,
      retry: false
    )
  end

  def create_match(client, body), do: request(client, :post, "/api/v1/matches", body)

  def state(client, match_id, wait_for_tick, since_tick \\ nil) do
    params = [waitForTick: wait_for_tick] ++ if(since_tick, do: [sinceTick: since_tick], else: [])
    request(client, :get, "/api/v1/matches/#{match_id}/state", nil, params)
  end

  def match_by_name(client, name), do: request(client, :get, "/api/v1/matches/named/#{name}")

  def match(client, match_id), do: request(client, :get, "/api/v1/matches/#{match_id}")

  def join(client, match_id), do: request(client, :post, "/api/v1/matches/#{match_id}/join")

  def leave(client, match_id), do: request(client, :post, "/api/v1/matches/#{match_id}/leave")

  def map(client, match_id), do: request(client, :get, "/api/v1/matches/#{match_id}/map")

  def commands(client, match_id, commands),
    do: request(client, :post, "/api/v1/matches/#{match_id}/commands", %{commands: commands})

  def result(client, match_id), do: request(client, :get, "/api/v1/matches/#{match_id}/result")

  defp request(client, method, url, body \\ nil, params \\ []) do
    opts = [method: method, url: url, params: params] ++ if(body, do: [json: body], else: [])

    case Req.request(client, opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        body = if is_map(body), do: body, else: %{}

        {:error,
         %{status: status, code: body["code"] || "HTTP_ERROR", message: body["message"] || ""}}

      {:error, exception} ->
        {:error, exception}
    end
  end
end
