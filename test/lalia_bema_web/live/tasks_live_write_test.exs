defmodule LaliaBemaWeb.TasksLiveWriteTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia
  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "claim button shells out to `lalia task claim`", %{conn: conn} do
    seed_task(%{slug: "fix-me", title: "Fix me"})

    {:ok, lv, _html} = live(conn, "/tasks")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ = render_click(lv, "claim", %{"slug" => "fix-me"})

    assert LaliaStub.last_args() == ~w[task claim fix-me --as scope-human]
  end

  test "set-status form submits `lalia task set-status <slug> <status>`",
       %{conn: conn} do
    seed_task(%{slug: "work", title: "work", status: :claimed, owner: "scope-human"})

    {:ok, lv, _html} = live(conn, "/tasks")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ =
      render_submit(lv, "set-status", %{"slug" => "work", "status" => "in-progress"})

    assert LaliaStub.last_args() ==
             ~w[task set-status work in-progress --as scope-human]
  end

  test "reassign form submits `lalia task reassign <slug> <agent>`",
       %{conn: conn} do
    seed_task(%{slug: "x", title: "x", owner: "scope-human"})

    {:ok, lv, _html} = live(conn, "/tasks")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ = render_submit(lv, "reassign", %{"slug" => "x", "agent" => "alice"})

    assert LaliaStub.last_args() == ~w[task reassign x alice --as scope-human]
  end

  test "publish modal submits to `lalia task publish --file <tmp>` with --as",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/tasks")

    _ = render_click(lv, "open-publish", %{})

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ =
      render_submit(lv, "publish", %{"payload" => ~s|{"slug":"demo","title":"Demo"}|})

    args = LaliaStub.last_args()
    assert ["task", "publish", "--file", path, "--as", "scope-human"] = args
    assert is_binary(path)
  end

  test "publish with invalid JSON shows 'Invalid JSON' error and skips CLI",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/tasks")

    _ = render_click(lv, "open-publish", %{})

    LaliaStub.clear_args()

    html = render_submit(lv, "publish", %{"payload" => "not-json"})

    assert html =~ "Invalid JSON"
    assert LaliaStub.all_args() == []
  end

  test "unpublish with --force flag shells out with the flag",
       %{conn: conn} do
    seed_task(%{slug: "remove-me", title: "Remove me"})

    {:ok, lv, _html} = live(conn, "/tasks")

    _ = render_click(lv, "confirm-unpublish", %{"slug" => "remove-me"})
    _ = render_click(lv, "unpublish-flag", %{"flag" => "force", "value" => "true"})

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ = render_click(lv, "unpublish", %{"slug" => "remove-me"})

    assert LaliaStub.last_args() ==
             ~w[task unpublish remove-me --force --as scope-human]
  end

  defp seed_task(attrs) do
    defaults = %{
      slug: "t-#{System.unique_integer([:positive])}",
      title: "untitled",
      status: :published,
      published_at: DateTime.utc_now()
    }

    {:ok, task} = Scope.upsert_task(Map.merge(defaults, attrs))
    task
  end
end
