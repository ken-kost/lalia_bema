defmodule LaliaBemaWeb.FeedLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Watcher

  test "renders empty state when Ash is empty", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/")

    assert html =~ "Lalia Scope"
    assert html =~ "No agents registered."
    assert html =~ "No rooms yet."
    assert html =~ "Waiting for messages"
  end

  test "hydrates from Ash on mount", %{conn: conn} do
    {:ok, _} =
      Scope.upsert_agent(%{
        agent_id: "01HA1",
        name: "alice",
        branch: "main",
        harness: "claude",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    {:ok, _} =
      Scope.upsert_room(%{
        name: "demo",
        description: "demo room",
        member_count: 2
      })

    {:ok, _} =
      Scope.upsert_message(%{
        kind: :room,
        target: "demo",
        from: "alice",
        seq: 1,
        body: "hello room",
        posted_at: DateTime.utc_now()
      })

    {:ok, _lv, html} = live(conn, "/")

    assert html =~ "hello room"
    assert html =~ "alice"
    assert html =~ "demo"
    assert html =~ "2 members"
  end

  test "re-reads message from Ash and prepends on PubSub broadcast", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/")
    refute html =~ "fresh arrival"

    {:ok, _lv, _} = live(conn, "/")

    # Simulate the Watcher: insert into Ash, then broadcast the hint.
    {:ok, _} =
      Scope.upsert_message(%{
        kind: :channel,
        target: "a--b",
        from: "bob",
        seq: 7,
        body: "fresh arrival",
        posted_at: DateTime.utc_now()
      })

    {:ok, lv, _} = live(conn, "/")

    Phoenix.PubSub.broadcast(Watcher.pubsub(), Watcher.topic(),
      {:new_message, %{kind: :channel, target: "a--b", seq: 7, from: "bob"}}
    )

    html = render(lv)
    assert html =~ "fresh arrival"
    assert html =~ "bob"
    assert html =~ "peer"
  end

  test "refreshes agents/rooms panels from Ash on structural broadcasts", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/")

    {:ok, _} =
      Scope.upsert_agent(%{
        agent_id: "01HA2",
        name: "zed",
        branch: "main",
        harness: "claude",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    {:ok, _} = Scope.upsert_room(%{name: "new-room", member_count: 3})

    Phoenix.PubSub.broadcast(Watcher.pubsub(), Watcher.topic(), {:agents, []})
    Phoenix.PubSub.broadcast(Watcher.pubsub(), Watcher.topic(), {:rooms, []})

    html = render(lv)
    assert html =~ "zed"
    assert html =~ "new-room"
    assert html =~ "3 members"
  end
end
