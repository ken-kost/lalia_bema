defmodule LaliaBema.Test.LaliaStub do
  @moduledoc """
  Helpers for driving the `test/support/bin/lalia` stub binary from tests.

  Points the `LaliaBema.Lalia` wrapper at the stub script, lets each test
  pre-seed stdout / stderr / exit status, and provides a tmp argv log so
  the test can assert the exact `System.cmd` argv that went out — which is
  the surface Phase 4 cares about.

      setup :stub_lalia

      test "post shells out with the right argv" do
        LaliaStub.set_response(exit: 0)
        assert {:ok, _} = Lalia.post("demo", "hi")
        assert LaliaStub.last_args() == ~w[post demo hi --as scope-human]
      end
  """

  @bin Path.expand("bin/lalia", __DIR__)

  @doc """
  ExUnit `setup` that swaps `:lalia_bema, :lalia, :binary` for the stub and
  points `LALIA_STUB_ARGS_LOG` at a per-test file. The previous config is
  restored via `on_exit`.
  """
  def stub_lalia(_tags) do
    prev = Application.get_env(:lalia_bema, :lalia, [])
    log_path = Path.join(System.tmp_dir!(), "lalia-stub-#{System.unique_integer([:positive])}.log")
    File.write!(log_path, "")

    Application.put_env(:lalia_bema, :lalia,
      Keyword.merge(prev, binary: @bin, home: System.tmp_dir!(), workspace: System.tmp_dir!())
    )

    System.put_env("LALIA_STUB_ARGS_LOG", log_path)
    System.delete_env("LALIA_STUB_OUT")
    System.delete_env("LALIA_STUB_ERR")
    System.delete_env("LALIA_STUB_EXIT")

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:lalia_bema, :lalia, prev)
      System.delete_env("LALIA_STUB_ARGS_LOG")
      System.delete_env("LALIA_STUB_OUT")
      System.delete_env("LALIA_STUB_ERR")
      System.delete_env("LALIA_STUB_EXIT")
      File.rm(log_path)
    end)

    %{lalia_stub_log: log_path}
  end

  @doc "Set the response the next stub invocation will produce."
  def set_response(opts \\ []) do
    if out = Keyword.get(opts, :out), do: System.put_env("LALIA_STUB_OUT", out)
    if err = Keyword.get(opts, :err), do: System.put_env("LALIA_STUB_ERR", err)
    if exit = Keyword.get(opts, :exit), do: System.put_env("LALIA_STUB_EXIT", Integer.to_string(exit))
    :ok
  end

  @doc "Path to the fake binary, useful for tests that want to set PATH explicitly."
  def binary_path, do: @bin

  @doc "Raw argv lines captured this test."
  def all_args do
    case System.get_env("LALIA_STUB_ARGS_LOG") do
      nil ->
        []

      path ->
        case File.read(path) do
          {:ok, content} ->
            content
            |> String.split("\n", trim: true)
            |> Enum.map(fn "argv\t" <> rest -> String.split(rest, " ", trim: true) end)

          _ ->
            []
        end
    end
  end

  @doc "argv of the most recent stub invocation."
  def last_args do
    case Enum.reverse(all_args()) do
      [last | _] -> last
      [] -> nil
    end
  end

  @doc "Clear the argv log so subsequent `last_args/0` returns only new calls."
  def clear_args do
    case System.get_env("LALIA_STUB_ARGS_LOG") do
      nil -> :ok
      path -> File.write(path, "")
    end
  end
end
