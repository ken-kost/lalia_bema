defmodule LaliaBemaWeb.FeedLive do
  @moduledoc """
  Phase 2 observer: three panels (agents, rooms, live stream) backed by the
  Ash `LaliaBema.Scope` domain. Structural changes and new messages are
  delivered via `Phoenix.PubSub`; on each broadcast we re-read from Ash so
  the view stays consistent with the durable store.
  """
  use LaliaBemaWeb, :live_view

  alias LaliaBema.Scope
  alias LaliaBema.Watcher

  @stream_limit 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Watcher.pubsub(), Watcher.topic())
    end

    agents = load_agents()
    rooms = load_rooms()
    messages = load_recent_messages()

    socket =
      socket
      |> assign(agents: agents, rooms: rooms, count: length(messages))
      |> stream_configure(:messages, dom_id: &"msg-#{&1.id}")
      |> stream(:messages, messages, limit: @stream_limit)

    {:ok, socket}
  end

  @impl true
  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  @impl true
  def handle_info({:new_message, %{kind: kind, target: target, seq: seq, from: from}}, socket) do
    case Scope.list_messages!(
           query: [filter: [kind: kind, target: target, seq: seq, from: from]]
         ) do
      [msg | _] ->
        socket =
          socket
          |> stream_insert(:messages, msg, at: 0, limit: @stream_limit)
          |> update(:count, &(&1 + 1))

        {:noreply, socket}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_info({:agents, _}, socket) do
    {:noreply, assign(socket, :agents, load_agents())}
  end

  def handle_info({:rooms, _}, socket) do
    {:noreply, assign(socket, :rooms, load_rooms())}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_agents do
    Scope.list_agents!(query: [sort: [name: :asc]], load: [:active?])
  end

  defp load_rooms do
    Scope.list_rooms!(query: [sort: [name: :asc]])
  end

  defp load_recent_messages do
    Scope.list_messages!(
      query: [sort: [posted_at: :desc, seq: :desc], limit: @stream_limit]
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Feed
        <:subtitle>
          Live feed from the Lalia workspace · {@count} message{if @count == 1, do: "", else: "s"} seen
        </:subtitle>
      </.header>

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-4">
        <section class="lg:col-span-1 rounded-box border border-base-300 p-4">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70 mb-3">
            Agents <span class="text-base-content/50">({length(@agents)})</span>
          </h2>
          <ul class="space-y-2">
            <li :if={@agents == []} class="text-sm text-base-content/50">No agents registered.</li>
            <li :for={a <- @agents} class="text-sm">
              <div class="flex items-center gap-2">
                <span class={[
                  "size-2 rounded-full",
                  if(a.active?, do: "bg-success", else: "bg-base-300")
                ]} />
                <.link navigate={~p"/agents/#{a.name}"} class="font-medium hover:underline">
                  {a.name}
                </.link>
              </div>
              <div class="ml-4 text-xs text-base-content/60">
                {format_agent_line(a)}
              </div>
            </li>
          </ul>
        </section>

        <section class="lg:col-span-1 rounded-box border border-base-300 p-4">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70 mb-3">
            Rooms <span class="text-base-content/50">({length(@rooms)})</span>
          </h2>
          <ul class="space-y-2">
            <li :if={@rooms == []} class="text-sm text-base-content/50">No rooms yet.</li>
            <li :for={r <- @rooms} class="text-sm">
              <div class="font-medium">
                <.link navigate={~p"/rooms/#{r.name}"} class="hover:underline">#{r.name}</.link>
              </div>
              <div class="text-xs text-base-content/60">
                {r.member_count} member{if r.member_count == 1, do: "", else: "s"}{if r.description, do: " · #{r.description}", else: ""}
              </div>
            </li>
          </ul>
        </section>

        <section class="lg:col-span-2 rounded-box border border-base-300 p-4">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70 mb-3">
            Live stream
          </h2>
          <ul id="messages" phx-update="stream" class="space-y-3">
            <li
              :for={{dom_id, msg} <- @streams.messages}
              id={dom_id}
              class="border-l-2 border-primary/30 pl-3"
            >
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <.link
                  navigate={~p"/history/#{kind_slug(msg.kind)}/#{msg.target}"}
                  class={[
                    "px-1.5 py-0.5 rounded font-mono hover:underline",
                    if(msg.kind == :room, do: "bg-info/20", else: "bg-warning/20")
                  ]}
                >
                  {kind_label(msg)}
                </.link>
                <.link navigate={~p"/agents/#{msg.from}"} class="font-medium text-base-content hover:underline">
                  {msg.from}
                </.link>
                <span>→ {msg.target}</span>
                <span class="ml-auto font-mono">{format_ts(msg.posted_at)}</span>
              </div>
              <div class="mt-1 text-sm whitespace-pre-wrap break-words">{msg.body}</div>
            </li>
          </ul>
          <p :if={@count == 0} class="text-sm text-base-content/50" id="messages-empty">
            Waiting for messages…
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp kind_slug(:room), do: "room"
  defp kind_slug(:channel), do: "channel"
  defp kind_slug(_), do: "room"

  defp kind_label(%{kind: :room}), do: "room"
  defp kind_label(%{kind: :channel}), do: "peer"
  defp kind_label(_), do: "msg"

  defp format_agent_line(a) do
    [a.branch, a.harness, format_ts(a.last_seen_at)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp format_ts(nil), do: ""
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(other) when is_binary(other), do: other
  defp format_ts(_), do: ""
end
