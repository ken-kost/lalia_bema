defmodule LaliaBemaWeb.InboxLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia
  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "renders empty state when no channels/rooms", %{conn: conn} do
    LaliaStub.set_response(out: "\n")

    {:ok, _lv, html} = live(conn, "/inbox")

    assert html =~ "Inbox"
    assert html =~ "No peer channels"
  end

  test "peek button on a channel card calls `lalia peek` and shows raw output",
       %{conn: conn} do
    LaliaStub.set_response(out: "alice--bob unread=1\n")
    {:ok, lv, _html} = live(conn, "/inbox")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "pending=2\npreview body here\n")

    html = render_click(lv, "peek", %{"target" => "alice--bob"})

    args = LaliaStub.last_args()
    assert args == ~w[peek alice--bob --as scope-human]
    assert html =~ "pending=2"
  end

  test "consume button triggers confirm; confirming calls `lalia read`",
       %{conn: conn} do
    LaliaStub.set_response(out: "alice--bob unread=1\n")
    {:ok, lv, _html} = live(conn, "/inbox")

    html = render_click(lv, "confirm-consume", %{"target" => "alice--bob"})
    assert html =~ "Consume the next message"

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "[7 2026-04-22T10:00:00Z alice] hey\n")

    _html = render_click(lv, "do-consume", %{})

    assert LaliaStub.last_args() == ~w[read alice--bob --timeout 0 --as scope-human]
  end

  test "read-any button calls `lalia read-any`", %{conn: conn} do
    LaliaStub.set_response(out: "\n")
    {:ok, lv, _html} = live(conn, "/inbox")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "[1 2026-04-22 bob] hey\n")

    _html = render_click(lv, "read-any", %{})

    assert LaliaStub.last_args() == ~w[read-any --timeout 0 --as scope-human]
  end
end
