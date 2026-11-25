import Config

config :swarm, start_cluster: false
config :logger, level: :warning
# The home guard the test fixtures are written around ("22 Soldiers: 15 attackers"). A game has 9
# (`Swarm.Roles`).
config :swarm, guards: 7
