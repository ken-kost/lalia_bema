defmodule LaliaBemaWeb.TasksLive do
  @moduledoc """
  Ash-backed task board at `/tasks`. Filters by status, project, and owner;
  subscribes to the Watcher PubSub topic so newly upserted tasks appear live.

  Phase 4 adds write actions: claim / set-status / unassign / reassign /
  unpublish / publish / handoff. All writes go through `LaliaBema.Lalia` so
  every mutation is signed by the scope identity.
  """
  use LaliaBemaWeb, :live_view

  require Ash.Query

  alias LaliaBema.Lalia
  alias LaliaBema.Scope
  alias LaliaBema.Watcher
  alias LaliaBemaWeb.RoomActions

  @statuses [:published, :claimed, :in_progress, :blocked, :ready, :merged]
  @settable_statuses ~w[in-progress ready blocked merged]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Watcher.pubsub(), Watcher.topic())

    socket =
      socket
      |> assign(page_title: "Tasks")
      |> assign(filters: %{"status" => "", "project" => "", "owner" => "", "mine" => false})
      |> assign(statuses: @statuses)
      |> assign(settable_statuses: @settable_statuses)
      |> assign(show_publish: false)
      |> assign(publish_payload: "")
      |> assign(publish_error: nil)
      |> assign(show_handoff: false)
      |> assign(handoff_target: "")
      |> assign(confirm_unpublish: nil)
      |> assign(unpublish_flags: %{"force" => false, "wipe_worktree" => false, "evict_owner" => false})
      |> assign(action_throttle: %{})
      |> load_all()
      |> load_agents()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters =
      socket.assigns.filters
      |> Map.merge(filters)
      |> Map.update("mine", false, fn
        "true" -> true
        true -> true
        _ -> false
      end)

    {:noreply, socket |> assign(:filters, filters) |> load_tasks()}
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     socket
     |> assign(:filters, %{"status" => "", "project" => "", "owner" => "", "mine" => false})
     |> load_tasks()}
  end

  def handle_event("claim", %{"slug" => slug}, socket) do
    RoomActions.call(socket, :task_claim, "Claimed #{slug}.", fn ->
      Lalia.task_claim(slug)
    end)
  end

  def handle_event("set-status", %{"slug" => slug, "status" => status}, socket) do
    RoomActions.call(socket, :task_set_status, "Status → #{status}.", fn ->
      Lalia.task_set_status(slug, status)
    end)
  end

  def handle_event("unassign", %{"slug" => slug}, socket) do
    RoomActions.call(socket, :task_unassign, "Unassigned #{slug}.", fn ->
      Lalia.task_unassign(slug)
    end)
  end

  def handle_event("reassign", %{"slug" => slug, "agent" => agent}, socket) do
    agent = String.trim(agent || "")

    if agent == "" do
      {:noreply, put_flash(socket, :error, "Reassign target is empty.")}
    else
      RoomActions.call(socket, :task_reassign, "Reassigned #{slug} to #{agent}.", fn ->
        Lalia.task_reassign(slug, agent)
      end)
    end
  end

  def handle_event("confirm-unpublish", %{"slug" => slug}, socket) do
    {:noreply, assign(socket, :confirm_unpublish, slug)}
  end

  def handle_event("cancel-unpublish", _params, socket) do
    {:noreply, assign(socket, :confirm_unpublish, nil)}
  end

  def handle_event("unpublish-flag", %{"flag" => flag, "value" => value}, socket) do
    flags = Map.put(socket.assigns.unpublish_flags, flag, value in ["true", true])
    {:noreply, assign(socket, :unpublish_flags, flags)}
  end

  def handle_event("unpublish", %{"slug" => slug}, socket) do
    flags = socket.assigns.unpublish_flags

    opts =
      [force: flags["force"], wipe_worktree: flags["wipe_worktree"], evict_owner: flags["evict_owner"]]
      |> Enum.reject(fn {_k, v} -> not v end)

    socket = assign(socket, :confirm_unpublish, nil)

    RoomActions.call(socket, :task_unpublish, "Unpublished #{slug}.", fn ->
      Lalia.task_unpublish(slug, opts)
    end)
  end

  def handle_event("open-publish", _params, socket),
    do: {:noreply, assign(socket, :show_publish, true)}

  def handle_event("close-publish", _params, socket),
    do: {:noreply, assign(socket, show_publish: false, publish_error: nil)}

  def handle_event("publish-change", %{"payload" => payload}, socket) do
    {:noreply, assign(socket, :publish_payload, payload)}
  end

  def handle_event("publish", %{"payload" => payload}, socket) do
    case Jason.decode(payload) do
      {:ok, _} ->
        case Lalia.task_publish(payload) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(show_publish: false, publish_payload: "", publish_error: nil)
             |> put_flash(:info, "Task published.")}

          other ->
            RoomActions.result_to_flash(other, socket)
        end

      {:error, _err} ->
        {:noreply, assign(socket, :publish_error, "Invalid JSON.")}
    end
  end

  def handle_event("open-handoff", _params, socket),
    do: {:noreply, assign(socket, :show_handoff, true)}

  def handle_event("close-handoff", _params, socket),
    do: {:noreply, assign(socket, show_handoff: false, handoff_target: "")}

  def handle_event("handoff-change", %{"target" => target}, socket),
    do: {:noreply, assign(socket, :handoff_target, target)}

  def handle_event("handoff", %{"target" => target}, socket) do
    target = String.trim(target)

    if target == "" do
      {:noreply, put_flash(socket, :error, "Handoff target is empty.")}
    else
      RoomActions.call(socket, :task_handoff, "Handed off to #{target}.", fn ->
        Lalia.task_handoff(target)
      end)
      |> close_handoff()
    end
  end

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  @impl true
  def handle_info({:tasks, _}, socket), do: {:noreply, load_all(socket)}
  def handle_info({:new_message, _}, socket), do: {:noreply, socket}
  def handle_info({:agents, _}, socket), do: {:noreply, load_agents(socket)}
  def handle_info({:identity, _}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  defp close_handoff({:noreply, socket}),
    do: {:noreply, assign(socket, show_handoff: false, handoff_target: "")}

  defp load_all(socket) do
    all = Scope.list_tasks!()

    socket
    |> assign(:all_tasks, all)
    |> assign(:projects, distinct(all, :project))
    |> assign(:owners, distinct(all, :owner))
    |> load_tasks()
  end

  defp load_agents(socket) do
    agents = Scope.list_agents!(query: [sort: [name: :asc]])
    assign(socket, :agents, agents)
  end

  defp load_tasks(socket) do
    filters = socket.assigns.filters
    scope = LaliaBema.scope_identity()

    query =
      Scope.Task
      |> Ash.Query.sort(updated_at: :desc)

    query =
      case filters["status"] do
        "" -> query
        nil -> query
        status -> Ash.Query.filter(query, status == ^String.to_existing_atom(status))
      end

    query =
      case filters["project"] do
        blank when blank in [nil, ""] -> query
        project -> Ash.Query.filter(query, project == ^project)
      end

    query =
      case filters["owner"] do
        blank when blank in [nil, ""] -> query
        owner -> Ash.Query.filter(query, owner == ^owner)
      end

    query =
      if filters["mine"] and is_binary(scope) do
        Ash.Query.filter(query, owner == ^scope)
      else
        query
      end

    assign(socket, :tasks, Ash.read!(query))
  end

  defp distinct(list, key) do
    list
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:scope_identity, fn -> LaliaBema.scope_identity() end)

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Tasks
        <:subtitle>
          {length(@tasks)} task{if length(@tasks) == 1, do: "", else: "s"} matching ·
          {length(@all_tasks)} total
        </:subtitle>
        <:actions>
          <button type="button" phx-click="open-publish" class="btn btn-sm btn-primary" id="publish-btn">
            Publish task
          </button>
          <button type="button" phx-click="open-handoff" class="btn btn-sm" id="handoff-btn">
            Handoff supervisor
          </button>
        </:actions>
      </.header>

      <div :if={@show_publish} id="publish-modal" class="rounded-box border border-primary/40 bg-primary/10 p-4 mb-4">
        <h3 class="font-semibold mb-2">Publish task from JSON</h3>
        <form phx-change="publish-change" phx-submit="publish" class="space-y-2">
          <textarea
            name="payload"
            rows="8"
            class="textarea textarea-bordered w-full font-mono text-xs"
            placeholder={~s|{"slug": "demo", "title": "Demo", ...}|}
          ><%= @publish_payload %></textarea>
          <p :if={@publish_error} class="text-xs text-error">{@publish_error}</p>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="close-publish" class="btn btn-sm btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-sm btn-primary">Publish</button>
          </div>
        </form>
      </div>

      <div :if={@show_handoff} id="handoff-modal" class="rounded-box border border-warning/40 bg-warning/10 p-4 mb-4">
        <h3 class="font-semibold mb-2">Handoff supervisor</h3>
        <form phx-change="handoff-change" phx-submit="handoff" class="flex items-center gap-2">
          <input type="text" name="target" value={@handoff_target} placeholder="new-supervisor" class="input input-sm input-bordered flex-1" />
          <button type="submit" class="btn btn-sm btn-warning">Handoff</button>
          <button type="button" phx-click="close-handoff" class="btn btn-sm btn-ghost">Cancel</button>
        </form>
      </div>

      <div :if={@confirm_unpublish} id="unpublish-modal" class="rounded-box border border-error/40 bg-error/10 p-4 mb-4">
        <h3 class="font-semibold mb-2">Unpublish {@confirm_unpublish}?</h3>
        <div class="flex flex-wrap gap-3 mb-2 text-sm">
          <label class="flex items-center gap-1">
            <input type="checkbox" phx-click="unpublish-flag" phx-value-flag="force"
                   phx-value-value={!@unpublish_flags["force"]}
                   checked={@unpublish_flags["force"]} class="checkbox checkbox-sm" />
            --force
          </label>
          <label class="flex items-center gap-1">
            <input type="checkbox" phx-click="unpublish-flag" phx-value-flag="wipe_worktree"
                   phx-value-value={!@unpublish_flags["wipe_worktree"]}
                   checked={@unpublish_flags["wipe_worktree"]} class="checkbox checkbox-sm" />
            --wipe-worktree
          </label>
          <label class="flex items-center gap-1">
            <input type="checkbox" phx-click="unpublish-flag" phx-value-flag="evict_owner"
                   phx-value-value={!@unpublish_flags["evict_owner"]}
                   checked={@unpublish_flags["evict_owner"]} class="checkbox checkbox-sm" />
            --evict-owner
          </label>
        </div>
        <div class="flex gap-2 justify-end">
          <button type="button" phx-click="cancel-unpublish" class="btn btn-sm btn-ghost">Cancel</button>
          <button type="button" phx-click="unpublish" phx-value-slug={@confirm_unpublish} class="btn btn-sm btn-error">
            Unpublish
          </button>
        </div>
      </div>

      <form phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4" id="task-filters">
        <label class="form-control">
          <span class="label label-text">Status</span>
          <select name="filters[status]" class="select select-sm select-bordered">
            <option value="">All</option>
            <option :for={s <- @statuses} value={Atom.to_string(s)} selected={@filters["status"] == Atom.to_string(s)}>
              {s}
            </option>
          </select>
        </label>

        <label class="form-control">
          <span class="label label-text">Project</span>
          <select name="filters[project]" class="select select-sm select-bordered">
            <option value="">All</option>
            <option :for={p <- @projects} value={p} selected={@filters["project"] == p}>{p}</option>
          </select>
        </label>

        <label class="form-control">
          <span class="label label-text">Owner</span>
          <select name="filters[owner]" class="select select-sm select-bordered">
            <option value="">All</option>
            <option :for={o <- @owners} value={o} selected={@filters["owner"] == o}>{o}</option>
          </select>
        </label>

        <label class="form-control flex-row items-center gap-1">
          <input type="checkbox" name="filters[mine]" value="true" checked={@filters["mine"]} class="checkbox checkbox-sm" />
          <span class="label-text text-sm">Mine</span>
        </label>

        <button type="button" phx-click="reset" class="btn btn-sm btn-ghost">Reset</button>
      </form>

      <div :if={@tasks == []} id="tasks-empty" class="text-sm text-base-content/60 italic">
        No tasks match the current filters.
      </div>

      <div :if={@tasks != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Slug</th>
              <th>Title</th>
              <th>Status</th>
              <th>Owner</th>
              <th>Project</th>
              <th>Last change</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody id="tasks">
            <tr :for={t <- @tasks} id={"task-#{t.slug}"}>
              <td>
                <.link navigate={~p"/rooms/#{t.slug}"} class="font-mono text-primary hover:underline">
                  {t.slug}
                </.link>
              </td>
              <td>{t.title}</td>
              <td><.status_badge status={t.status} /></td>
              <td>{t.owner || "—"}</td>
              <td>{t.project || "—"}</td>
              <td class="font-mono text-xs">{format_ts(t.updated_at)}</td>
              <td class="text-right">
                <.row_actions task={t} settable_statuses={@settable_statuses} agents={@agents} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  attr :task, :any, required: true
  attr :settable_statuses, :list, required: true
  attr :agents, :list, required: true

  defp row_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1 justify-end">
      <button
        :if={is_nil(@task.owner)}
        type="button"
        phx-click="claim"
        phx-value-slug={@task.slug}
        class="btn btn-xs"
      >
        Claim
      </button>

      <form phx-submit="set-status" class="inline-flex">
        <input type="hidden" name="slug" value={@task.slug} />
        <select name="status" class="select select-xs select-bordered">
          <option :for={s <- @settable_statuses} value={s}>{s}</option>
        </select>
        <button type="submit" class="btn btn-xs">set</button>
      </form>

      <button
        :if={not is_nil(@task.owner)}
        type="button"
        phx-click="unassign"
        phx-value-slug={@task.slug}
        data-confirm="Unassign this task?"
        class="btn btn-xs btn-ghost"
      >
        Unassign
      </button>

      <form phx-submit="reassign" class="inline-flex">
        <input type="hidden" name="slug" value={@task.slug} />
        <select name="agent" class="select select-xs select-bordered">
          <option value="" disabled selected>reassign…</option>
          <option :for={a <- @agents} value={a.name}>{a.name}</option>
        </select>
        <button type="submit" class="btn btn-xs">go</button>
      </form>

      <button type="button" phx-click="confirm-unpublish" phx-value-slug={@task.slug} class="btn btn-xs btn-error">
        Unpublish
      </button>
    </div>
    """
  end

  attr :status, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", badge_class(@status)]}>{@status}</span>
    """
  end

  defp badge_class(:published), do: "badge-ghost"
  defp badge_class(:claimed), do: "badge-info"
  defp badge_class(:in_progress), do: "badge-warning"
  defp badge_class(:blocked), do: "badge-error"
  defp badge_class(:ready), do: "badge-success"
  defp badge_class(:merged), do: "badge-primary"
  defp badge_class(_), do: "badge-ghost"

  defp format_ts(nil), do: ""
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_ts(_), do: ""
end
