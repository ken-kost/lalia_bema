defmodule LaliaBema.IdentityTest do
  use ExUnit.Case, async: false

  alias LaliaBema.Identity
  alias LaliaBema.Test.LaliaStub

  setup :stub_lalia

  defp stub_lalia(tags), do: LaliaStub.stub_lalia(tags)

  test "reports :registered when scope identity appears in `lalia agents`" do
    LaliaStub.set_response(
      out: """
      repo: ~/src/demo
        main-wt scope-human main idle claude 2026-04-22T10:00:00Z
      """
    )

    {:ok, pid} = Identity.start_link(name: :test_identity_ok, auto_register?: false)
    :ok = wait_for_state(pid, :registered)
    GenServer.stop(pid)
  end

  test "auto-registers when scope identity is missing" do
    LaliaStub.set_response(
      out: """
      repo: ~/src/demo
        main-wt alice main idle claude 2026-04-22T10:00:00Z
      """
    )

    {:ok, pid} = Identity.start_link(name: :test_identity_register, auto_register?: true)
    :ok = wait_for_state(pid, :registered)

    args_log = LaliaStub.all_args()

    assert Enum.any?(args_log, fn argv ->
             argv == ~w[register --name scope-human --role peer]
           end)

    GenServer.stop(pid)
  end

  test "broadcasts {:identity, state} on state transitions" do
    LaliaStub.set_response(
      out: """
      repo: ~/src/demo
        main-wt scope-human main idle claude 2026-04-22T10:00:00Z
      """
    )

    Phoenix.PubSub.subscribe(LaliaBema.PubSub, "feed")

    {:ok, pid} = Identity.start_link(name: :test_identity_bcast, auto_register?: false)
    assert_receive {:identity, :registered}, 1_000

    GenServer.stop(pid)
  end

  defp wait_for_state(pid, target, attempts \\ 50) do
    if attempts <= 0 do
      :timeout
    else
      case GenServer.call(pid, :state) do
        ^target ->
          :ok

        _other ->
          Process.sleep(20)
          wait_for_state(pid, target, attempts - 1)
      end
    end
  end
end
