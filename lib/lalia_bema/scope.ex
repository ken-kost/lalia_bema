defmodule LaliaBema.Scope do
  @moduledoc """
  Ash domain backing the Lalia Scope sidecar's durable store.

  Hosts the `Agent`, `Room`, `Message`, and `Task` resources. Exposes code
  interface functions so LiveViews and the Watcher can call into Ash without
  hand-rolled queries.
  """
  use Ash.Domain,
    otp_app: :lalia_bema,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource LaliaBema.Scope.Agent do
      define :list_agents, action: :read
      define :get_agent, action: :read, get_by: [:agent_id]
      define :upsert_agent, action: :upsert
    end

    resource LaliaBema.Scope.Room do
      define :list_rooms, action: :read
      define :get_room, action: :read, get_by: [:name]
      define :upsert_room, action: :upsert
    end

    resource LaliaBema.Scope.Message do
      define :list_messages, action: :read
      define :upsert_message, action: :upsert
    end

    resource LaliaBema.Scope.Task do
      define :list_tasks, action: :read
      define :get_task, action: :read, get_by: [:slug]
      define :upsert_task, action: :upsert
      define :claim_task, action: :claim
      define :start_task, action: :start
      define :mark_task_ready, action: :mark_ready
      define :block_task, action: :block
      define :unblock_task, action: :unblock
      define :merge_task, action: :merge
    end
  end
end
