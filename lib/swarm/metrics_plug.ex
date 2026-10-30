defmodule Swarm.MetricsPlug do
  @moduledoc "The node's HTTP endpoint: `/metrics` for Prometheus, `/health` for probes."

  import Plug.Conn

  def init(opts), do: opts

  def call(%{method: "GET", request_path: "/metrics"} = conn, _opts) do
    conn
    |> put_resp_content_type("text/plain; version=0.0.4")
    |> send_resp(200, Swarm.Metrics.render())
  end

  def call(%{method: "GET", request_path: "/health"} = conn, _opts), do: send_resp(conn, 200, "ok\n")
  def call(conn, _opts), do: send_resp(conn, 404, "not found\n")
end
