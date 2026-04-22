defmodule LaliaBema do
  @moduledoc """
  Top-level entry points for the Lalia Scope sidecar.

  Holds a handful of helpers — most work happens inside `LaliaBema.Lalia`
  (the CLI wrapper), `LaliaBema.Scope` (the Ash domain), and the LiveViews
  under `LaliaBemaWeb`.
  """

  @doc """
  Configured scope identity used to sign every write that goes out via the
  `lalia` CLI. Pulled from `config :lalia_bema, :lalia, caller: …` and
  overridable at runtime via `LALIA_NAME`.
  """
  @spec scope_identity() :: String.t() | nil
  def scope_identity do
    LaliaBema.Lalia.scope_identity()
  end

  @doc """
  Registration state as observed by `LaliaBema.Identity`.

  Returns `:registered`, `:unregistered`, `:unknown` (no check has run yet
  or the CLI is unreachable), or the raw error tuple from the last check.
  Used by LiveViews to decide whether to render the "not registered" banner.
  """
  @spec identity_state() :: :registered | :unregistered | :unknown | {:error, term()}
  def identity_state, do: LaliaBema.Identity.state()
end
