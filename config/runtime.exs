import Config

# Everything here can be set with environment variables; see README.md.
if config_env() != :test do
  [_name, host] =
    case String.split(to_string(node()), "@") do
      [name, host] -> [name, host]
      _ -> ["nonode", "nohost"]
    end

  # SWARM_PEERS="a,b,c" means a@<this host>, b@<this host>, c@<this host>.
  # Full names ("swarm@swarm-0.swarm.default.svc.cluster.local") are used as they are.
  peers =
    case System.get_env("SWARM_PEERS") do
      nil ->
        [node()]

      list ->
        list
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn peer -> if peer =~ "@", do: peer, else: "#{peer}@#{host}" end)
        |> Enum.map(&String.to_atom/1)
    end

  tick_ms =
    case System.get_env("SWARM_TICK_MS") do
      nil -> nil
      ms -> String.to_integer(ms)
    end

  config :swarm,
    server: System.get_env("NETRTS_SERVER", "http://localhost:5080"),
    api_key: System.get_env("NETRTS_API_KEY"),
    # One house bot, or several for a free-for-all: SWARM_OPPONENT=balanced,rusher
    opponents: System.get_env("SWARM_OPPONENT", "sitter") |> String.split(",", trim: true) |> Enum.map(&String.trim/1),
    tick_ms: tick_ms,
    matches: String.to_integer(System.get_env("SWARM_MATCHES", "1")),
    peers: peers,
    data_dir: Path.join(System.get_env("SWARM_DATA_DIR", "data"), to_string(node()))

  # scripts/iex.sh: a plain shell with no cluster, for trying things out.
  if System.get_env("SWARM_CLUSTER") == "false", do: config(:swarm, start_cluster: false)

  config :libcluster,
    topologies: [
      swarm: [strategy: Cluster.Strategy.Epmd, config: [hosts: peers]]
    ]
end
