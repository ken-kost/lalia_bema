defmodule LaliaBemaWeb.PageController do
  use LaliaBemaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
