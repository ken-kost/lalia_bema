defmodule LaliaBemaWeb.AgentLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Watcher

  test "renders empty activity when nothing is known about the agent", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/agents/nobody")

    assert html =~ "nobody"
    assert html =~ "not registered"
    assert html =~ "No messages from this agent."
  end

  test "shows registry metadata, rooms, channels, and recent messages", %{conn: conn} do
    {:ok, _} =
      Scope.upsert_agent(%{
        agent_id: "01HA1",
        name: "alice",
        project: "alpha",
        branch: "main",
        harness: "claude",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    seed_message(%{kind: :room, target: "demo", from: "alice", seq: 1, body: "hi demo"})
    seed_message(%{kind: :channel, target: "alice--bob", from: "alice", seq: 1, body: "hi bob"})

    {:ok, _lv, html} = live(conn, "/agents/alice")

    assert html =~ "alice"
    assert html =~ "alpha"
    assert html =~ "claude"
    assert html =~ "demo"
    assert html =~ "alice--bob"
    assert html =~ "hi demo"
    assert html =~ "hi bob"
  end

  test "refreshes on new_message broadcast for this agent", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/agents/zed")

    seed_message(%{kind: :room, target: "r", from: "zed", seq: 1, body: "after mount"})

    Phoenix.PubSub.broadcast(Watcher.pubsub(), Watcher.topic(),
      {:new_message, %{kind: :room, target: "r", seq: 1, from: "zed"}}
    )

    html = render(lv)
    assert html =~ "after mount"
  end

  defp seed_message(attrs) do
    defaults = %{body: "", posted_at: DateTime.utc_now()}
    {:ok, m} = Scope.upsert_message(Map.merge(defaults, attrs))
    m
  end
end
