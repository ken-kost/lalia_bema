defmodule LaliaBemaWeb.RoomActions do
  @moduledoc """
  Shared helpers for composer / join / leave / peek / consume flows used by
  `RoomLive`, `RoomsLive`, `AgentLive`, `HistoryLive`, and `InboxLive`.

  Extracts two kinds of logic:

  * **Result to flash** — a single `result_to_flash/3` helper that maps
    `{:ok, _}`, `{:error, {:exit, status, stderr}}`, and `{:error,
    :unauthorized, _}` tuples to the right `put_flash` call.
  * **Client-side rate-limit shaping** — a 1 s throttle per socket keyed by
    verb so mashed composers don't flood the sidecar. Purely advisory: we
    also enforce on submit.
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias LaliaBema.Lalia

  @throttle_ms 1_000

  @doc """
  Turn a wrapper result into a flash on the socket. Returns the same
  `{status, socket}` shape as `handle_event/3` callbacks so it can be the
  tail of a pipeline.
  """
  def result_to_flash(result, socket, success_msg \\ "Done.")

  def result_to_flash({:ok, _out}, socket, msg) do
    {:noreply, put_flash(socket, :info, msg)}
  end

  def result_to_flash({:error, :unauthorized, _out}, socket, _msg) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Not authorized (exit 6). Register the scope identity first."
     )}
  end

  def result_to_flash({:error, {:exit, status, stderr}}, socket, _msg) do
    detail = stderr |> String.trim() |> String.slice(0, 400)
    {:noreply, put_flash(socket, :error, "lalia exited #{status}: #{detail}")}
  end

  def result_to_flash({:error, other}, socket, _msg) do
    {:noreply, put_flash(socket, :error, "lalia failed: #{inspect(other)}")}
  end

  @doc """
  Returns `{:ok, socket}` when the verb is allowed, `{:throttled, socket}`
  otherwise. Socket keeps `:action_throttle` assigns as a map of
  `verb => last_monotonic_ms`.
  """
  def throttle(socket, verb) do
    now = System.monotonic_time(:millisecond)
    throttle = Map.get(socket.assigns, :action_throttle, %{})

    case Map.get(throttle, verb) do
      nil ->
        {:ok, Phoenix.Component.assign(socket, :action_throttle, Map.put(throttle, verb, now))}

      last when now - last >= @throttle_ms ->
        {:ok, Phoenix.Component.assign(socket, :action_throttle, Map.put(throttle, verb, now))}

      _ ->
        {:throttled, socket}
    end
  end

  @doc """
  Check whether the configured scope identity is in the given participant
  list (string list from `Lalia.participants/1`).
  """
  def joined?(participants, scope_identity) when is_list(participants) do
    is_binary(scope_identity) and scope_identity in participants
  end

  def joined?(_, _), do: false

  @doc "Wrap a wrapper call with throttling + flash mapping."
  def call(socket, verb, success_msg, fun) do
    case throttle(socket, verb) do
      {:throttled, socket} ->
        {:noreply, put_flash(socket, :error, "Slow down — one action per second.")}

      {:ok, socket} ->
        fun.() |> result_to_flash(socket, success_msg)
    end
  end

  @doc "Scope identity (convenience re-export)."
  def scope_identity, do: Lalia.scope_identity()
end
