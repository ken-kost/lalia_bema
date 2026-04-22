defmodule LaliaBema.Scope.Agent do
  @moduledoc """
  Mirrors an entry in Lalia's `registry/<ULID>.json`. One row per registered
  agent. Upserted idempotently by `agent_id`.
  """
  use Ash.Resource,
    otp_app: :lalia_bema,
    domain: LaliaBema.Scope,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "scope_agents"
    repo LaliaBema.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [
        :agent_id,
        :name,
        :project,
        :branch,
        :harness,
        :registered_at,
        :last_seen_at,
        :lease_expires_at,
        :repo_root,
        :pubkey
      ]

      upsert? true
      upsert_fields [
        :name,
        :project,
        :branch,
        :harness,
        :registered_at,
        :last_seen_at,
        :lease_expires_at,
        :repo_root,
        :pubkey
      ]
    end

    update :update do
      primary? true
      accept [
        :name,
        :project,
        :branch,
        :harness,
        :registered_at,
        :last_seen_at,
        :lease_expires_at,
        :repo_root,
        :pubkey
      ]
    end
  end

  attributes do
    attribute :agent_id, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :project, :string, public?: true
    attribute :branch, :string, public?: true
    attribute :harness, :string, public?: true
    attribute :registered_at, :utc_datetime_usec, public?: true
    attribute :last_seen_at, :utc_datetime_usec, public?: true
    attribute :lease_expires_at, :utc_datetime_usec, public?: true
    attribute :repo_root, :string, public?: true
    attribute :pubkey, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :active?, :boolean, expr(not is_nil(lease_expires_at) and lease_expires_at > now()) do
      public? true
    end
  end
end
