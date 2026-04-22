defmodule LaliaBema.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LaliaBemaWeb.Telemetry,
      LaliaBema.Repo,
      {DNSCluster, query: Application.get_env(:lalia_bema, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LaliaBema.PubSub},
      # Start a worker by calling: LaliaBema.Worker.start_link(arg)
      # {LaliaBema.Worker, arg},
      # Start to serve requests, typically the last entry
      LaliaBemaWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LaliaBema.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LaliaBemaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
