defmodule LaliaBemaWeb.TasksLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Watcher

  test "renders empty state when no tasks exist", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/tasks")

    assert html =~ "Tasks"
    assert html =~ "No tasks match"
  end

  test "lists seeded tasks with their status", %{conn: conn} do
    seed_task(%{slug: "fix-things", title: "Fix things", owner: "alice", project: "alpha"})
    seed_task(%{slug: "ship-it", title: "Ship it", owner: "bob", project: "beta"})

    {:ok, _lv, html} = live(conn, "/tasks")

    assert html =~ "fix-things"
    assert html =~ "Fix things"
    assert html =~ "ship-it"
    assert html =~ "alice"
    assert html =~ "alpha"
  end

  test "filtering by status narrows results", %{conn: conn} do
    seed_task(%{slug: "a", title: "A", status: :claimed, owner: "alice"})
    seed_task(%{slug: "b", title: "B", status: :in_progress, owner: "alice"})

    {:ok, lv, _html} = live(conn, "/tasks")

    html = render_change(lv, "filter", %{"filters" => %{"status" => "claimed"}})

    assert html =~ "<tr id=\"task-a\""
    refute html =~ "<tr id=\"task-b\""
  end

  test "reset restores full task list", %{conn: conn} do
    seed_task(%{slug: "a", title: "A", status: :claimed})
    seed_task(%{slug: "b", title: "B", status: :in_progress})

    {:ok, lv, _html} = live(conn, "/tasks")

    _ = render_change(lv, "filter", %{"filters" => %{"status" => "claimed"}})
    html = render_click(lv, "reset", %{})

    assert html =~ "task-a"
    assert html =~ "task-b"
  end

  test "reloads when {:tasks, _} is broadcast", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/tasks")

    seed_task(%{slug: "late", title: "Late arrival"})

    Phoenix.PubSub.broadcast(Watcher.pubsub(), Watcher.topic(), {:tasks, :reconciled})

    html = render(lv)
    assert html =~ "Late arrival"
  end

  defp seed_task(attrs) do
    defaults = %{
      slug: "task-#{System.unique_integer([:positive])}",
      title: "untitled",
      status: :published,
      published_at: DateTime.utc_now()
    }

    {:ok, task} = Scope.upsert_task(Map.merge(defaults, attrs))
    task
  end
end
