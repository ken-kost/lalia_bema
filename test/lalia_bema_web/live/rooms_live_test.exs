defmodule LaliaBemaWeb.RoomsLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia
  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "renders empty state when no rooms exist", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/rooms")

    assert html =~ "Rooms"
    assert html =~ "No rooms yet"
  end

  test "seeded rooms render with names and member counts", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo", description: "demo room", member_count: 3})
    {:ok, _} = Scope.upsert_room(%{name: "alpha", description: "alpha stuff", member_count: 1})

    {:ok, _lv, html} = live(conn, "/rooms")

    assert html =~ "demo"
    assert html =~ "alpha"
    assert html =~ "demo room"
    # member counts rendered in table cell
    assert html =~ ">3<"
    assert html =~ ">1<"
  end

  test "clicking New Room opens the create modal", %{conn: conn} do
    {:ok, lv, html} = live(conn, "/rooms")

    refute html =~ "Create room"

    html = render_click(lv, "open-create", %{})
    assert html =~ "Create room"
  end

  test "submitting the create form shells out to `lalia room create` and closes modal",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/rooms")

    _ = render_click(lv, "open-create", %{})
    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    html = render_submit(lv, "create", %{"name" => "demo", "desc" => ""})

    assert LaliaStub.last_args() == ~w[room create demo --as scope-human]
    refute html =~ "Create room"
  end

  test "confirming archive sweep calls `lalia rooms gc`", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/rooms")

    html = render_click(lv, "confirm-gc", %{})
    assert html =~ "Archive sweep"
    assert html =~ "Yes, run"

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _html = render_click(lv, "gc", %{})
    assert LaliaStub.last_args() == ~w[rooms gc --as scope-human]
  end

  test "Join button calls `lalia join <room>`", %{conn: conn} do
    {:ok, _} = Scope.upsert_room(%{name: "demo", member_count: 0})

    {:ok, lv, _html} = live(conn, "/rooms")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _html = render_click(lv, "join", %{"room" => "demo"})

    # participants is called after join; first call should be the join itself.
    argvs = LaliaStub.all_args()
    assert ~w[join demo --as scope-human] in argvs
  end
end
