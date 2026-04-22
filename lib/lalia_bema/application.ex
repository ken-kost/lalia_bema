defmodule LaliaBema.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        LaliaBemaWeb.Telemetry,
        LaliaBema.Repo,
        {DNSCluster, query: Application.get_env(:lalia_bema, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: LaliaBema.PubSub}
      ] ++
        watcher_child() ++
        reconciler_child() ++
        identity_child() ++
        [LaliaBemaWeb.Endpoint]

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

  defp watcher_child do
    cfg = Application.get_env(:lalia_bema, :lalia, [])
    if Keyword.get(cfg, :watcher_enabled, true), do: [LaliaBema.Watcher], else: []
  end

  defp reconciler_child do
    cfg = Application.get_env(:lalia_bema, :lalia, [])
    if Keyword.get(cfg, :watcher_enabled, true), do: [LaliaBema.Reconciler], else: []
  end

  defp identity_child do
    cfg = Application.get_env(:lalia_bema, :lalia, [])
    if Keyword.get(cfg, :identity_check_enabled, true), do: [LaliaBema.Identity], else: []
  end
end
