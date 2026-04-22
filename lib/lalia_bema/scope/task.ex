defmodule LaliaBema.Scope.Task do
  @moduledoc """
  Mirrors Lalia's supervisor/worker task primitive.

  The lifecycle is modelled as an `AshStateMachine`:

      published → claimed → in_progress → ready → merged
                                 ↘                 ↗
                                  blocked ──→ in_progress
  """
  use Ash.Resource,
    otp_app: :lalia_bema,
    domain: LaliaBema.Scope,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshPaperTrail.Resource]

  postgres do
    table "scope_tasks"
    repo LaliaBema.Repo
  end

  paper_trail do
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    create_version_on_destroy? false
  end

  state_machine do
    initial_states [:published]
    default_initial_state :published
    state_attribute :status

    transitions do
      transition :claim, from: :published, to: :claimed
      transition :start, from: :claimed, to: :in_progress
      transition :mark_ready, from: :in_progress, to: :ready
      transition :block, from: :in_progress, to: :blocked
      transition :unblock, from: :blocked, to: :in_progress
      transition :merge, from: :ready, to: :merged
      transition :upsert, from: [:published, :claimed, :in_progress, :blocked, :ready, :merged], to: [:published, :claimed, :in_progress, :blocked, :ready, :merged]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      primary? true
      accept [:slug, :title, :description, :owner, :project, :status, :published_at, :claimed_at, :ready_at, :merged_at]

      upsert? true
      upsert_fields [:title, :description, :owner, :project, :status, :published_at, :claimed_at, :ready_at, :merged_at]
    end

    update :claim do
      accept [:owner, :claimed_at]
      change transition_state(:claimed)
    end

    update :start do
      change transition_state(:in_progress)
    end

    update :mark_ready do
      accept [:ready_at]
      change transition_state(:ready)
    end

    update :block do
      change transition_state(:blocked)
    end

    update :unblock do
      change transition_state(:in_progress)
    end

    update :merge do
      accept [:merged_at]
      change transition_state(:merged)
    end
  end

  attributes do
    attribute :slug, :string do
      primary_key? true
      allow_nil? false
      public? true
    end

    attribute :title, :string, public?: true
    attribute :description, :string, public?: true
    attribute :owner, :string, public?: true
    attribute :project, :string, public?: true
    attribute :published_at, :utc_datetime_usec, public?: true
    attribute :claimed_at, :utc_datetime_usec, public?: true
    attribute :ready_at, :utc_datetime_usec, public?: true
    attribute :merged_at, :utc_datetime_usec, public?: true

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
