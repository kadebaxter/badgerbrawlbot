defmodule Mix.Tasks.Swarm.Solo do
  @shortdoc "Plays one match with the non-distributed bot"
  @moduledoc """
  Plays one match with no cluster, no `ra` and no unit processes: the baseline.

      mix swarm.solo

  Uses the same environment variables as the swarm (`NETRTS_SERVER`, `NETRTS_API_KEY`,
  `SWARM_OPPONENT`, `SWARM_TICK_MS`, ...).
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Application.put_env(:swarm, :start_cluster, false, persistent: true)
    Mix.Task.run("app.start")
    Swarm.Solo.run()
  end
end
