defmodule LaliaBema.LaliaTest do
  use ExUnit.Case, async: false

  alias LaliaBema.Lalia
  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia

  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  describe "messaging argv" do
    test "tell shells out with peer, body, and --as scope identity" do
      LaliaStub.set_response(out: "ok\n")

      assert {:ok, "ok\n"} = Lalia.tell("alice", "hi there")
      assert LaliaStub.last_args() == ~w[tell alice hi there --as scope-human]
    end

    test "ask passes the body verbatim and threads --timeout" do
      LaliaStub.set_response(out: "ok\n")

      assert {:ok, _} = Lalia.ask("alice", "q?", timeout: 30)
      assert LaliaStub.last_args() == ~w[ask alice q? --timeout 30 --as scope-human]
    end

    test "post shells out to `lalia post <room> <body>`" do
      LaliaStub.set_response(out: "")

      assert {:ok, _} = Lalia.post("demo", "first post")
      assert LaliaStub.last_args() == ~w[post demo first post --as scope-human]
    end

    test "peek (non-destructive) honours --room flag" do
      LaliaStub.set_response(out: "pending=3\n")

      assert {:ok, %{pending: 3, raw: _}} = Lalia.peek("demo", room: true)
      assert LaliaStub.last_args() == ~w[peek demo --room --as scope-human]
    end

    test "read threads --room and --timeout" do
      LaliaStub.set_response(out: "[7 2026-04-22T10:00:00Z alice] hey\n")

      assert {:ok, %{seq: 7, from: "alice", body: "hey"}} =
               Lalia.read("demo", room: true, timeout: 0)

      assert LaliaStub.last_args() ==
               ~w[read demo --room --timeout 0 --as scope-human]
    end

    test "read_any accepts --timeout" do
      LaliaStub.set_response(out: "[1 2026-04-22 bob] hey\n")
      assert {:ok, _} = Lalia.read_any(timeout: 0)
      assert LaliaStub.last_args() == ~w[read-any --timeout 0 --as scope-human]
    end
  end

  describe "rooms" do
    test "room_create accepts --desc" do
      LaliaStub.set_response(out: "")
      assert {:ok, _} = Lalia.room_create("test", desc: "hello world")

      assert LaliaStub.last_args() ==
               ~w[room create test --desc hello world --as scope-human]
    end

    test "join / leave / participants" do
      LaliaStub.set_response(out: "alice\nbob\n")

      assert {:ok, _} = Lalia.join("demo")
      assert LaliaStub.last_args() == ~w[join demo --as scope-human]

      assert {:ok, _} = Lalia.leave("demo")
      assert LaliaStub.last_args() == ~w[leave demo --as scope-human]

      assert {:ok, ["alice", "bob"]} = Lalia.participants("demo")
      assert LaliaStub.last_args() == ~w[participants demo --as scope-human]
    end

    test "rooms gc" do
      LaliaStub.set_response(out: "")
      assert {:ok, _} = Lalia.rooms_gc()
      assert LaliaStub.last_args() == ~w[rooms gc --as scope-human]
    end
  end

  describe "identity / registry" do
    test "register does NOT thread --as (caller may not be registered yet)" do
      LaliaStub.set_response(out: "registered\n")

      assert {:ok, _} =
               Lalia.register(name: "someone", role: "peer", harness: "claude")

      args = LaliaStub.last_args()
      assert args == ~w[register --name someone --harness claude --role peer]
      refute "--as" in args
    end

    test "unregister, renew, stop thread --as" do
      LaliaStub.set_response(out: "")

      assert {:ok, _} = Lalia.unregister()
      assert LaliaStub.last_args() == ~w[unregister --as scope-human]

      assert {:ok, _} = Lalia.renew()
      assert LaliaStub.last_args() == ~w[renew --as scope-human]

      assert {:ok, _} = Lalia.stop()
      assert LaliaStub.last_args() == ~w[stop --as scope-human]
    end

    test "suggest_name trims and passes --harness" do
      LaliaStub.set_response(out: "  curious-otter-42  \n")

      assert {:ok, "curious-otter-42"} = Lalia.suggest_name(harness: "claude")
      assert LaliaStub.last_args() == ~w[suggest-name --harness claude]
    end

    test "channels parses k=v fields" do
      LaliaStub.set_response(out: "a--b last_activity=2026-04-22T10:00:00Z unread=3\n")

      assert {:ok, [%{pair: "a--b", unread: 3, last_activity: "2026-04-22T10:00:00Z"}]} =
               Lalia.channels()
    end

    test "nickname CRUD" do
      LaliaStub.set_response(out: "alice nick-alice follow\nbob nick-bob\n")

      assert {:ok,
              [
                %{name: "alice", nickname: "nick-alice", follow: true},
                %{name: "bob", nickname: "nick-bob", follow: false}
              ]} = Lalia.nickname_list()

      LaliaStub.set_response(out: "")
      assert {:ok, _} = Lalia.nickname_set("alice", "al", follow: true)
      assert LaliaStub.last_args() == ~w[nickname set alice al --follow --as scope-human]

      assert {:ok, _} = Lalia.nickname_delete("alice")
      assert LaliaStub.last_args() == ~w[nickname delete alice --as scope-human]
    end
  end

  describe "tasks" do
    test "task_publish writes to a tmp file and cleans up" do
      LaliaStub.set_response(out: "published\n")
      payload = %{slug: "demo", title: "demo"}

      assert {:ok, _} = Lalia.task_publish(payload)

      args = LaliaStub.last_args()
      assert ["task", "publish", "--file", path | _rest] = args
      refute File.exists?(path), "tmp file was not cleaned up"
    end

    test "task_claim / task_set_status / task_unassign / task_reassign" do
      LaliaStub.set_response(out: "")

      assert {:ok, _} = Lalia.task_claim("foo")
      assert LaliaStub.last_args() == ~w[task claim foo --as scope-human]

      assert {:ok, _} = Lalia.task_set_status("foo", :in_progress)

      assert LaliaStub.last_args() ==
               ~w[task set-status foo in_progress --as scope-human]

      assert {:ok, _} = Lalia.task_unassign("foo")
      assert LaliaStub.last_args() == ~w[task unassign foo --as scope-human]

      assert {:ok, _} = Lalia.task_reassign("foo", "alice")
      assert LaliaStub.last_args() == ~w[task reassign foo alice --as scope-human]
    end

    test "task_unpublish accepts supervisor flags" do
      LaliaStub.set_response(out: "")

      assert {:ok, _} =
               Lalia.task_unpublish("foo",
                 force: true,
                 wipe_worktree: true,
                 evict_owner: true
               )

      assert LaliaStub.last_args() ==
               ~w[task unpublish foo --force --wipe-worktree --evict-owner --as scope-human]
    end

    test "task_handoff" do
      LaliaStub.set_response(out: "")
      assert {:ok, _} = Lalia.task_handoff("new-supervisor")
      assert LaliaStub.last_args() == ~w[task handoff new-supervisor --as scope-human]
    end
  end

  describe "error surfacing" do
    test "non-zero exit returns {:error, {:exit, status, stderr}}" do
      LaliaStub.set_response(exit: 2, err: "boom\n")

      assert {:error, {:exit, 2, stderr}} = Lalia.tell("alice", "hi")
      assert stderr =~ "boom"
    end

    test "exit code 6 surfaces as :unauthorized so the UI can flash a hint" do
      LaliaStub.set_response(exit: 6, err: "not registered\n")

      assert {:error, :unauthorized, stderr} = Lalia.tell("alice", "hi")
      assert stderr =~ "not registered"
    end
  end

  describe "identity override" do
    test "as: false drops the --as flag" do
      LaliaStub.set_response(out: "")
      assert {:ok, _} = Lalia.post("demo", "hi", as: false)
      args = LaliaStub.last_args()
      refute "--as" in args
    end

    test "as: \"other\" replaces the configured caller" do
      LaliaStub.set_response(out: "")
      assert {:ok, _} = Lalia.post("demo", "hi", as: "other")
      assert LaliaStub.last_args() == ~w[post demo hi --as other]
    end
  end

  describe "telemetry" do
    test "emits [:lalia_bema, :lalia, :cmd] with verb and status metadata" do
      ref = make_ref()
      test_pid = self()
      handler_id = "test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:lalia_bema, :lalia, :cmd],
        fn _event, _meas, meta, _ -> send(test_pid, {ref, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      LaliaStub.set_response(out: "")
      {:ok, _} = Lalia.tell("alice", "hi")
      assert_receive {^ref, %{verb: :tell, status: :ok}}, 500

      LaliaStub.set_response(exit: 6)
      Lalia.tell("alice", "hi")
      assert_receive {^ref, %{verb: :tell, status: :unauthorized}}, 500
    end
  end
end
