defmodule LaliaBema.Scope.Message do
  @moduledoc """
  A single message posted to a room or a peer channel in the Lalia workspace.

  Identity is `{kind, target, seq, from}` so repeated backfill and live
  ingestion share one `:upsert` action without duplicating rows.
  """
  use Ash.Resource,
    otp_app: :lalia_bema,
    domain: LaliaBema.Scope,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "scope_messages"
    repo LaliaBema.Repo
  end

  paper_trail do
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    create_version_on_destroy? false
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [:kind, :target, :from, :seq, :body, :posted_at, :path]

      upsert? true
      upsert_identity :kind_target_seq_from
      upsert_fields [:body, :posted_at, :path]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :kind, :atom,
      constraints: [one_of: [:room, :channel]],
      allow_nil?: false,
      public?: true

    attribute :target, :string, allow_nil?: false, public?: true
    attribute :from, :string, allow_nil?: false, public?: true
    attribute :seq, :integer, allow_nil?: false, public?: true
    attribute :body, :string, public?: true
    attribute :posted_at, :utc_datetime_usec, public?: true
    attribute :path, :string, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :kind_target_seq_from, [:kind, :target, :seq, :from]
  end
end
