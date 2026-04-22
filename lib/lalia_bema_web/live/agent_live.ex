defmodule LaliaBemaWeb.AgentLive do
  @moduledoc """
  Per-agent drill-down at `/agents/:name`. Shows header metadata, the rooms
  and peer channels they're in, their 50 most recent messages, and a
  composer for tell / ask back.
  """
  use LaliaBemaWeb, :live_view

  require Ash.Query

  alias LaliaBema.Lalia
  alias LaliaBema.Scope
  alias LaliaBema.Watcher
  alias LaliaBemaWeb.RoomActions

  @recent_cap 50

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Watcher.pubsub(), Watcher.topic())

    socket =
      socket
      |> assign(page_title: name)
      |> assign(agent_name: name)
      |> assign(composer: "")
      |> assign(compose_mode: "tell")
      |> assign(ask_timeout: 30)
      |> assign(ask_reply: nil)
      |> assign(peek: nil)
      |> assign(confirm_consume: false)
      |> assign(action_throttle: %{})
      |> load_agent()
      |> load_activity()

    {:ok, socket}
  end

  @impl true
  def handle_event("compose-change", %{"body" => body} = params, socket) do
    mode = Map.get(params, "mode", socket.assigns.compose_mode)
    timeout = params |> Map.get("timeout", "30") |> to_int(30)

    {:noreply,
     socket
     |> assign(:composer, body)
     |> assign(:compose_mode, mode)
     |> assign(:ask_timeout, timeout)}
  end

  def handle_event("send", params, socket) do
    body = params |> Map.get("body", "") |> String.trim()
    mode = Map.get(params, "mode", socket.assigns.compose_mode)
    timeout = params |> Map.get("timeout", "30") |> to_int(30)
    peer = socket.assigns.agent_name

    if body == "" do
      {:noreply, put_flash(socket, :error, "Message body is empty.")}
    else
      case mode do
        "tell" ->
          RoomActions.call(socket, :tell, "Told #{peer}.", fn ->
            Lalia.tell(peer, body)
          end)
          |> clear_composer()

        "ask" ->
          case Lalia.ask(peer, body, timeout: timeout) do
            {:ok, out} ->
              {:noreply,
               socket
               |> put_flash(:info, "Ask sent, awaiting reply…")
               |> assign(:ask_reply, String.trim(out))
               |> assign(:composer, "")}

            other ->
              RoomActions.result_to_flash(other, socket)
          end
      end
    end
  end

  def handle_event("peek", _params, socket) do
    case Lalia.peek(socket.assigns.agent_name) do
      {:ok, peek} -> {:noreply, assign(socket, :peek, peek)}
      other -> RoomActions.result_to_flash(other, socket)
    end
  end

  def handle_event("confirm-consume", _params, socket) do
    {:noreply, assign(socket, :confirm_consume, true)}
  end

  def handle_event("cancel-consume", _params, socket) do
    {:noreply, assign(socket, :confirm_consume, false)}
  end

  def handle_event("consume", _params, socket) do
    socket = assign(socket, :confirm_consume, false)

    RoomActions.call(socket, :consume, "Consumed next message.", fn ->
      Lalia.read(socket.assigns.agent_name, timeout: 0)
    end)
  end

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  @impl true
  def handle_info({:new_message, %{from: from}}, socket)
      when from == socket.assigns.agent_name do
    {:noreply, load_activity(socket)}
  end

  def handle_info({:agents, _}, socket), do: {:noreply, load_agent(socket)}
  def handle_info({:identity, _}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load_agent(socket) do
    name = socket.assigns.agent_name

    agent =
      case Scope.list_agents!(query: [filter: [name: name]], load: [:active?]) do
        [a | _] -> a
        [] -> nil
      end

    assign(socket, :agent, agent)
  end

  defp load_activity(socket) do
    name = socket.assigns.agent_name

    msgs =
      Scope.Message
      |> Ash.Query.filter(from == ^name)
      |> Ash.Query.sort(posted_at: :desc, seq: :desc)
      |> Ash.Query.limit(@recent_cap)
      |> Ash.read!()

    all_for_agent =
      Scope.Message
      |> Ash.Query.filter(from == ^name)
      |> Ash.Query.select([:kind, :target])
      |> Ash.read!()

    rooms =
      all_for_agent
      |> Enum.filter(&(&1.kind == :room))
      |> Enum.map(& &1.target)
      |> Enum.uniq()
      |> Enum.sort()

    channels =
      all_for_agent
      |> Enum.filter(&(&1.kind == :channel))
      |> Enum.map(& &1.target)
      |> Enum.uniq()
      |> Enum.sort()

    socket
    |> assign(:messages, msgs)
    |> assign(:rooms, rooms)
    |> assign(:channels, channels)
    |> assign(:total_messages, length(all_for_agent))
  end

  defp clear_composer({:noreply, socket}) do
    {:noreply, assign(socket, :composer, "")}
  end

  defp to_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(val, _) when is_integer(val), do: val
  defp to_int(_, default), do: default

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:scope_identity, fn -> LaliaBema.scope_identity() end)
      |> assign_new(:self?, fn -> assigns.agent_name == LaliaBema.scope_identity() end)

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@agent_name}
        <:subtitle>
          <%= cond do %>
            <% @agent -> %>
              <span class={[
                "badge badge-sm",
                if(@agent.active?, do: "badge-success", else: "badge-ghost")
              ]}>
                {if @agent.active?, do: "active", else: "expired"}
              </span>
              · {@total_messages} message{if @total_messages == 1, do: "", else: "s"}
              <span :if={@self?} class="ml-2 badge badge-info badge-sm">acting as this agent</span>
            <% true -> %>
              <span class="text-warning">Agent not registered; showing activity only.</span>
          <% end %>
        </:subtitle>
        <:actions>
          <button type="button" phx-click="peek" class="btn btn-sm" id="peek-channel">
            Peek
          </button>
          <button type="button" phx-click="confirm-consume" class="btn btn-sm btn-warning" id="consume-channel">
            Consume
          </button>
        </:actions>
      </.header>

      <div :if={@confirm_consume} id="confirm-consume" class="alert alert-warning mb-4">
        <span>Consuming will remove the next message from the mailbox.</span>
        <div class="flex gap-2">
          <button type="button" phx-click="consume" class="btn btn-sm btn-error">Yes</button>
          <button type="button" phx-click="cancel-consume" class="btn btn-sm">Cancel</button>
        </div>
      </div>

      <div :if={@peek} id="peek-panel" class="rounded-box border border-info/40 bg-info/10 p-3 mb-4">
        <strong>Mailbox peek</strong>
        <pre class="text-xs font-mono whitespace-pre-wrap">{@peek.raw}</pre>
      </div>

      <div :if={@ask_reply} id="ask-reply" class="rounded-box border border-success/40 bg-success/10 p-3 mb-4">
        <strong>Ask reply</strong>
        <pre class="text-xs font-mono whitespace-pre-wrap">{@ask_reply}</pre>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <section class="lg:col-span-1 rounded-box border border-base-300 p-4 space-y-2" id="agent-meta">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
            Metadata
          </h2>
          <dl :if={@agent} class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
            <dt class="text-base-content/60">Project</dt>
            <dd>{@agent.project || "—"}</dd>
            <dt class="text-base-content/60">Branch</dt>
            <dd class="font-mono">{@agent.branch || "—"}</dd>
            <dt class="text-base-content/60">Harness</dt>
            <dd>{@agent.harness || "—"}</dd>
            <dt class="text-base-content/60">Last seen</dt>
            <dd class="font-mono text-xs">{format_ts(@agent.last_seen_at)}</dd>
            <dt class="text-base-content/60">Lease</dt>
            <dd class="font-mono text-xs">{format_ts(@agent.lease_expires_at)}</dd>
          </dl>
          <p :if={is_nil(@agent)} class="text-sm text-base-content/50">
            No registry entry for this agent.
          </p>
        </section>

        <section class="lg:col-span-1 rounded-box border border-base-300 p-4 space-y-2" id="agent-rooms">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
            Rooms <span class="text-base-content/50">({length(@rooms)})</span>
          </h2>
          <ul :if={@rooms != []} class="space-y-1 text-sm">
            <li :for={r <- @rooms}>
              <.link navigate={~p"/rooms/#{r}"} class="hover:underline">#{r}</.link>
            </li>
          </ul>
          <p :if={@rooms == []} class="text-sm text-base-content/50">Not in any rooms.</p>

          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70 pt-3">
            Channels <span class="text-base-content/50">({length(@channels)})</span>
          </h2>
          <ul :if={@channels != []} id="agent-channels" class="space-y-1 text-sm">
            <li :for={c <- @channels}>
              <.link navigate={~p"/history/channel/#{c}"} class="font-mono hover:underline">{c}</.link>
            </li>
          </ul>
          <p :if={@channels == []} class="text-sm text-base-content/50">No peer channels.</p>
        </section>

        <section class="lg:col-span-1 rounded-box border border-base-300 p-4 space-y-2" id="agent-recent">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
            Recent messages <span class="text-base-content/50">({length(@messages)})</span>
          </h2>
          <ul :if={@messages != []} class="space-y-3">
            <li
              :for={m <- @messages}
              id={"agent-msg-#{m.id}"}
              class="border-l-2 border-primary/30 pl-3"
            >
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <.link
                  navigate={~p"/history/#{kind_slug(m.kind)}/#{m.target}"}
                  class="font-mono hover:underline"
                >
                  {kind_slug(m.kind)}/{m.target}
                </.link>
                <span class="ml-auto font-mono">{format_ts(m.posted_at)}</span>
              </div>
              <p class="mt-1 text-sm whitespace-pre-wrap break-words">{m.body}</p>
            </li>
          </ul>
          <p :if={@messages == []} class="text-sm text-base-content/50">
            No messages from this agent.
          </p>
        </section>
      </div>

      <form
        phx-change="compose-change"
        phx-submit="send"
        class="rounded-box border border-base-300 p-3 mt-6"
        id="agent-composer"
      >
        <div class="flex items-center gap-3 mb-2">
          <label class="text-xs uppercase tracking-wide text-base-content/60">
            As <code class="font-mono">{@scope_identity || "no-identity"}</code> →
            <span class="font-mono">{@agent_name}</span>
          </label>
          <label class="flex items-center gap-1 text-sm">
            <input type="radio" name="mode" value="tell" checked={@compose_mode == "tell"} class="radio radio-sm" /> Tell
          </label>
          <label class="flex items-center gap-1 text-sm">
            <input type="radio" name="mode" value="ask" checked={@compose_mode == "ask"} class="radio radio-sm" /> Ask
          </label>
          <label :if={@compose_mode == "ask"} class="flex items-center gap-1 text-sm">
            timeout
            <input type="number" name="timeout" value={@ask_timeout} min="0" max="600" class="input input-xs input-bordered w-16" />
            s
          </label>
        </div>
        <textarea
          name="body"
          rows="3"
          class="textarea textarea-bordered w-full font-mono text-sm"
          placeholder="Message body (Ctrl+Enter to send, Esc to clear)"
        ><%= @composer %></textarea>
        <div class="flex items-center justify-between mt-2">
          <span :if={String.length(@composer) > 500} class="text-xs text-warning">
            {String.length(@composer)} chars
          </span>
          <span :if={String.length(@composer) <= 500} class="text-xs text-base-content/40"></span>
          <button type="submit" class="btn btn-sm btn-primary">
            {if @compose_mode == "ask", do: "Ask", else: "Tell"}
          </button>
        </div>
      </form>
    </Layouts.app>
    """
  end

  defp kind_slug(:room), do: "room"
  defp kind_slug(:channel), do: "channel"
  defp kind_slug(_), do: "room"

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_ts(_), do: "—"
end
