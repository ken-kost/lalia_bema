defmodule Mix.Tasks.Lalia.Backfill do
  @moduledoc """
  Walks the configured Lalia workspace and upserts every agent, room, and
  message into the Ash Scope domain. Idempotent.

      mix lalia.backfill
      mix lalia.backfill --workspace /path/to/workspace
  """
  use Mix.Task

  @shortdoc "Backfill the Ash Scope store from the Lalia git workspace"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, strict: [workspace: :string])

    backfill_opts =
      case opts[:workspace] do
        nil -> []
        ws -> [workspace: ws]
      end

    {:ok, stats} = LaliaBema.Backfill.run(backfill_opts)

    Mix.shell().info(
      "Backfill complete: #{stats.agents} agent(s), #{stats.rooms} room(s), " <>
        "#{stats.messages} message(s), errors: #{stats.errors}"
    )
  end
end
