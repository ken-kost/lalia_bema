defmodule LaliaBema.BackfillTest do
  use LaliaBema.DataCase, async: false

  alias LaliaBema.Backfill
  alias LaliaBema.Scope

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "lalia_bema_backfill_#{System.unique_integer([:positive])}")

    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(Path.join(workspace, "registry"))
    File.mkdir_p!(Path.join(workspace, "rooms/demo"))
    File.mkdir_p!(Path.join(workspace, "peers/a--b"))

    # registry/<ulid>.json
    File.write!(
      Path.join(workspace, "registry/01ARZ3NDEKTSV4RRFFQ69G5FAV.json"),
      Jason.encode!(%{
        agent_id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        name: "alice",
        project: "demo",
        branch: "main",
        harness: "claude",
        started_at: "2026-04-22T10:00:00+02:00",
        last_seen_at: "2026-04-22T10:05:00+02:00",
        expires_at: "2026-04-22T11:00:00+02:00",
        repo_root: "/tmp/demo",
        pubkey: "deadbeef"
      })
    )

    # rooms/demo/ROOM.md + MEMBERS.md + one message
    File.write!(Path.join(workspace, "rooms/demo/ROOM.md"), """
    # room demo

    created_by: alice
    created_at: 2026-04-22T10:00:00+02:00
    desc: demo room
    """)

    File.write!(Path.join(workspace, "rooms/demo/MEMBERS.md"), """
    # members

    count: 2

    - alice
    - bob
    """)

    File.write!(Path.join(workspace, "rooms/demo/000001-alice.md"), """
    ---
    seq: 1
    from: alice
    room: demo
    ts: 2026-04-22T10:01:00+02:00
    ---

    hello demo
    """)

    # peers/a--b/...
    File.write!(Path.join(workspace, "peers/a--b/000001-alice.md"), """
    ---
    seq: 1
    from: alice
    ts: 2026-04-22T10:02:00+02:00
    ---

    hi bob
    """)

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{workspace: workspace}
  end

  test "walks workspace and upserts everything", %{workspace: workspace} do
    {:ok, stats} = Backfill.run(workspace: workspace)

    assert stats.agents == 1
    assert stats.rooms == 1
    assert stats.messages == 2
    assert stats.errors == 0

    assert [%{name: "alice", project: "demo"}] = Scope.list_agents!()
    assert [%{name: "demo", member_count: 2, description: "demo room"}] = Scope.list_rooms!()
    assert Scope.list_messages!() |> length() == 2
  end

  test "running twice does not duplicate or change state", %{workspace: workspace} do
    {:ok, first} = Backfill.run(workspace: workspace)
    {:ok, second} = Backfill.run(workspace: workspace)

    assert first == second
    assert length(Scope.list_agents!()) == 1
    assert length(Scope.list_rooms!()) == 1
    assert length(Scope.list_messages!()) == 2
  end
end
