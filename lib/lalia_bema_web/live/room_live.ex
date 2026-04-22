defmodule LaliaBemaWeb.RoomLive do
  @moduledoc """
  Full-transcript view at `/rooms/:name`. Reads messages from the Ash store,
  supports paginated and body-substring search, and appends live when the
  Watcher broadcasts a new message for this room.

  Phase 4 adds write affordances:

  * Composer textarea for `Lalia.post/2`
  * Join / Leave / Peek / Consume buttons wired to the CLI
  * Participant sidebar with click-to-tell and nickname inline editor
  """
  use LaliaBemaWeb, :live_view

  require Ash.Query

  alias LaliaBema.Lalia
  alias LaliaBema.Scope
  alias LaliaBema.Watcher
  alias LaliaBemaWeb.RoomActions

  @page_size 50

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Watcher.pubsub(), Watcher.topic())

    socket =
      socket
      |> assign(page_title: "#" <> name)
      |> assign(room_name: name)
      |> assign(room: fetch_room(name))
      |> assign(search: "")
      |> assign(page: 1)
      |> assign(composer: "")
      |> assign(peek: nil)
      |> assign(participants: [])
      |> assign(action_throttle: %{})
      |> assign(confirm_consume: false)
      |> refresh_participants()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = params["q"] || ""
    page = parse_page(params["page"])

    socket =
      socket
      |> assign(search: search, page: page)
      |> load_messages()
      |> load_members()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: path_for(socket.assigns.room_name, q, 1), replace: true)}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply,
     push_patch(socket, to: path_for(socket.assigns.room_name, socket.assigns.search, parse_page(page)))}
  end

  def handle_event("compose-change", %{"body" => body}, socket) do
    {:noreply, assign(socket, :composer, body)}
  end

  def handle_event("post", %{"body" => body}, socket) do
    body = String.trim(body)

    if body == "" do
      {:noreply, put_flash(socket, :error, "Message body is empty.")}
    else
      RoomActions.call(socket, :post, "Posted to ##{socket.assigns.room_name}.", fn ->
        Lalia.post(socket.assigns.room_name, body)
      end)
      |> after_post()
    end
  end

  def handle_event("join", _params, socket) do
    RoomActions.call(socket, :join, "Joined ##{socket.assigns.room_name}.", fn ->
      Lalia.join(socket.assigns.room_name)
    end)
    |> refresh_participants_after()
  end

  def handle_event("leave", _params, socket) do
    RoomActions.call(socket, :leave, "Left ##{socket.assigns.room_name}.", fn ->
      Lalia.leave(socket.assigns.room_name)
    end)
    |> refresh_participants_after()
  end

  def handle_event("peek", _params, socket) do
    case Lalia.peek(socket.assigns.room_name, room: true) do
      {:ok, peek} ->
        {:noreply, assign(socket, :peek, peek)}

      other ->
        RoomActions.result_to_flash(other, socket)
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
      Lalia.read(socket.assigns.room_name, room: true, timeout: 0)
    end)
  end

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  @impl true
  def handle_info({:new_message, %{kind: :room, target: target}}, socket)
      when target == socket.assigns.room_name do
    {:noreply, socket |> load_messages() |> load_members()}
  end

  def handle_info({:rooms, _}, socket) do
    {:noreply, assign(socket, :room, fetch_room(socket.assigns.room_name))}
  end

  def handle_info({:identity, _state}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  defp fetch_room(name) do
    case Scope.get_room(name) do
      {:ok, room} -> room
      _ -> nil
    end
  end

  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1

  defp parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(int) when is_integer(int) and int > 0, do: int
  defp parse_page(_), do: 1

  defp path_for(name, search, page) do
    params = %{}
    params = if search != "", do: Map.put(params, :q, search), else: params
    params = if page > 1, do: Map.put(params, :page, page), else: params

    if params == %{} do
      "/rooms/#{name}"
    else
      "/rooms/#{name}?" <> URI.encode_query(params)
    end
  end

  defp load_messages(socket) do
    %{room_name: name, search: search, page: page} = socket.assigns
    offset = (page - 1) * @page_size

    base =
      Scope.Message
      |> Ash.Query.filter(kind == :room and target == ^name)

    query = maybe_search(base, search)
    total = Ash.count!(query)

    messages =
      query
      |> Ash.Query.sort(posted_at: :desc, seq: :desc)
      |> Ash.Query.limit(@page_size)
      |> Ash.Query.offset(offset)
      |> Ash.read!()

    socket
    |> assign(:messages, messages)
    |> assign(:total, total)
    |> assign(:page_size, @page_size)
  end

  defp maybe_search(query, ""), do: query

  defp maybe_search(query, search) do
    pattern = "%" <> search <> "%"
    Ash.Query.filter(query, ilike(body, ^pattern))
  end

  defp load_members(socket) do
    %{room_name: name} = socket.assigns

    senders =
      Scope.Message
      |> Ash.Query.filter(kind == :room and target == ^name)
      |> Ash.Query.select([:from])
      |> Ash.read!()
      |> Enum.map(& &1.from)
      |> Enum.uniq()
      |> Enum.sort()

    agents_by_name =
      Scope.list_agents!(load: [:active?])
      |> Map.new(&{&1.name, &1})

    members = Enum.map(senders, &{&1, Map.get(agents_by_name, &1)})
    assign(socket, :members, members)
  end

  defp refresh_participants(socket) do
    case Lalia.participants(socket.assigns.room_name) do
      {:ok, list} -> assign(socket, :participants, list)
      _ -> socket
    end
  end

  defp refresh_participants_after({:noreply, socket}) do
    {:noreply, refresh_participants(socket)}
  end

  defp after_post({:noreply, socket}) do
    {:noreply, assign(socket, :composer, "")}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:scope_identity, fn -> LaliaBema.scope_identity() end)
      |> assign(:joined?, RoomActions.joined?(assigns.participants, LaliaBema.scope_identity()))

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        #{@room_name}
        <:subtitle>
          <%= cond do %>
            <% @room && @room.description -> %>
              {@room.description}
            <% @room -> %>
              Room transcript
            <% true -> %>
              <span class="text-warning">Room not yet registered — showing messages only.</span>
          <% end %>
        </:subtitle>
        <:actions>
          <button :if={!@joined?} type="button" phx-click="join" class="btn btn-sm btn-primary">
            Join
          </button>
          <button :if={@joined?} type="button" phx-click="leave" class="btn btn-sm btn-ghost">
            Leave
          </button>
          <button type="button" phx-click="peek" class="btn btn-sm" id="peek-mailbox">
            Peek mailbox
          </button>
          <button type="button" phx-click="confirm-consume" class="btn btn-sm btn-warning" id="consume-btn">
            Consume next
          </button>
        </:actions>
      </.header>

      <div :if={@confirm_consume} id="confirm-consume" class="alert alert-warning mb-4">
        <div>
          <strong>Destructive:</strong>
          Consuming pulls the next message out of Lalia's mailbox.
        </div>
        <div class="flex gap-2">
          <button type="button" phx-click="consume" class="btn btn-sm btn-error">Yes, consume</button>
          <button type="button" phx-click="cancel-consume" class="btn btn-sm">Cancel</button>
        </div>
      </div>

      <div :if={@peek} id="peek-panel" class="rounded-box border border-info/40 bg-info/10 p-3 mb-4 text-sm">
        <div class="flex items-center gap-2 mb-2">
          <strong>Mailbox peek</strong>
          <span :if={@peek[:pending]} class="badge badge-info">pending {@peek.pending}</span>
        </div>
        <pre class="whitespace-pre-wrap font-mono text-xs">{@peek.raw}</pre>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-4 gap-4">
        <aside class="lg:col-span-1 rounded-box border border-base-300 p-4 space-y-3 order-2 lg:order-1">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70">
            Participants <span class="text-base-content/50">({length(@participants)})</span>
          </h2>
          <ul :if={@participants != []} id="participants" class="space-y-1 text-sm">
            <li :for={name <- @participants} class="flex items-center gap-2">
              <.link navigate={~p"/agents/#{name}"} class="hover:underline">{name}</.link>
              <.link
                navigate={~p"/history/channel/#{channel_pair(@scope_identity, name)}"}
                class="text-xs text-base-content/50 hover:underline"
              >
                tell
              </.link>
            </li>
          </ul>

          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/70 pt-2">
            Members <span class="text-base-content/50">({length(@members)})</span>
          </h2>
          <ul :if={@members != []} id="members" class="space-y-1 text-sm">
            <li :for={{name, agent} <- @members} class="flex items-center gap-2">
              <span class={[
                "size-2 rounded-full",
                if(agent && agent.active?, do: "bg-success", else: "bg-base-300")
              ]} />
              <.link navigate={~p"/agents/#{name}"} class="hover:underline">{name}</.link>
              <span :if={is_nil(agent)} class="text-xs text-base-content/50">(not registered)</span>
            </li>
          </ul>
          <p :if={@members == [] and @participants == []} class="text-sm text-base-content/50">
            No members yet.
          </p>
        </aside>

        <section class="lg:col-span-3 space-y-4 order-1 lg:order-2">
          <form phx-submit="search" class="flex gap-2">
            <input
              type="text"
              name="q"
              value={@search}
              placeholder="Search message body…"
              class="input input-sm input-bordered flex-1"
            />
            <button type="submit" class="btn btn-sm btn-primary">Search</button>
            <.link :if={@search != ""} patch={path_for(@room_name, "", 1)} class="btn btn-sm btn-ghost">
              Clear
            </.link>
          </form>

          <p class="text-xs text-base-content/60">
            {@total} message{if @total == 1, do: "", else: "s"}{if @search != "", do: " matching \"#{@search}\"", else: ""}
          </p>

          <ul id="room-messages" class="space-y-3">
            <li
              :for={msg <- @messages}
              id={"msg-#{msg.seq}"}
              class="border-l-2 border-primary/30 pl-3"
            >
              <div class="flex items-center gap-2 text-xs text-base-content/60">
                <span class="font-mono">#{msg.seq}</span>
                <.link navigate={~p"/agents/#{msg.from}"} class="font-medium text-base-content hover:underline">
                  {msg.from}
                </.link>
                <span class="ml-auto font-mono">{format_ts(msg.posted_at)}</span>
              </div>
              <pre class="mt-1 text-sm whitespace-pre-wrap break-words font-mono">{msg.body}</pre>
            </li>
          </ul>

          <p :if={@messages == []} id="room-empty" class="text-sm text-base-content/50 italic">
            No messages to show.
          </p>

          <div :if={@total > @page_size} class="flex items-center gap-2 justify-end text-sm">
            <button
              type="button"
              phx-click="paginate"
              phx-value-page={@page - 1}
              disabled={@page <= 1}
              class="btn btn-sm"
            >
              ← Prev
            </button>
            <span class="text-base-content/60">
              Page {@page} of {max(div(@total + @page_size - 1, @page_size), 1)}
            </span>
            <button
              type="button"
              phx-click="paginate"
              phx-value-page={@page + 1}
              disabled={@page * @page_size >= @total}
              class="btn btn-sm"
            >
              Next →
            </button>
          </div>

          <form
            phx-change="compose-change"
            phx-submit="post"
            class="rounded-box border border-base-300 p-3 mt-6"
            id="room-composer"
          >
            <label class="text-xs uppercase tracking-wide text-base-content/60 mb-1 block">
              Post as <code class="font-mono">{@scope_identity || "no-identity"}</code>
            </label>
            <textarea
              name="body"
              rows="3"
              class="textarea textarea-bordered w-full font-mono text-sm"
              placeholder="Write a message (Ctrl+Enter to send, Esc to clear)…"
              phx-hook="ComposerHotkeys"
              id="room-composer-body"
            ><%= @composer %></textarea>
            <div class="flex items-center justify-between mt-2">
              <span :if={String.length(@composer) > 500} class="text-xs text-warning">
                {String.length(@composer)} chars
              </span>
              <span :if={String.length(@composer) <= 500} class="text-xs text-base-content/40"></span>
              <button type="submit" class="btn btn-sm btn-primary">Post</button>
            </div>
          </form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp channel_pair(nil, other), do: other
  defp channel_pair(me, other) when me <= other, do: "#{me}--#{other}"
  defp channel_pair(me, other), do: "#{other}--#{me}"

  defp format_ts(nil), do: ""
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_ts(_), do: ""
end
