defmodule LaliaBemaWeb.NicknamesLive do
  @moduledoc """
  `/nicknames` — full CRUD surface over `~/.lalia/nicknames.json` via the
  CLI wrapper.
  """
  use LaliaBemaWeb, :live_view

  alias LaliaBema.Lalia
  alias LaliaBemaWeb.RoomActions

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Nicknames")
      |> assign(form: %{"name" => "", "nickname" => "", "follow" => false})
      |> assign(action_throttle: %{})
      |> load_nicknames()

    {:ok, socket}
  end

  @impl true
  def handle_event("form-change", %{"form" => form}, socket) do
    form =
      socket.assigns.form
      |> Map.merge(form)
      |> Map.update!("follow", fn
        "true" -> true
        true -> true
        _ -> false
      end)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"form" => form}, socket) do
    name = String.trim(Map.get(form, "name", ""))
    nickname = String.trim(Map.get(form, "nickname", ""))
    follow? = Map.get(form, "follow") in [true, "true"]

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "Agent name is required.")}

      nickname == "" ->
        {:noreply, put_flash(socket, :error, "Nickname is required.")}

      true ->
        RoomActions.call(socket, :nickname_set, "Nickname saved.", fn ->
          Lalia.nickname_set(name, nickname, follow: follow?)
        end)
        |> reload_after()
    end
  end

  def handle_event("delete", %{"name" => name}, socket) do
    RoomActions.call(socket, :nickname_delete, "Nickname cleared.", fn ->
      Lalia.nickname_delete(name)
    end)
    |> reload_after()
  end

  def handle_event("nav-search", params, socket),
    do: LaliaBemaWeb.NavSearch.handle(socket, params)

  defp reload_after({:noreply, socket}), do: {:noreply, load_nicknames(socket)}

  defp load_nicknames(socket) do
    case Lalia.nickname_list() do
      {:ok, list} -> assign(socket, :nicknames, list)
      _ -> assign(socket, :nicknames, [])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Nicknames
        <:subtitle>Local alias mappings stored in <code class="font-mono">~/.lalia/nicknames.json</code></:subtitle>
      </.header>

      <form phx-change="form-change" phx-submit="save" class="flex flex-wrap items-end gap-3 mb-6" id="nickname-form">
        <label class="form-control">
          <span class="label-text text-xs">Agent</span>
          <input type="text" name="form[name]" value={@form["name"]} class="input input-sm input-bordered w-32" />
        </label>
        <label class="form-control">
          <span class="label-text text-xs">Nickname</span>
          <input type="text" name="form[nickname]" value={@form["nickname"]} class="input input-sm input-bordered w-32" />
        </label>
        <label class="form-control flex flex-row items-center gap-1">
          <input type="checkbox" name="form[follow]" value="true" checked={@form["follow"]} class="checkbox checkbox-sm" />
          <span class="text-sm">follow</span>
        </label>
        <button type="submit" class="btn btn-sm btn-primary">Save</button>
      </form>

      <div :if={@nicknames == []} id="nicknames-empty" class="text-sm text-base-content/60 italic">
        No nicknames configured.
      </div>

      <div :if={@nicknames != []} class="overflow-x-auto">
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Agent</th>
              <th>Nickname</th>
              <th>Follow</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="nicknames">
            <tr :for={n <- @nicknames} id={"nickname-#{n.name}"}>
              <td class="font-mono">{n.name}</td>
              <td>{n.nickname}</td>
              <td>
                <span :if={n.follow} class="badge badge-sm badge-info">follow</span>
                <span :if={not n.follow} class="text-base-content/50 text-xs">—</span>
              </td>
              <td class="text-right">
                <button type="button" phx-click="delete" phx-value-name={n.name}
                        data-confirm="Remove nickname?" class="btn btn-xs btn-ghost">
                  Remove
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
