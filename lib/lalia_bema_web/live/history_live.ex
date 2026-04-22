defmodule LaliaBemaWeb.HistoryLive do
  @moduledoc """
  `/history/:kind/:target` — search + permalink view equivalent to
  `lalia history`. `:kind` is `"room"` or `"channel"`; `:target` is a room
  name or a `alice--bob` peer pair. Each rendered message carries a
  `#msg-<seq>` anchor so links share cleanly.

  Phase 4 adds a tell / ask composer when viewing a channel so operators
  can reply to the peer directly from the transcript page.
  """
  use LaliaBemaWeb, :live_view

  require Ash.Query

  alias LaliaBema.Lalia
  alias LaliaBema.Scope
  alias LaliaBema.Watcher
  alias LaliaBemaWeb.RoomActions

  @page_size 50

  @impl true
  def mount(%{"kind" => kind, "target" => target}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Watcher.pubsub(), Watcher.topic())

    with {:ok, kind_atom} <- parse_kind(kind) do
      socket =
        socket
        |> assign(page_title: "#{kind}/#{target}")
        |> assign(kind: kind_atom)
        |> assign(kind_slug: kind)
        |> assign(target: target)
        |> assign(search: "")
        |> assign(jump: "")
        |> assign(page: 1)
        |> assign(composer: "")
        |> assign(compose_mode: "tell")
        |> assign(ask_timeout: 30)
        |> assign(ask_reply: nil)
        |> assign(peek: nil)
        |> assign(confirm_consume: false)
        |> assign(action_throttle: %{})

      {:ok, socket}
    else
      :error ->
        {:ok,
         socket
         |> put_flash(:error, "Unknown kind #{inspect(kind)}")
         |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    search = params["q"] || ""
    page = parse_page(params["page"])

    socket =
      socket
      |> assign(search: search, page: page)
      |> load_messages()

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    path = path_for(socket.assigns.kind_slug, socket.assigns.target, q, 1)
    {:noreply, push_patch(socket, to: path, replace: true)}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    path =
      path_for(
        socket.assigns.kind_slug,
        socket.assigns.target,
        socket.assigns.search,
        parse_page(page)
      )

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("jump", %{"seq" => seq}, socket) do
    {:noreply, assign(socket, :jump, seq)}
  end

  def handle_event("compose-change", params, socket) do
    body = Map.get(params, "body", socket.assigns.composer)
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
    peer = peer_for(socket)

    cond do
      body == "" ->
        {:noreply, put_flash(socket, :error, "Message body is empty.")}

      is_nil(peer) ->
        {:noreply, put_flash(socket, :error, "Can't infer peer from channel pair.")}

      mode == "ask" ->
        case Lalia.ask(peer, body, timeout: timeout) do
          {:ok, out} ->
            {:noreply,
             socket
             |> put_flash(:info, "Ask sent.")
             |> assign(:ask_reply, String.trim(out))
             |> assign(:composer, "")}

          other ->
            RoomActions.result_to_flash(other, socket)
        end

      true ->
        RoomActions.call(socket, :tell, "Told #{peer}.", fn ->
          Lalia.tell(peer, body)
        end)
        |> clear_composer()
    end
  end

  def handle_event("peek", _params, socket) do
    peer = peer_for(socket)

    case peer && Lalia.peek(peer) do
      nil -> {:noreply, put_flash(socket, :error, "Peek requires a channel context.")}
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
    peer = peer_for(socket)
    socket = assign(socket, :confirm_consume, false)

    if peer do
      RoomActions.call(socket, :consume, "Consumed next message.", fn ->
        Lalia.read(peer, timeout: 0)
      end)
    else
      {:noreply, put_flash(socket, :error, "Consume requires a channel context.")}
    end
  end

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  @impl true
  def handle_info({:new_message, %{kind: k, target: t}}, socket)
      when k == socket.assigns.kind and t == socket.assigns.target do
    {:noreply, load_messages(socket)}
  end

  def handle_info({:identity, _}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  defp parse_kind("room"), do: {:ok, :room}
  defp parse_kind("channel"), do: {:ok, :channel}
  defp parse_kind(_), do: :error

  defp parse_page(nil), do: 1
  defp parse_page(""), do: 1

  defp parse_page(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(n) when is_integer(n) and n > 0, do: n
  defp parse_page(_), do: 1

  defp path_for(kind_slug, target, search, page) do
    base = "/history/#{kind_slug}/#{URI.encode(target)}"
    params = %{}
    params = if search != "", do: Map.put(params, :q, search), else: params
    params = if page > 1, do: Map.put(params, :page, page), else: params

    case params do
      m when map_size(m) == 0 -> base
      m -> base <> "?" <> URI.encode_query(m)
    end
  end

  defp load_messages(socket) do
    %{kind: kind, target: target, search: search, page: page} = socket.assigns
    offset = (page - 1) * @page_size

    base =
      Scope.Message
      |> Ash.Query.filter(kind == ^kind and target == ^target)

    query = maybe_search(base, search)
    total = Ash.count!(query)

    messages =
      query
      |> Ash.Query.sort(seq: :asc)
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

  defp peer_for(%{assigns: %{kind: :channel, target: pair}}) do
    me = LaliaBema.scope_identity()

    case String.split(pair, "--", parts: 2) do
      [^me, other] -> other
      [other, ^me] -> other
      [a, _b] when is_binary(me) and a != me -> a
      [other] -> other
      _ -> nil
    end
  end

  defp peer_for(_), do: nil

  defp clear_composer({:noreply, socket}), do: {:noreply, assign(socket, :composer, "")}

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
      |> assign_new(:peer, fn -> peer_for(assigns) end)

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        <span class="font-mono">{@kind_slug}/{@target}</span>
        <:subtitle>
          {@total} message{if @total == 1, do: "", else: "s"}{if @search != "", do: " matching \"#{@search}\"", else: ""}
        </:subtitle>
        <:actions>
          <button :if={@kind == :channel} type="button" phx-click="peek" class="btn btn-sm" id="peek-channel">
            Peek
          </button>
          <button :if={@kind == :channel} type="button" phx-click="confirm-consume" class="btn btn-sm btn-warning" id="consume-channel">
            Consume
          </button>
        </:actions>
      </.header>

      <div :if={@confirm_consume} id="confirm-consume" class="alert alert-warning mb-4">
        <span>Consume will remove the next message from the mailbox.</span>
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

      <div class="flex flex-wrap items-center gap-3 mb-4">
        <form phx-submit="search" class="flex items-center gap-2 flex-1 min-w-64">
          <input
            type="text"
            name="q"
            value={@search}
            placeholder="Substring search (body)…"
            class="input input-sm input-bordered flex-1"
          />
          <button type="submit" class="btn btn-sm btn-primary">Search</button>
          <.link :if={@search != ""} patch={path_for(@kind_slug, @target, "", 1)} class="btn btn-sm btn-ghost">
            Clear
          </.link>
        </form>

        <form phx-submit="jump" class="flex items-center gap-2">
          <input
            type="text"
            name="seq"
            placeholder="#seq"
            class="input input-sm input-bordered w-24 font-mono"
          />
          <button type="submit" class="btn btn-sm">Jump</button>
        </form>
      </div>

      <p :if={@jump != ""} id="jump-hint" class="text-xs text-base-content/60 mb-2">
        Jumping to <a href={"#msg-#{@jump}"} class="link font-mono">#msg-{@jump}</a>
      </p>

      <ul id="history-messages" class="space-y-3">
        <li
          :for={msg <- @messages}
          id={"msg-#{msg.seq}"}
          class="border-l-2 border-primary/30 pl-3 scroll-mt-24"
        >
          <div class="flex items-center gap-2 text-xs text-base-content/60">
            <a href={"#msg-#{msg.seq}"} class="font-mono hover:underline">#{msg.seq}</a>
            <.link navigate={~p"/agents/#{msg.from}"} class="font-medium text-base-content hover:underline">
              {msg.from}
            </.link>
            <span class="ml-auto font-mono">{format_ts(msg.posted_at)}</span>
          </div>
          <pre class="mt-1 text-sm whitespace-pre-wrap break-words font-mono">{msg.body}</pre>
        </li>
      </ul>

      <p :if={@messages == []} id="history-empty" class="text-sm text-base-content/50 italic">
        No messages to show.
      </p>

      <div :if={@total > @page_size} class="flex items-center gap-2 justify-end text-sm mt-4">
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
        :if={@kind == :channel and @peer}
        phx-change="compose-change"
        phx-submit="send"
        class="rounded-box border border-base-300 p-3 mt-6"
        id="history-composer"
      >
        <div class="flex items-center gap-3 mb-2">
          <label class="text-xs uppercase tracking-wide text-base-content/60">
            As <code class="font-mono">{@scope_identity || "no-identity"}</code> →
            <span class="font-mono">{@peer}</span>
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
          placeholder="Message body…"
        ><%= @composer %></textarea>
        <div class="flex items-center justify-end mt-2">
          <button type="submit" class="btn btn-sm btn-primary">
            {if @compose_mode == "ask", do: "Ask", else: "Tell"}
          </button>
        </div>
      </form>
    </Layouts.app>
    """
  end

  defp format_ts(nil), do: ""
  defp format_ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_ts(_), do: ""
end
