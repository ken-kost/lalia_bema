defmodule LaliaBemaWeb.NicknamesLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia
  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "renders nickname list from stub output", %{conn: conn} do
    LaliaStub.set_response(out: "alice nick-alice follow\nbob nick-b\n")

    {:ok, _lv, html} = live(conn, "/nicknames")

    assert html =~ "alice"
    assert html =~ "nick-alice"
    assert html =~ "bob"
    assert html =~ "nick-b"
    assert html =~ "follow"
  end

  test "empty list shows empty state", %{conn: conn} do
    LaliaStub.set_response(out: "\n")

    {:ok, _lv, html} = live(conn, "/nicknames")

    assert html =~ "No nicknames configured"
  end

  test "submitting the form shells out to `lalia nickname set` with --follow",
       %{conn: conn} do
    LaliaStub.set_response(out: "\n")
    {:ok, lv, _html} = live(conn, "/nicknames")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ =
      render_submit(lv, "save", %{
        "form" => %{"name" => "alice", "nickname" => "al", "follow" => "true"}
      })

    argvs = LaliaStub.all_args()

    assert ~w[nickname set alice al --follow --as scope-human] in argvs
  end

  test "submitting without follow omits the --follow flag", %{conn: conn} do
    LaliaStub.set_response(out: "\n")
    {:ok, lv, _html} = live(conn, "/nicknames")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ =
      render_submit(lv, "save", %{
        "form" => %{"name" => "bob", "nickname" => "bb", "follow" => "false"}
      })

    argvs = LaliaStub.all_args()
    assert ~w[nickname set bob bb --as scope-human] in argvs
  end

  test "delete button shells out to `lalia nickname delete`", %{conn: conn} do
    LaliaStub.set_response(out: "alice nick-alice\n")

    {:ok, lv, _html} = live(conn, "/nicknames")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ = render_click(lv, "delete", %{"name" => "alice"})

    argvs = LaliaStub.all_args()
    assert ~w[nickname delete alice --as scope-human] in argvs
  end
end
