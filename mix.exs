defmodule Swarm.MixProject do
  use Mix.Project

  def project do
    [
      app: :swarm,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      # The Docker image runs this release (see Dockerfile).
      releases: [swarm: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      # runtime_tools: :dbg and friends in a remote shell on a running pod.
      extra_applications: [:logger, :runtime_tools],
      mod: {Swarm.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ra, "~> 3.2"},
      {:libcluster, "~> 3.5"},
      {:req, "~> 0.7.5"},
      {:jason, "~> 1.4"},
      # Serves /metrics and /health (see Swarm.Metrics).
      {:bandit, "~> 1.14"}
    ]
  end
end
