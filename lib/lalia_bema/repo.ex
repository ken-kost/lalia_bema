defmodule LaliaBema.Repo do
  use Ecto.Repo,
    otp_app: :lalia_bema,
    adapter: Ecto.Adapters.Postgres
end
