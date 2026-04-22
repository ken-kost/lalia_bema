defmodule LaliaBema.Reconciler do
  @moduledoc """
  Periodic belt-and-suspenders pass that re-runs `LaliaBema.Backfill` so any
  git commits the filesystem watcher missed still land in Ash. Runs every
  60 seconds by default.

  Stale agents are detected naturally: registry files carry `expires_at`,
  so the upserted `lease_expires_at` flips the `active?` calculation once
  the timestamp passes.
  """
  use GenServer
  require Logger

  alias LaliaBema.Backfill

  @default_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs a reconciliation pass synchronously. Useful for tests."
  def reconcile(server \\ __MODULE__) do
    GenServer.call(server, :reconcile)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    workspace = Keyword.get(opts, :workspace)

    schedule(interval)
    {:ok, %{interval: interval, workspace: workspace}}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    {:reply, do_reconcile(state), state}
  end

  @impl true
  def handle_info(:tick, state) do
    do_reconcile(state)
    schedule(state.interval)
    {:noreply, state}
  end

  defp do_reconcile(%{workspace: workspace}) do
    opts = if workspace, do: [workspace: workspace], else: []

    case Backfill.run(opts) do
      {:ok, stats} ->
        if stats.errors > 0 do
          Logger.warning("LaliaBema.Reconciler: completed with #{stats.errors} error(s)")
        end

        {:ok, stats}

      other ->
        Logger.warning("LaliaBema.Reconciler: backfill returned #{inspect(other)}")
        other
    end
  rescue
    e ->
      Logger.warning("LaliaBema.Reconciler raised: #{inspect(e)}")
      {:error, e}
  end

  defp schedule(interval) do
    Process.send_after(self(), :tick, interval)
  end
end
