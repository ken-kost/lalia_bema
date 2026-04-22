defmodule LaliaBemaWeb.RoomLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Watcher

  test "renders empty state when the room has no messages", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "quiet", description: "nothing here"})

    {:ok, _lv, html} = live(conn, "/rooms/quiet")

    assert html =~ "quiet"
    assert html =~ "nothing here"
    assert html =~ "No messages"
  end

  test "lists messages and derives members", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo", member_count: 2})

    {:ok, _} =
      Scope.upsert_agent(%{
        agent_id: "01HA1",
        name: "alice",
        lease_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })

    seed_message(%{kind: :room, target: "demo", from: "alice", seq: 1, body: "hello room"})
    seed_message(%{kind: :room, target: "demo", from: "bob", seq: 2, body: "hi alice"})

    {:ok, _lv, html} = live(conn, "/rooms/demo")

    assert html =~ "hello room"
    assert html =~ "hi alice"
    assert html =~ "alice"
    assert html =~ "bob"
    assert html =~ "not registered"
  end

  test "body substring search filters messages", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo"})
    seed_message(%{kind: :room, target: "demo", from: "alice", seq: 1, body: "alpha one"})
    seed_message(%{kind: :room, target: "demo", from: "bob", seq: 2, body: "beta two"})

    {:ok, lv, _html} = live(conn, "/rooms/demo")

    html = render_submit(lv, "search", %{"q" => "alpha"})

    assert html =~ "alpha one"
    refute html =~ "beta two"
  end

  test "appends message on matching new_message broadcast", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo"})
    {:ok, lv, _} = live(conn, "/rooms/demo")

    seed_message(%{kind: :room, target: "demo", from: "bob", seq: 1, body: "fresh"})
    Phoenix.PubSub.broadcast(Watcher.pubsub(), Watcher.topic(),
      {:new_message, %{kind: :room, target: "demo", seq: 1, from: "bob"}}
    )

    html = render(lv)
    assert html =~ "fresh"
  end

  defp seed_message(attrs) do
    defaults = %{body: "", posted_at: DateTime.utc_now()}
    {:ok, m} = Scope.upsert_message(Map.merge(defaults, attrs))
    m
  end
end
