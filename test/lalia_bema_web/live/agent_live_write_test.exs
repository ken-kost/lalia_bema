defmodule LaliaBemaWeb.AgentLiveWriteTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia
  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "tell mode shells out to `lalia tell <peer> <body>`", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/agents/alice")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ =
      render_submit(lv, "send", %{"body" => "hi", "mode" => "tell", "timeout" => "30"})

    assert LaliaStub.last_args() == ~w[tell alice hi --as scope-human]
  end

  test "ask mode shells out with --timeout and shows reply panel", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/agents/alice")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "pong\n")

    html =
      render_submit(lv, "send", %{"body" => "q?", "mode" => "ask", "timeout" => "10"})

    assert LaliaStub.last_args() == ~w[ask alice q? --timeout 10 --as scope-human]
    assert html =~ "ask-reply"
    assert html =~ "pong"
  end

  test "empty body shows an error flash and skips the CLI", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/agents/alice")

    LaliaStub.clear_args()

    html = render_submit(lv, "send", %{"body" => "   ", "mode" => "tell", "timeout" => "30"})

    assert html =~ "Message body is empty"
    assert LaliaStub.all_args() == []
  end

  test "peek button shows mailbox peek panel and argv hits `lalia peek <agent>`",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/agents/alice")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "pending=1\n")

    html = render_click(lv, "peek", %{})

    assert html =~ "peek-panel"
    assert LaliaStub.last_args() == ~w[peek alice --as scope-human]
  end
end
