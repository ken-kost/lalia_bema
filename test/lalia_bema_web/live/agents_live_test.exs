defmodule LaliaBemaWeb.AgentsLiveTest do
  use LaliaBemaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias LaliaBema.Scope
  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia
  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "renders empty state when no agents exist", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/agents")

    assert html =~ "Agents"
    assert html =~ "No agents match"
  end

  test "seeded agents render with names and active-lease dot", %{conn: conn} do
    seed_agent(%{agent_id: "01A", name: "alice", lease: 3600})
    seed_agent(%{agent_id: "01B", name: "bob", lease: -1})

    {:ok, _lv, html} = live(conn, "/agents")

    assert html =~ "alice"
    assert html =~ "bob"
    assert html =~ "bg-success"
    assert html =~ "bg-base-300"
  end

  test "scope-identity row shows 'you' badge", %{conn: conn} do
    seed_agent(%{agent_id: "01S", name: "scope-human", lease: 3600})
    seed_agent(%{agent_id: "01A", name: "alice", lease: 3600})

    {:ok, _lv, html} = live(conn, "/agents")

    {scope_row, alice_row} = {agent_row(html, "scope-human"), agent_row(html, "alice")}

    assert scope_row =~ "scope-human"
    assert scope_row =~ "badge-info"
    assert scope_row =~ ">you<"
    refute alice_row =~ ">you<"
  end

  defp agent_row(html, name) do
    case Regex.run(~r/<tr id="agent-#{Regex.escape(name)}".*?<\/tr>/s, html) do
      [match] -> match
      _ -> ""
    end
  end

  test "register modal opens and submit shells out with --name/--role but no --as",
       %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/agents")

    html = render_click(lv, "open-register", %{})
    assert html =~ "Register agent"

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _ = render_submit(lv, "register", %{
      "register" => %{
        "name" => "newbie",
        "harness" => "",
        "model" => "",
        "project" => "",
        "role" => "peer"
      }
    })

    args = LaliaStub.last_args()
    assert args == ~w[register --name newbie --role peer]
    refute "--as" in args
  end

  test "Suggest name button populates the name field from CLI output", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/agents")

    _ = render_click(lv, "open-register", %{})

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "curious-otter-42\n")

    html = render_click(lv, "suggest-name", %{})

    assert html =~ "curious-otter-42"
    args = LaliaStub.last_args()
    assert args == ~w[suggest-name]
  end

  test "Renew button calls `lalia renew`", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/agents")

    LaliaStub.clear_args()
    LaliaStub.set_response(out: "")

    _html = render_click(lv, "renew", %{})
    assert LaliaStub.last_args() == ~w[renew --as scope-human]
  end

  test "filtering by project narrows the list on refresh", %{conn: conn} do
    seed_agent(%{agent_id: "01A", name: "alice", project: "alpha", lease: 3600})
    seed_agent(%{agent_id: "01B", name: "bob", project: "beta", lease: 3600})

    {:ok, lv, _html} = live(conn, "/agents")

    _ =
      render_change(lv, "filter", %{
        "filter" => %{"project" => "alpha", "harness" => "", "role" => ""}
      })

    # Filter is applied on next load_agents (e.g. {:agents, _} broadcast).
    Phoenix.PubSub.broadcast(
      LaliaBema.Watcher.pubsub(),
      LaliaBema.Watcher.topic(),
      {:agents, :reconciled}
    )

    body = tbody_region(render(lv))
    assert body =~ ~s(agent-alice)
    refute body =~ ~s(agent-bob)
  end

  defp tbody_region(html) do
    case Regex.run(~r/<tbody id="agents">(.*?)<\/tbody>/s, html) do
      [_, inner] -> inner
      _ -> ""
    end
  end

  defp seed_agent(attrs) do
    lease_offset = Map.get(attrs, :lease, 3600)
    defaults = %{
      agent_id: "01X",
      name: "agent",
      branch: "main",
      harness: "claude",
      project: nil,
      lease_expires_at: DateTime.add(DateTime.utc_now(), lease_offset, :second)
    }

    {:ok, a} =
      Scope.upsert_agent(
        Map.merge(defaults, Map.drop(attrs, [:lease]))
        |> Map.put(
          :lease_expires_at,
          DateTime.add(DateTime.utc_now(), lease_offset, :second)
        )
      )

    a
  end
end
