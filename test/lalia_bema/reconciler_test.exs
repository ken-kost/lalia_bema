defmodule LaliaBema.ReconcilerTest do
  use LaliaBema.DataCase, async: false

  alias LaliaBema.Reconciler
  alias LaliaBema.Scope

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "lalia_bema_recon_#{System.unique_integer([:positive])}")

    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(Path.join(workspace, "registry"))
    File.mkdir_p!(Path.join(workspace, "rooms"))
    File.mkdir_p!(Path.join(workspace, "peers"))

    # Registry file with lease in the PAST — active? should be false after reconcile.
    File.write!(
      Path.join(workspace, "registry/01ARZ3NDEKTSV4RRFFQ69G5FAV.json"),
      Jason.encode!(%{
        agent_id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        name: "stale-alice",
        project: "demo",
        branch: "main",
        harness: "claude",
        started_at: "2020-01-01T00:00:00Z",
        last_seen_at: "2020-01-01T00:00:00Z",
        expires_at: "2020-01-01T01:00:00Z"
      })
    )

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{workspace: workspace}
  end

  test "manually inserted agent with a future lease gets flipped stale by the reconciler",
       %{workspace: workspace} do
    # Pretend we had stale data: agent inserted with lease_expires_at in the future.
    {:ok, fresh} =
      Scope.upsert_agent(%{
        agent_id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        name: "stale-alice",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    fresh = Ash.load!(fresh, :active?)
    assert fresh.active? == true

    {:ok, _pid} = start_supervised({Reconciler, workspace: workspace, interval_ms: 60_000})
    {:ok, stats} = Reconciler.reconcile()
    assert stats.agents == 1

    reconciled =
      Scope.get_agent!("01ARZ3NDEKTSV4RRFFQ69G5FAV", load: [:active?])

    assert reconciled.active? == false
  end
end
