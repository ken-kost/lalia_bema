defmodule LaliaBemaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use LaliaBemaWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assigns
      |> Map.put_new(:scope_identity, LaliaBema.scope_identity())
      |> Map.put_new(:identity_state, LaliaBema.identity_state())

    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8 border-b border-base-300 gap-4">
      <div class="flex-1 flex items-center gap-4">
        <.link navigate={~p"/"} class="flex items-center gap-2 font-semibold">
          <img src={~p"/images/logo.svg"} width="28" />
          <span>Lalia Scope</span>
        </.link>
        <nav class="flex flex-wrap gap-1">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Feed</.link>
          <.link navigate={~p"/tasks"} class="btn btn-ghost btn-sm">Tasks</.link>
          <.link navigate={~p"/rooms"} class="btn btn-ghost btn-sm">Rooms</.link>
          <.link navigate={~p"/agents"} class="btn btn-ghost btn-sm">Agents</.link>
          <.link navigate={~p"/channels"} class="btn btn-ghost btn-sm">Channels</.link>
          <.link navigate={~p"/inbox"} class="btn btn-ghost btn-sm">Inbox</.link>
        </nav>
      </div>
      <div class="flex-none flex items-center gap-3">
        <form phx-submit="nav-search" id="nav-search" class="flex items-center gap-1">
          <select name="kind" class="select select-sm select-bordered">
            <option value="room">room</option>
            <option value="channel">channel</option>
          </select>
          <input
            name="target"
            type="text"
            placeholder="name or peer--pair"
            class="input input-sm input-bordered w-48"
          />
          <button type="submit" class="btn btn-sm btn-primary">Search</button>
        </form>
        <.scope_identity_widget identity={@scope_identity} state={@identity_state} />
        <.theme_toggle />
      </div>
    </header>

    <div :if={@identity_state in [:unregistered, :unknown] or match?({:error, _}, @identity_state)} class="bg-warning/20 border-b border-warning/40 px-4 py-2 text-sm text-warning-content">
      <span class="font-semibold">Scope identity not registered:</span>
      writes will fail until <code class="font-mono">{@scope_identity || "scope-human"}</code>
      is registered. Open
      <.link navigate={~p"/agents"} class="link">Agents</.link>
      to register, or run <code class="font-mono">lalia register --name {@scope_identity || "scope-human"}</code>.
    </div>

    <main class="px-4 py-6 sm:px-6 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  attr :identity, :string, default: nil
  attr :state, :any, default: :unknown

  def scope_identity_widget(assigns) do
    ~H"""
    <.link
      navigate={~p"/agents"}
      class="flex items-center gap-2 text-xs border border-base-300 rounded px-2 py-1 hover:bg-base-200"
      id="scope-identity-widget"
    >
      <span class={[
        "size-2 rounded-full",
        case @state do
          :registered -> "bg-success"
          :unregistered -> "bg-warning"
          {:error, _} -> "bg-error"
          _ -> "bg-base-300"
        end
      ]} />
      <span class="font-mono">
        {@identity || "no-identity"}
      </span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
