import Config

config :logger, :default_formatter, format: "$time [$level] $message\n"

config :swarm, start_cluster: true

import_config "#{config_env()}.exs"
