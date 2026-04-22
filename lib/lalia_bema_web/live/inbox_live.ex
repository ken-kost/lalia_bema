defmodule LaliaBemaWeb.InboxLive do
  @moduledoc """
  `/inbox` — peek / consume / read-any surface. Three tabs: peer channels,
  rooms-I'm-in, all (read-any).

  Peek output is cached in assigns for ~5 s per target. Consume is
  destructive and requires a confirm on first use per session.
  """
  use LaliaBemaWeb, :live_view

  alias LaliaBema.Lalia
  alias LaliaBema.Watcher
  alias LaliaBemaWeb.RoomActions

  @cache_ttl_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Watcher.pubsub(), Watcher.topic())

    socket =
      socket
      |> assign(page_title: "Inbox")
      |> assign(tab: "channels")
      |> assign(peeks: %{})
      |> assign(just_read: [])
      |> assign(confirm_target: nil)
      |> assign(consume_confirmed?: false)
      |> assign(action_throttle: %{})
      |> load_sources()

    {:ok, socket}
  end

  @impl true
  def handle_event("switch-tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("peek", %{"target" => target} = params, socket) do
    room? = Map.get(params, "room") == "true"
    now = System.monotonic_time(:millisecond)

    case Lalia.peek(target, room: room?) do
      {:ok, peek} ->
        peeks = Map.put(socket.assigns.peeks, {target, room?}, {peek, now})
        {:noreply, assign(socket, :peeks, peeks)}

      other ->
        RoomActions.result_to_flash(other, socket)
    end
  end

  def handle_event("confirm-consume", %{"target" => target} = params, socket) do
    if socket.assigns.consume_confirmed? do
      do_consume(target, params["room"] == "true", socket)
    else
      {:noreply, assign(socket, :confirm_target, {target, params["room"] == "true"})}
    end
  end

  def handle_event("cancel-consume", _params, socket) do
    {:noreply, assign(socket, :confirm_target, nil)}
  end

  def handle_event("do-consume", params, socket) do
    {target, room?} = socket.assigns.confirm_target || {params["target"], params["room"] == "true"}

    socket =
      socket
      |> assign(:confirm_target, nil)
      |> assign(:consume_confirmed?, true)

    do_consume(target, room?, socket)
  end

  def handle_event("read-any", _params, socket) do
    case Lalia.read_any(timeout: 0) do
      {:ok, msg} ->
        {:noreply,
         socket
         |> put_flash(:info, "Consumed a message from any mailbox.")
         |> update(:just_read, &[msg | &1])}

      other ->
        RoomActions.result_to_flash(other, socket)
    end
  end

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  @impl true
  def handle_info({:new_message, _}, socket) do
    # Invalidate peek cache so next "Peek" refreshes.
    {:noreply, assign(socket, :peeks, %{})}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp do_consume(target, room?, socket) do
    case Lalia.read(target, room: room?, timeout: 0) do
      {:ok, msg} ->
        {:noreply,
         socket
         |> put_flash(:info, "Consumed next from #{target}.")
         |> update(:just_read, &[msg | &1])}

      other ->
        RoomActions.result_to_flash(other, socket)
    end
  end

  defp load_sources(socket) do
    rooms =
      case Lalia.rooms() do
        {:ok, list} -> list
        _ -> []
      end

    channels =
      case Lalia.channels() do
        {:ok, list} -> list
        _ -> []
      end

    socket
    |> assign(:rooms, rooms)
    |> assign(:channels, channels)
  end

  defp cached_peek(peeks, target, room?) do
    case Map.get(peeks, {target, room?}) do
      {peek, stored_at} ->
        if System.monotonic_time(:millisecond) - stored_at < @cache_ttl_ms do
          peek
        else
          nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Inbox
        <:subtitle>Peek and consume on the scope identity's mailboxes</:subtitle>
        <:actions>
          <button type="button" phx-click="read-any" class="btn btn-sm btn-primary" id="read-any-btn"
                  data-confirm="read-any consumes the next message from any mailbox. Proceed?">
            Read any
          </button>
        </:actions>
      </.header>

      <div :if={@just_read != []} id="just-read" class="rounded-box border border-success/40 bg-success/10 p-3 mb-4">
        <strong>Just read ({length(@just_read)})</strong>
        <ul class="mt-2 space-y-2">
          <li :for={{msg, idx} <- Enum.with_index(@just_read)} id={"read-#{idx}"} class="text-xs">
            <span class="font-mono">{msg[:from] || "?"}</span>:
            <span class="whitespace-pre-wrap">{msg[:body] || msg[:raw]}</span>
          </li>
        </ul>
      </div>

      <div :if={@confirm_target} id="confirm-consume" class="alert alert-warning mb-4">
        <span>Consume the next message from
          <code class="font-mono">
            {elem(@confirm_target, 0)}{if elem(@confirm_target, 1), do: " (room)", else: ""}
          </code>?
        </span>
        <div class="flex gap-2">
          <button type="button" phx-click="do-consume" class="btn btn-sm btn-error">Yes</button>
          <button type="button" phx-click="cancel-consume" class="btn btn-sm">Cancel</button>
        </div>
      </div>

      <div class="tabs tabs-bordered mb-4">
        <button type="button"
                phx-click="switch-tab" phx-value-tab="channels"
                class={["tab", @tab == "channels" && "tab-active"]}>
          Peer channels ({length(@channels)})
        </button>
        <button type="button"
                phx-click="switch-tab" phx-value-tab="rooms"
                class={["tab", @tab == "rooms" && "tab-active"]}>
          Rooms ({length(@rooms)})
        </button>
      </div>

      <div :if={@tab == "channels"} id="channels-pane" class="space-y-3">
        <div :if={@channels == []} class="text-sm text-base-content/50 italic">No peer channels.</div>
        <div :for={c <- @channels} id={"inbox-channel-#{c.pair}"} class="rounded-box border border-base-300 p-3">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/history/channel/#{c.pair}"} class="font-mono text-sm hover:underline">{c.pair}</.link>
            <span :if={c.unread > 0} class="badge badge-sm badge-info">{c.unread} unread</span>
            <span class="ml-auto flex gap-1">
              <button type="button" phx-click="peek" phx-value-target={c.pair} class="btn btn-xs">Peek</button>
              <button type="button" phx-click="confirm-consume" phx-value-target={c.pair} class="btn btn-xs btn-warning">
                Consume
              </button>
            </span>
          </div>
          <div :if={peek = cached_peek(@peeks, c.pair, false)} class="mt-2 text-xs font-mono whitespace-pre-wrap bg-base-200 p-2 rounded">{peek.raw}</div>
        </div>
      </div>

      <div :if={@tab == "rooms"} id="rooms-pane" class="space-y-3">
        <div :if={@rooms == []} class="text-sm text-base-content/50 italic">No rooms.</div>
        <div :for={r <- @rooms} id={"inbox-room-#{r.name}"} class="rounded-box border border-base-300 p-3">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/rooms/#{r.name}"} class="font-mono text-sm hover:underline">#{r.name}</.link>
            <span class="text-xs text-base-content/60">{r.messages} msg · {r.members} members</span>
            <span class="ml-auto flex gap-1">
              <button type="button" phx-click="peek" phx-value-target={r.name} phx-value-room="true" class="btn btn-xs">Peek</button>
              <button type="button" phx-click="confirm-consume" phx-value-target={r.name} phx-value-room="true" class="btn btn-xs btn-warning">
                Consume
              </button>
            </span>
          </div>
          <div :if={peek = cached_peek(@peeks, r.name, true)} class="mt-2 text-xs font-mono whitespace-pre-wrap bg-base-200 p-2 rounded">{peek.raw}</div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
