defmodule LaliaBema.Scope.Room do
  @moduledoc """
  Mirrors `rooms/<name>/ROOM.md` + `MEMBERS.md`. Upserted by room name.
  """
  use Ash.Resource,
    otp_app: :lalia_bema,
    domain: LaliaBema.Scope,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "scope_rooms"
    repo LaliaBema.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [:name, :description, :created_at, :created_by, :archived?, :member_count]

      upsert? true
      upsert_fields [:description, :created_at, :created_by, :archived?, :member_count]
    end

    update :update do
      primary? true
      accept [:description, :created_at, :created_by, :archived?, :member_count]
    end
  end

  attributes do
    attribute :name, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :description, :string, public?: true
    attribute :created_at, :utc_datetime_usec, public?: true
    attribute :created_by, :string, public?: true
    attribute :archived?, :boolean, default: false, public?: true
    attribute :member_count, :integer, default: 0, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
