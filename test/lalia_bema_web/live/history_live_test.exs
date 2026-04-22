defmodule LaliaBemaWeb.HistoryLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Watcher

  test "renders empty state for an unknown room", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/history/room/ghost")

    assert html =~ "room/ghost"
    assert html =~ "No messages"
  end

  test "renders messages with permalink anchors", %{conn: conn} do
    seed_message(%{kind: :room, target: "demo", from: "alice", seq: 1, body: "one"})
    seed_message(%{kind: :room, target: "demo", from: "bob", seq: 2, body: "two"})

    {:ok, _lv, html} = live(conn, "/history/room/demo")

    assert html =~ "one"
    assert html =~ "two"
    assert html =~ ~s(id="msg-1")
    assert html =~ ~s(id="msg-2")
  end

  test "body substring search filters and updates URL", %{conn: conn} do
    seed_message(%{kind: :room, target: "demo", from: "alice", seq: 1, body: "alpha one"})
    seed_message(%{kind: :room, target: "demo", from: "bob", seq: 2, body: "beta two"})

    {:ok, lv, _} = live(conn, "/history/room/demo")

    html = render_submit(lv, "search", %{"q" => "alpha"})

    assert html =~ "alpha one"
    refute html =~ "beta two"
    assert_patched(lv, "/history/room/demo?q=alpha")
  end

  test "supports channel kind with peer pair target", %{conn: conn} do
    seed_message(%{kind: :channel, target: "alice--bob", from: "alice", seq: 7, body: "peer msg"})

    {:ok, _lv, html} = live(conn, "/history/channel/alice--bob")

    assert html =~ "channel/alice--bob"
    assert html =~ "peer msg"
    assert html =~ ~s(id="msg-7")
  end

  test "refreshes on new_message broadcast for matching target", %{conn: conn} do
    {:ok, lv, _} = live(conn, "/history/room/demo")

    seed_message(%{kind: :room, target: "demo", from: "carol", seq: 1, body: "live arrival"})

    Phoenix.PubSub.broadcast(Watcher.pubsub(), Watcher.topic(),
      {:new_message, %{kind: :room, target: "demo", seq: 1, from: "carol"}}
    )

    html = render(lv)
    assert html =~ "live arrival"
  end

  defp seed_message(attrs) do
    defaults = %{body: "", posted_at: DateTime.utc_now()}
    {:ok, m} = Scope.upsert_message(Map.merge(defaults, attrs))
    m
  end
end
