defmodule LaliaBemaWeb.AgentsLive do
  @moduledoc """
  `/agents` — agents index with register / unregister / renew / nickname
  management.
  """
  use LaliaBemaWeb, :live_view

  alias LaliaBema.Lalia
  alias LaliaBema.Scope
  alias LaliaBema.Watcher
  alias LaliaBemaWeb.RoomActions

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Watcher.pubsub(), Watcher.topic())

    socket =
      socket
      |> assign(page_title: "Agents")
      |> assign(filter: %{"project" => "", "harness" => "", "role" => ""})
      |> assign(show_register: false)
      |> assign(register_form: %{"name" => "", "harness" => "", "model" => "", "project" => "", "role" => "peer"})
      |> assign(nickname_edits: %{})
      |> assign(action_throttle: %{})
      |> load_agents()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter = Map.merge(socket.assigns.filter, filter)

    {:noreply,
     socket
     |> assign(:filter, filter)
     |> load_agents()}
  end

  def handle_event("open-register", _params, socket) do
    {:noreply,
     assign(socket, :show_register, true)
     |> assign(:register_form, %{"name" => "", "harness" => "", "model" => "", "project" => "", "role" => "peer"})}
  end

  def handle_event("close-register", _params, socket),
    do: {:noreply, assign(socket, :show_register, false)}

  def handle_event("register-change", %{"register" => form}, socket) do
    {:noreply, assign(socket, :register_form, Map.merge(socket.assigns.register_form, form))}
  end

  def handle_event("suggest-name", _params, socket) do
    harness = socket.assigns.register_form["harness"]
    opts = if harness not in [nil, ""], do: [harness: harness], else: []

    case Lalia.suggest_name(opts) do
      {:ok, name} ->
        form = Map.put(socket.assigns.register_form, "name", name)
        {:noreply, assign(socket, :register_form, form)}

      other ->
        RoomActions.result_to_flash(other, socket)
    end
  end

  def handle_event("register", %{"register" => form}, socket) do
    opts =
      [name: form["name"], harness: form["harness"], model: form["model"], project: form["project"], role: form["role"]]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    RoomActions.call(socket, :register, "Registered.", fn ->
      Lalia.register(opts)
    end)
    |> close_register()
  end

  def handle_event("unregister", _params, socket) do
    RoomActions.call(socket, :unregister, "Unregistered.", fn ->
      Lalia.unregister()
    end)
  end

  def handle_event("renew", _params, socket) do
    RoomActions.call(socket, :renew, "Lease renewed.", fn -> Lalia.renew() end)
  end

  def handle_event("nickname-edit", %{"agent" => name, "value" => value}, socket) do
    {:noreply, assign(socket, :nickname_edits, Map.put(socket.assigns.nickname_edits, name, value))}
  end

  def handle_event("nickname-save", %{"agent" => name} = params, socket) do
    value = Map.get(socket.assigns.nickname_edits, name) || Map.get(params, "value", "")
    follow? = Map.get(params, "follow") == "true"

    if value == "" do
      case Lalia.nickname_delete(name) do
        {:ok, _} -> {:noreply, put_flash(socket, :info, "Nickname cleared.")}
        other -> RoomActions.result_to_flash(other, socket)
      end
    else
      case Lalia.nickname_set(name, value, follow: follow?) do
        {:ok, _} -> {:noreply, put_flash(socket, :info, "Nickname set.")}
        other -> RoomActions.result_to_flash(other, socket)
      end
    end
  end

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  @impl true
  def handle_info({:agents, _}, socket), do: {:noreply, load_agents(socket)}
  def handle_info({:identity, _}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  defp close_register({:noreply, socket}), do: {:noreply, assign(socket, :show_register, false)}

  defp load_agents(socket) do
    agents = Scope.list_agents!(query: [sort: [name: :asc]], load: [:active?])
    filtered = apply_filter(agents, socket.assigns.filter)

    socket
    |> assign(:agents, filtered)
    |> assign(:total_agents, length(agents))
    |> assign(:projects, distinct(agents, :project))
    |> assign(:harnesses, distinct(agents, :harness))
  end

  defp apply_filter(agents, filter) do
    Enum.filter(agents, fn a ->
      (filter["project"] in [nil, ""] or a.project == filter["project"]) and
        (filter["harness"] in [nil, ""] or a.harness == filter["harness"])
    end)
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
      |> assign_new(:identity_state, fn -> LaliaBema.identity_state() end)

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Agents
        <:subtitle>
          {length(@agents)} of {@total_agents} ·
          acting as <code class="font-mono">{@scope_identity || "no-identity"}</code>
        </:subtitle>
        <:actions>
          <button :if={@scope_identity} type="button" phx-click="renew" class="btn btn-sm" id="renew-btn">
            Renew lease
          </button>
          <button :if={@scope_identity} type="button" phx-click="unregister" class="btn btn-sm btn-warning" id="unregister-btn"
                  data-confirm="Unregister the scope identity?">
            Unregister
          </button>
          <button type="button" phx-click="open-register" class="btn btn-sm btn-primary" id="open-register">
            Register…
          </button>
        </:actions>
      </.header>

      <div :if={@identity_state != :registered} id="identity-banner" class="alert alert-warning mb-4">
        Scope identity <code class="font-mono">{@scope_identity || "scope-human"}</code>
        is not registered. Writes will fail until it is.
      </div>

      <div :if={@show_register} id="register-modal" class="rounded-box border border-primary/40 bg-primary/10 p-4 mb-4">
        <h3 class="font-semibold mb-2">Register agent</h3>
        <form phx-change="register-change" phx-submit="register" class="grid grid-cols-2 gap-2">
          <label class="form-control">
            <span class="label-text text-xs">Name</span>
            <div class="flex gap-1">
              <input type="text" name="register[name]" value={@register_form["name"]} class="input input-sm input-bordered flex-1" />
              <button type="button" phx-click="suggest-name" class="btn btn-sm">Suggest</button>
            </div>
          </label>
          <label class="form-control">
            <span class="label-text text-xs">Harness</span>
            <input type="text" name="register[harness]" value={@register_form["harness"]} class="input input-sm input-bordered" />
          </label>
          <label class="form-control">
            <span class="label-text text-xs">Model</span>
            <input type="text" name="register[model]" value={@register_form["model"]} class="input input-sm input-bordered" />
          </label>
          <label class="form-control">
            <span class="label-text text-xs">Project</span>
            <input type="text" name="register[project]" value={@register_form["project"]} class="input input-sm input-bordered" />
          </label>
          <label class="form-control">
            <span class="label-text text-xs">Role</span>
            <select name="register[role]" class="select select-sm select-bordered">
              <option value="peer" selected={@register_form["role"] == "peer"}>peer</option>
              <option value="supervisor" selected={@register_form["role"] == "supervisor"}>supervisor</option>
              <option value="worker" selected={@register_form["role"] == "worker"}>worker</option>
            </select>
          </label>
          <div class="col-span-2 flex justify-end gap-2">
            <button type="button" phx-click="close-register" class="btn btn-sm btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-sm btn-primary">Register</button>
          </div>
        </form>
      </div>

      <form phx-change="filter" class="flex flex-wrap items-end gap-3 mb-4" id="agent-filters">
        <label class="form-control">
          <span class="label label-text">Project</span>
          <select name="filter[project]" class="select select-sm select-bordered">
            <option value="">All</option>
            <option :for={p <- @projects} value={p} selected={@filter["project"] == p}>{p}</option>
          </select>
        </label>
        <label class="form-control">
          <span class="label label-text">Harness</span>
          <select name="filter[harness]" class="select select-sm select-bordered">
            <option value="">All</option>
            <option :for={h <- @harnesses} value={h} selected={@filter["harness"] == h}>{h}</option>
          </select>
        </label>
      </form>

      <div :if={@agents == []} id="agents-empty" class="text-sm text-base-content/60 italic">
        No agents match.
      </div>

      <div :if={@agents != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th></th>
              <th>Name</th>
              <th>Project</th>
              <th>Harness</th>
              <th>Branch</th>
              <th>Lease</th>
              <th>Nickname</th>
            </tr>
          </thead>
          <tbody id="agents">
            <tr :for={a <- @agents} id={"agent-#{a.name}"}>
              <td>
                <span class={[
                  "inline-block size-2 rounded-full",
                  if(a.active?, do: "bg-success", else: "bg-base-300")
                ]} />
              </td>
              <td>
                <.link navigate={~p"/agents/#{a.name}"} class="font-mono hover:underline">
                  {a.name}
                </.link>
                <span :if={a.name == @scope_identity} class="ml-1 badge badge-xs badge-info">you</span>
              </td>
              <td>{a.project || "—"}</td>
              <td>{a.harness || "—"}</td>
              <td class="font-mono text-xs">{a.branch || "—"}</td>
              <td class="font-mono text-xs">{format_ts(a.lease_expires_at)}</td>
              <td>
                <form phx-submit="nickname-save" class="flex items-center gap-1">
                  <input type="hidden" name="agent" value={a.name} />
                  <input
                    type="text"
                    name="value"
                    value={Map.get(@nickname_edits, a.name, "")}
                    phx-change="nickname-edit"
                    phx-value-agent={a.name}
                    placeholder="nickname"
                    class="input input-xs input-bordered w-24"
                  />
                  <label class="text-xs flex items-center gap-1">
                    <input type="checkbox" name="follow" value="true" class="checkbox checkbox-xs" /> follow
                  </label>
                  <button type="submit" class="btn btn-xs">Save</button>
                </form>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_ts(_), do: "—"
end
