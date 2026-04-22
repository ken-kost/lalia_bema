defmodule LaliaBemaWeb.RoomLiveWriteTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia
  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "post composer shells out to `lalia post <room> <body>`", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo"})
    # participants is called on mount
    LaliaStub.set_response(out: "\n")

    {:ok, lv, _html} = live(conn, "/rooms/demo")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ = render_submit(lv, "post", %{"body" => "hi there"})

    assert LaliaStub.last_args() == ~w[post demo hi there --as scope-human]
  end

  test "empty body shows an error flash and does not shell out", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo"})
    LaliaStub.set_response(out: "\n")
    {:ok, lv, _html} = live(conn, "/rooms/demo")

    LaliaStub.clear_args()

    html = render_submit(lv, "post", %{"body" => "   "})

    assert html =~ "Message body is empty"
    assert LaliaStub.all_args() == []
  end

  test "Join button shells out to `lalia join <room>`", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo"})
    LaliaStub.set_response(out: "\n")
    {:ok, lv, _html} = live(conn, "/rooms/demo")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ = render_click(lv, "join", %{})

    argvs = LaliaStub.all_args()
    assert ~w[join demo --as scope-human] in argvs
  end

  test "peek button shows the peek panel with CLI output", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo"})
    LaliaStub.set_response(out: "\n")
    {:ok, lv, _html} = live(conn, "/rooms/demo")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "pending=5\nmailbox preview\n")

    html = render_click(lv, "peek", %{})

    assert html =~ "peek-panel"
    assert html =~ "pending=5"
    assert LaliaStub.last_args() == ~w[peek demo --room --as scope-human]
  end

  test "consume requires confirm; confirming sends `lalia read <room> --room --timeout 0`",
       %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo"})
    LaliaStub.set_response(out: "\n")
    {:ok, lv, _html} = live(conn, "/rooms/demo")

    html = render_click(lv, "confirm-consume", %{})
    assert html =~ "Destructive"

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "[1 2026-04-22 alice] hi\n")

    _ = render_click(lv, "consume", %{})

    assert LaliaStub.last_args() == ~w[read demo --room --timeout 0 --as scope-human]
  end
end
