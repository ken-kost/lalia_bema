defmodule LaliaBemaWeb.ChannelsLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia
  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "renders channels from stub output as a table row", %{conn: conn} do
    LaliaStub.set_response(out: "alice--bob last_activity=2026-04-22 unread=3\n")

    {:ok, _lv, html} = live(conn, "/channels")

    assert html =~ "alice--bob"
    assert html =~ "2026-04-22"
    assert html =~ ">3<"
  end

  test "empty output shows empty state", %{conn: conn} do
    LaliaStub.set_response(out: "\n")

    {:ok, _lv, html} = live(conn, "/channels")

    assert html =~ "No channels visible"
  end

  test "non-zero exit shows an error panel", %{conn: conn} do
    LaliaStub.set_response(exit: 2, err: "boom\n")

    {:ok, _lv, html} = live(conn, "/channels")

    assert html =~ "channels-error"
    assert html =~ "lalia exited 2"
  end

  test "refresh button re-queries the CLI", %{conn: conn} do
    LaliaStub.set_response(out: "")
    {:ok, lv, _html} = live(conn, "/channels")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "alice--carol unread=1\n")

    html = render_click(lv, "refresh", %{})

    assert html =~ "alice--carol"
    assert LaliaStub.last_args() == ~w[channels --as scope-human]
  end
end
