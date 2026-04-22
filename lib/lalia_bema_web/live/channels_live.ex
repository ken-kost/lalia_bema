defmodule LaliaBemaWeb.ChannelsLive do
  @moduledoc """
  `/channels` — peer-channel index via `lalia channels`. Each row links to
  `/history/channel/:pair`.
  """
  use LaliaBemaWeb, :live_view

  alias LaliaBema.Lalia

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Channels")
      |> load_channels()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_channels(socket)}

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  defp load_channels(socket) do
    case Lalia.channels() do
      {:ok, channels} ->
        socket
        |> assign(:channels, channels)
        |> assign(:error, nil)

      {:error, :unauthorized, stderr} ->
        socket
        |> assign(:channels, [])
        |> assign(:error, "Not authorized: #{stderr}")

      {:error, {:exit, status, stderr}} ->
        socket
        |> assign(:channels, [])
        |> assign(:error, "lalia exited #{status}: #{String.slice(stderr || "", 0, 400)}")

      {:error, other} ->
        socket
        |> assign(:channels, [])
        |> assign(:error, inspect(other))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Channels
        <:subtitle>Peer-to-peer channels visible to the scope identity</:subtitle>
        <:actions>
          <button type="button" phx-click="refresh" class="btn btn-sm" id="refresh-channels">
            Refresh
          </button>
        </:actions>
      </.header>

      <div :if={@error} id="channels-error" class="alert alert-error mb-4">
        {@error}
      </div>

      <div :if={@channels == [] and is_nil(@error)} id="channels-empty" class="text-sm text-base-content/60 italic">
        No channels visible to the scope identity.
      </div>

      <div :if={@channels != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Pair</th>
              <th>Last activity</th>
              <th>Unread</th>
            </tr>
          </thead>
          <tbody id="channels">
            <tr :for={c <- @channels} id={"channel-#{c.pair}"}>
              <td>
                <.link navigate={~p"/history/channel/#{c.pair}"} class="font-mono hover:underline">
                  {c.pair}
                </.link>
              </td>
              <td class="font-mono text-xs">{c.last_activity || "—"}</td>
              <td>{c.unread}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
