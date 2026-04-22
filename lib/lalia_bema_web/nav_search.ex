defmodule LaliaBemaWeb.NavSearch do
  @moduledoc false
  import Phoenix.LiveView, only: [push_navigate: 2]

  def handle(socket, %{"kind" => kind, "target" => target})
      when is_binary(target) and target != "" and kind in ["room", "channel"] do
    {:noreply, push_navigate(socket, to: "/history/#{kind}/#{URI.encode(target)}")}
  end

  def handle(socket, _), do: {:noreply, socket}
end
