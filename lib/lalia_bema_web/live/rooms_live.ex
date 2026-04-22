defmodule LaliaBemaWeb.RoomsLive do
  @moduledoc """
  `/rooms` — rooms index page with lifecycle actions: create, join/leave,
  archive sweep, participants.
  """
  use LaliaBemaWeb, :live_view

  require Ash.Query

  alias LaliaBema.Lalia
  alias LaliaBema.Scope
  alias LaliaBema.Watcher
  alias LaliaBemaWeb.RoomActions

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Watcher.pubsub(), Watcher.topic())

    socket =
      socket
      |> assign(page_title: "Rooms")
      |> assign(show_create: false)
      |> assign(create_name: "")
      |> assign(create_desc: "")
      |> assign(confirm_gc: false)
      |> assign(action_throttle: %{})
      |> assign(expanded: MapSet.new())
      |> assign(participants: %{})
      |> load_rooms()

    {:ok, socket}
  end

  @impl true
  def handle_event("open-create", _params, socket),
    do: {:noreply, assign(socket, :show_create, true)}

  def handle_event("close-create", _params, socket),
    do:
      {:noreply,
       assign(socket, show_create: false, create_name: "", create_desc: "")}

  def handle_event("create-change", %{"name" => name} = params, socket) do
    desc = Map.get(params, "desc", socket.assigns.create_desc)
    {:noreply, assign(socket, create_name: name, create_desc: desc)}
  end

  def handle_event("create", %{"name" => name} = params, socket) do
    name = String.trim(name)
    desc = params |> Map.get("desc", "") |> String.trim()

    if name == "" do
      {:noreply, put_flash(socket, :error, "Room name is required.")}
    else
      opts = if desc != "", do: [desc: desc], else: []

      case RoomActions.call(socket, :room_create, "Created ##{name}.", fn ->
             Lalia.room_create(name, opts)
           end) do
        {:noreply, s} -> {:noreply, s |> assign(show_create: false, create_name: "", create_desc: "") |> load_rooms()}
      end
    end
  end

  def handle_event("confirm-gc", _params, socket),
    do: {:noreply, assign(socket, :confirm_gc, true)}

  def handle_event("cancel-gc", _params, socket),
    do: {:noreply, assign(socket, :confirm_gc, false)}

  def handle_event("gc", _params, socket) do
    socket = assign(socket, :confirm_gc, false)

    RoomActions.call(socket, :rooms_gc, "Archive sweep ran.", fn ->
      Lalia.rooms_gc()
    end)
  end

  def handle_event("join", %{"room" => room}, socket) do
    RoomActions.call(socket, :join, "Joined ##{room}.", fn ->
      Lalia.join(room)
    end)
    |> refresh_room_participants(room)
  end

  def handle_event("leave", %{"room" => room}, socket) do
    RoomActions.call(socket, :leave, "Left ##{room}.", fn ->
      Lalia.leave(room)
    end)
    |> refresh_room_participants(room)
  end

  def handle_event("toggle-participants", %{"room" => room}, socket) do
    expanded = socket.assigns.expanded

    cond do
      MapSet.member?(expanded, room) ->
        {:noreply, assign(socket, :expanded, MapSet.delete(expanded, room))}

      true ->
        socket =
          case Lalia.participants(room) do
            {:ok, list} ->
              participants = Map.put(socket.assigns.participants, room, list)

              socket
              |> assign(:participants, participants)
              |> assign(:expanded, MapSet.put(expanded, room))

            _ ->
              put_flash(socket, :error, "Could not fetch participants.")
          end

        {:noreply, socket}
    end
  end

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  @impl true
  def handle_info({:rooms, _}, socket), do: {:noreply, load_rooms(socket)}
  def handle_info({:new_message, _}, socket), do: {:noreply, load_rooms(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load_rooms(socket) do
    rooms = Scope.list_rooms!(query: [sort: [name: :asc]])

    activity =
      Scope.Message
      |> Ash.Query.filter(kind == :room)
      |> Ash.Query.sort(posted_at: :desc)
      |> Ash.read!()
      |> Enum.group_by(& &1.target)

    rooms_with_counts =
      Enum.map(rooms, fn r ->
        msgs = Map.get(activity, r.name, [])

        last =
          case msgs do
            [first | _] -> first.posted_at
            _ -> nil
          end

        Map.put(r, :__computed__, %{message_count: length(msgs), last_activity: last})
      end)

    assign(socket, :rooms, rooms_with_counts)
  end

  defp refresh_room_participants({:noreply, socket}, room) do
    case Lalia.participants(room) do
      {:ok, list} ->
        {:noreply, assign(socket, :participants, Map.put(socket.assigns.participants, room, list))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:scope_identity, fn -> LaliaBema.scope_identity() end)

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Rooms
        <:subtitle>
          {length(@rooms)} room{if length(@rooms) == 1, do: "", else: "s"} mirrored from the Lalia workspace
        </:subtitle>
        <:actions>
          <button type="button" phx-click="open-create" class="btn btn-sm btn-primary" id="open-create">
            New Room
          </button>
          <button type="button" phx-click="confirm-gc" class="btn btn-sm btn-warning" id="open-gc">
            Archive sweep
          </button>
        </:actions>
      </.header>

      <div :if={@show_create} id="create-modal" class="rounded-box border border-primary/40 bg-primary/10 p-4 mb-4">
        <h3 class="font-semibold mb-2">Create room</h3>
        <form phx-change="create-change" phx-submit="create" class="space-y-2">
          <label class="form-control w-full">
            <span class="label-text text-xs">Name</span>
            <input type="text" name="name" value={@create_name} class="input input-sm input-bordered w-full" required />
          </label>
          <label class="form-control w-full">
            <span class="label-text text-xs">Description</span>
            <input type="text" name="desc" value={@create_desc} class="input input-sm input-bordered w-full" />
          </label>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="close-create" class="btn btn-sm btn-ghost">Cancel</button>
            <button type="submit" class="btn btn-sm btn-primary">Create</button>
          </div>
        </form>
      </div>

      <div :if={@confirm_gc} id="gc-modal" class="alert alert-warning mb-4">
        <span>
          Archive sweep removes rooms flagged for cleanup by the daemon. Supervisor-only.
        </span>
        <div class="flex gap-2">
          <button type="button" phx-click="gc" class="btn btn-sm btn-error">Yes, run</button>
          <button type="button" phx-click="cancel-gc" class="btn btn-sm">Cancel</button>
        </div>
      </div>

      <div :if={@rooms == []} id="rooms-empty" class="text-sm text-base-content/60 italic">
        No rooms yet. Create one with the button above.
      </div>

      <div :if={@rooms != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Name</th>
              <th>Description</th>
              <th>Members</th>
              <th>Messages</th>
              <th>Last activity</th>
              <th class="text-right">Actions</th>
            </tr>
          </thead>
          <tbody id="rooms">
            <%= for r <- @rooms do %>
              <tr id={"room-#{r.name}"}>
                <td>
                  <.link navigate={~p"/rooms/#{r.name}"} class="font-mono hover:underline">#{r.name}</.link>
                </td>
                <td>{r.description || "—"}</td>
                <td>{r.member_count}</td>
                <td>{r.__computed__.message_count}</td>
                <td class="font-mono text-xs">{format_ts(r.__computed__.last_activity)}</td>
                <td class="text-right">
                  <div class="flex items-center gap-1 justify-end">
                    <% joined? = RoomActions.joined?(Map.get(@participants, r.name, []), @scope_identity) %>
                    <button
                      :if={not joined?}
                      type="button"
                      phx-click="join"
                      phx-value-room={r.name}
                      class="btn btn-xs"
                    >
                      Join
                    </button>
                    <button
                      :if={joined?}
                      type="button"
                      phx-click="leave"
                      phx-value-room={r.name}
                      class="btn btn-xs btn-ghost"
                    >
                      Leave
                    </button>
                    <button
                      type="button"
                      phx-click="toggle-participants"
                      phx-value-room={r.name}
                      class="btn btn-xs"
                    >
                      Participants
                    </button>
                  </div>
                </td>
              </tr>
              <tr :if={MapSet.member?(@expanded, r.name)} id={"participants-#{r.name}"}>
                <td colspan="6" class="bg-base-200 text-xs">
                  <div class="flex flex-wrap gap-2">
                    <span :for={p <- Map.get(@participants, r.name, [])} class="badge">
                      <.link navigate={~p"/agents/#{p}"} class="hover:underline">{p}</.link>
                    </span>
                    <span :if={Map.get(@participants, r.name, []) == []} class="italic text-base-content/50">
                      No participants.
                    </span>
                  </div>
                </td>
              </tr>
            <% end %>
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
