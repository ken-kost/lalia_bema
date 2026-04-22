defmodule LaliaBema.WatcherWriteThroughTest do
  @moduledoc """
  Exercises the Ash write-through path in `LaliaBema.Watcher` without needing
  the real `lalia` binary. A bare workspace with a single message file is
  enough — we drop a second file into it after the Watcher is running and
  assert both the PubSub broadcast fires and the row lands in Ash.
  """
  use LaliaBema.DataCase, async: false

  alias LaliaBema.Scope
  alias LaliaBema.Watcher

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "lalia_bema_wtr_#{System.unique_integer([:positive])}")

    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(Path.join(workspace, "rooms/demo"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    prev = Application.get_env(:lalia_bema, :lalia)

    Application.put_env(:lalia_bema, :lalia,
      binary: "lalia",
      home: Path.join(tmp, "lalia"),
      workspace: workspace,
      caller: "test",
      watcher_enabled: false
    )

    on_exit(fn -> Application.put_env(:lalia_bema, :lalia, prev) end)

    %{workspace: workspace}
  end

  test "new message file lands in Ash and broadcasts on PubSub", %{workspace: workspace} do
    Phoenix.PubSub.subscribe(LaliaBema.PubSub, Watcher.topic())
    start_supervised!({Watcher, workspace: workspace})
    :timer.sleep(100)

    write_message(workspace, "rooms/demo", 42, "alice", "round-trip", "2026-04-22T12:00:00Z")

    assert_receive {:new_message, %Watcher.Message{from: "alice", seq: 42}}, 2_000

    # Give the write-through a moment to commit.
    :timer.sleep(150)

    [row] =
      Scope.list_messages!(
        query: [filter: [kind: :room, target: "demo", seq: 42, from: "alice"]]
      )

    assert row.body == "round-trip"
    assert row.path =~ "rooms/demo"
  end

  defp write_message(workspace, subdir, seq, from, body, ts) do
    path =
      Path.join(workspace, "#{subdir}/#{String.pad_leading(Integer.to_string(seq), 6, "0")}-#{from}.md")

    File.write!(path, """
    ---
    seq: #{seq}
    from: #{from}
    ts: #{ts}
    ---

    #{body}
    """)
  end
end
