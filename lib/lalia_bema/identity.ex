defmodule LaliaBema.Identity do
  @moduledoc """
  Tracks whether the configured scope identity (`config :lalia_bema, :lalia,
  caller:`) is registered with the running `lalia` daemon.

  On boot: run `lalia agents`, look for the configured name, and if it's
  missing attempt `lalia register --name <name> --role <role>` so the
  first-run case "just works". Any result short of `:registered` leaves a
  banner visible on every LiveView until a subsequent registration lands.

  The watcher's 5 s tick re-checks the state and broadcasts `{:identity,
  state}` whenever it changes, so LiveViews drop/show the banner live.
  """

  use GenServer
  require Logger

  alias LaliaBema.Lalia

  @topic "feed"
  @pubsub LaliaBema.PubSub
  @tick_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Current registration state."
  @spec state() :: :registered | :unregistered | :unknown | {:error, term()}
  def state(server \\ __MODULE__) do
    case Process.whereis(server) do
      nil -> :unknown
      pid -> GenServer.call(pid, :state)
    end
  catch
    :exit, _ -> :unknown
  end

  @doc "Force a re-check. Returns the new state."
  def refresh(server \\ __MODULE__) do
    GenServer.call(server, :refresh)
  end

  @impl true
  def init(opts) do
    auto_register? = Keyword.get(opts, :auto_register?, true)
    state = %{state: :unknown, auto_register?: auto_register?}
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, %{state: s} = state) do
    {:reply, s, state}
  end

  def handle_call(:refresh, _from, state) do
    new = check_and_register(state.auto_register?)
    state = maybe_broadcast(state, new)
    {:reply, new, %{state | state: new}}
  end

  @impl true
  def handle_info(:tick, state) do
    new = check_and_register(state.auto_register?)
    state = maybe_broadcast(state, new)
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | state: new}}
  end

  def handle_info(_, state), do: {:noreply, state}

  ## Internals

  defp maybe_broadcast(%{state: old} = state, new) when old != new do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:identity, new})
    state
  end

  defp maybe_broadcast(state, _new), do: state

  defp check_and_register(auto_register?) do
    name = Lalia.scope_identity()

    cond do
      name in [nil, ""] ->
        :unknown

      true ->
        case Lalia.agents() do
          {:ok, agents} ->
            if Enum.any?(agents, &(&1.name == name)) do
              :registered
            else
              if auto_register?, do: attempt_register(name), else: :unregistered
            end

          {:error, reason} ->
            Logger.warning("LaliaBema.Identity: lalia agents failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp attempt_register(name) do
    role = Keyword.get(Lalia.config(), :role, "peer")

    case Lalia.register(name: name, role: role) do
      {:ok, _} ->
        Logger.info("LaliaBema.Identity: auto-registered scope identity #{inspect(name)}")
        :registered

      {:error, reason} ->
        Logger.warning(
          "LaliaBema.Identity: auto-register of #{inspect(name)} failed: #{inspect(reason)}"
        )

        :unregistered
    end
  end
end
