defmodule LaliaBema.WatcherTest do
  @moduledoc """
  Integration test for `LaliaBema.Watcher`.

  Requires the real `lalia` binary on PATH. The test spins up an isolated
  `LALIA_HOME` / `LALIA_WORKSPACE` tree so it doesn't touch the user's
  running daemon. If the binary is missing, the test is skipped.
  """
  use ExUnit.Case, async: false

  alias LaliaBema.Watcher

  @moduletag :integration

  setup_all do
    case System.find_executable("lalia") do
      nil -> {:skip, "lalia binary not on PATH"}
      _path -> :ok
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "lalia_bema_#{System.unique_integer([:positive])}")
    home = Path.join(tmp, "lalia")
    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(home)
    File.mkdir_p!(workspace)

    prev = Application.get_env(:lalia_bema, :lalia)

    Application.put_env(:lalia_bema, :lalia,
      binary: "lalia",
      home: home,
      workspace: workspace,
      caller: "test-a",
      watcher_enabled: false
    )

    on_exit(fn ->
      run(home, workspace, ["stop"], "test-a")
      Application.put_env(:lalia_bema, :lalia, prev)
      File.rm_rf!(tmp)
    end)

    {_, 0} = run(home, workspace, ["register", "--name", "test-a"], nil)
    {_, 0} = run(home, workspace, ["register", "--name", "test-b"], nil)

    %{home: home, workspace: workspace}
  end

  test "broadcasts new messages as they're committed", %{workspace: workspace} do
    Phoenix.PubSub.subscribe(LaliaBema.PubSub, Watcher.topic())

    start_supervised!({Watcher, workspace: workspace})
    # Give inotify a moment to prime its watches before we create files.
    :timer.sleep(200)

    assert {_, 0} = run_env(["tell", "test-b", "hello", "--as", "test-a"])

    assert_receive {:new_message, %Watcher.Message{from: "test-a", body: "hello", kind: :channel}},
                   3_000
  end

  test "does not re-broadcast pre-existing messages on boot", %{workspace: workspace} do
    assert {_, 0} = run_env(["tell", "test-b", "pre-existing", "--as", "test-a"])
    # Wait for the git commit to land.
    :timer.sleep(300)

    Phoenix.PubSub.subscribe(LaliaBema.PubSub, Watcher.topic())
    start_supervised!({Watcher, workspace: workspace})

    refute_receive {:new_message, _}, 500

    snap = Watcher.snapshot()
    assert Enum.any?(snap.recent, &(&1.body == "pre-existing"))
  end

  defp run_env(args) do
    cfg = Application.fetch_env!(:lalia_bema, :lalia)
    run(Keyword.fetch!(cfg, :home), Keyword.fetch!(cfg, :workspace), args, Keyword.get(cfg, :caller))
  end

  defp run(home, workspace, args, caller) do
    env = [{"LALIA_HOME", home}, {"LALIA_WORKSPACE", workspace}]
    env = if caller, do: [{"LALIA_NAME", caller} | env], else: env
    System.cmd("lalia", args, env: env, stderr_to_stdout: true)
  end
end
