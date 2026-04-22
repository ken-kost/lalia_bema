defmodule LaliaBema.Lalia do
  @moduledoc """
  Thin wrapper around the `lalia` CLI — both read and write verbs.

  Reads the binary path, workspace, home, and scope identity from
  `Application.get_env(:lalia_bema, :lalia)` so tests can point the sidecar
  at a fixture workspace and swap the binary for a stub script on `$PATH`.

  Every shell-out threads the configured scope identity via `--as <name>` so
  writes are signed by a registered Lalia agent. Callers may override per
  invocation with `as: "other-name"`.

  Return shape:

      {:ok, parsed_value | :ok | raw_string}
      {:error, {:exit, status, stderr}}
      {:error, :unauthorized, stderr}   # exit status 6

  Every call emits a `[:lalia_bema, :lalia, :cmd]` telemetry span with
  `%{verb: verb, status: status, duration_us: n}` metadata.
  """

  @type agent :: %{
          name: String.t(),
          worktree: String.t(),
          branch: String.t(),
          status: String.t(),
          harness: String.t(),
          last_seen: String.t(),
          repo: String.t()
        }

  @type room :: %{name: String.t(), members: integer(), messages: integer()}

  ## Read verbs

  @spec agents() :: {:ok, [agent]} | {:error, term()}
  def agents do
    with {:ok, out} <- cmd(["agents"], verb: :agents) do
      {:ok, parse_agents(out)}
    end
  end

  @spec rooms() :: {:ok, [room]} | {:error, term()}
  def rooms do
    with {:ok, out} <- cmd(["rooms"], verb: :rooms) do
      {:ok, parse_rooms(out)}
    end
  end

  @doc """
  Shells out to `lalia history`. Returns a list of %{seq, ts, from, body}.
  Pass `kind: :room` to target a room instead of a peer.
  """
  @spec history(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def history(target, opts \\ []) do
    args =
      case Keyword.get(opts, :kind, :peer) do
        :room -> ["history", target, "--room"]
        _ -> ["history", target]
      end

    with {:ok, out} <- cmd(args, verb: :history) do
      {:ok, parse_history(out)}
    end
  end

  ## Messaging

  @doc "tell <peer> <body>. Fire-and-forget DM."
  @spec tell(String.t(), String.t(), keyword()) :: {:ok, String.t()} | error()
  def tell(peer, body, opts \\ []) when is_binary(peer) and is_binary(body) do
    cmd(["tell", peer, body], Keyword.put_new(opts, :verb, :tell))
  end

  @doc "ask <peer> <body> [--timeout N]. Returns raw CLI output."
  @spec ask(String.t(), String.t(), keyword()) :: {:ok, String.t()} | error()
  def ask(peer, body, opts \\ []) when is_binary(peer) and is_binary(body) do
    args = ["ask", peer, body] ++ timeout_flag(opts)
    cmd(args, Keyword.put_new(opts, :verb, :ask))
  end

  @doc "post <room> <body>."
  @spec post(String.t(), String.t(), keyword()) :: {:ok, String.t()} | error()
  def post(room, body, opts \\ []) when is_binary(room) and is_binary(body) do
    cmd(["post", room, body], Keyword.put_new(opts, :verb, :post))
  end

  @doc "peek <target> [--room] — non-destructive mailbox preview."
  @spec peek(String.t(), keyword()) :: {:ok, map()} | error()
  def peek(target, opts \\ []) when is_binary(target) do
    args =
      ["peek", target]
      |> maybe_append(Keyword.get(opts, :room, false), "--room")

    with {:ok, out} <- cmd(args, Keyword.put_new(opts, :verb, :peek)) do
      {:ok, parse_peek(out)}
    end
  end

  @doc "read <target> [--room] [--timeout N] — consumes a message (destructive)."
  @spec read(String.t(), keyword()) :: {:ok, map()} | error()
  def read(target, opts \\ []) when is_binary(target) do
    args =
      (["read", target]
       |> maybe_append(Keyword.get(opts, :room, false), "--room")) ++ timeout_flag(opts)

    with {:ok, out} <- cmd(args, Keyword.put_new(opts, :verb, :read)) do
      {:ok, parse_read(out)}
    end
  end

  @doc "read-any [--timeout N] — consume the next message from any mailbox."
  @spec read_any(keyword()) :: {:ok, map()} | error()
  def read_any(opts \\ []) do
    args = ["read-any"] ++ timeout_flag(opts)

    with {:ok, out} <- cmd(args, Keyword.put_new(opts, :verb, :read_any)) do
      {:ok, parse_read(out)}
    end
  end

  ## Rooms

  @doc "room create <name> [--desc <text>]."
  @spec room_create(String.t(), keyword()) :: {:ok, String.t()} | error()
  def room_create(name, opts \\ []) when is_binary(name) do
    args =
      ["room", "create", name]
      |> maybe_append_kv("--desc", Keyword.get(opts, :desc))

    cmd(args, Keyword.put_new(opts, :verb, :room_create))
  end

  @doc "join <room>."
  @spec join(String.t(), keyword()) :: {:ok, String.t()} | error()
  def join(room, opts \\ []) when is_binary(room) do
    cmd(["join", room], Keyword.put_new(opts, :verb, :join))
  end

  @doc "leave <room>."
  @spec leave(String.t(), keyword()) :: {:ok, String.t()} | error()
  def leave(room, opts \\ []) when is_binary(room) do
    cmd(["leave", room], Keyword.put_new(opts, :verb, :leave))
  end

  @doc "participants <room> — list room members."
  @spec participants(String.t(), keyword()) :: {:ok, [String.t()]} | error()
  def participants(room, opts \\ []) when is_binary(room) do
    with {:ok, out} <- cmd(["participants", room], Keyword.put_new(opts, :verb, :participants)) do
      {:ok, parse_participants(out)}
    end
  end

  @doc "rooms gc — supervisor-only mass archive sweep."
  @spec rooms_gc(keyword()) :: {:ok, String.t()} | error()
  def rooms_gc(opts \\ []) do
    cmd(["rooms", "gc"], Keyword.put_new(opts, :verb, :rooms_gc))
  end

  ## Identity / registry

  @doc """
  register [--name N] [--harness H] [--model M] [--project P] [--role R].

  Unlike other verbs, `register` never threads `--as` because the caller may
  not yet be registered. Pass `as: false` to be explicit.
  """
  @spec register(keyword()) :: {:ok, String.t()} | error()
  def register(opts \\ []) do
    args =
      ["register"]
      |> maybe_append_kv("--name", Keyword.get(opts, :name))
      |> maybe_append_kv("--harness", Keyword.get(opts, :harness))
      |> maybe_append_kv("--model", Keyword.get(opts, :model))
      |> maybe_append_kv("--project", Keyword.get(opts, :project))
      |> maybe_append_kv("--role", Keyword.get(opts, :role))

    opts = Keyword.merge([as: false, verb: :register], opts)
    cmd(args, opts)
  end

  @doc "unregister."
  @spec unregister(keyword()) :: {:ok, String.t()} | error()
  def unregister(opts \\ []) do
    cmd(["unregister"], Keyword.put_new(opts, :verb, :unregister))
  end

  @doc "suggest-name [--harness H]."
  @spec suggest_name(keyword()) :: {:ok, String.t()} | error()
  def suggest_name(opts \\ []) do
    args =
      ["suggest-name"]
      |> maybe_append_kv("--harness", Keyword.get(opts, :harness))

    opts = Keyword.merge([as: false, verb: :suggest_name], opts)

    with {:ok, out} <- cmd(args, opts) do
      {:ok, String.trim(out)}
    end
  end

  @doc "renew — extend the caller's lease."
  @spec renew(keyword()) :: {:ok, String.t()} | error()
  def renew(opts \\ []) do
    cmd(["renew"], Keyword.put_new(opts, :verb, :renew))
  end

  @doc "stop — terminate the daemon (supervisor-only on shared deployments)."
  @spec stop(keyword()) :: {:ok, String.t()} | error()
  def stop(opts \\ []) do
    cmd(["stop"], Keyword.put_new(opts, :verb, :stop))
  end

  @doc "channels — list peer channels the caller can see."
  @spec channels(keyword()) :: {:ok, [map()]} | error()
  def channels(opts \\ []) do
    with {:ok, out} <- cmd(["channels"], Keyword.put_new(opts, :verb, :channels)) do
      {:ok, parse_channels(out)}
    end
  end

  @doc "nickname list."
  @spec nickname_list(keyword()) :: {:ok, [map()]} | error()
  def nickname_list(opts \\ []) do
    with {:ok, out} <- cmd(["nickname", "list"], Keyword.put_new(opts, :verb, :nickname_list)) do
      {:ok, parse_nickname_list(out)}
    end
  end

  @doc "nickname show <name>."
  @spec nickname_show(String.t(), keyword()) :: {:ok, String.t()} | error()
  def nickname_show(name, opts \\ []) when is_binary(name) do
    cmd(["nickname", "show", name], Keyword.put_new(opts, :verb, :nickname_show))
  end

  @doc "nickname set <name> <nickname> [--follow]."
  @spec nickname_set(String.t(), String.t(), keyword()) :: {:ok, String.t()} | error()
  def nickname_set(name, nickname, opts \\ []) when is_binary(name) and is_binary(nickname) do
    args =
      ["nickname", "set", name, nickname]
      |> maybe_append(Keyword.get(opts, :follow, false), "--follow")

    cmd(args, Keyword.put_new(opts, :verb, :nickname_set))
  end

  @doc "nickname delete <name>."
  @spec nickname_delete(String.t(), keyword()) :: {:ok, String.t()} | error()
  def nickname_delete(name, opts \\ []) when is_binary(name) do
    cmd(["nickname", "delete", name], Keyword.put_new(opts, :verb, :nickname_delete))
  end

  ## Tasks

  @doc """
  task publish --file <tmp-json>. Writes the payload to a tmp file, shells
  out, then cleans up the tmp file.
  """
  @spec task_publish(String.t() | map(), keyword()) :: {:ok, String.t()} | error()
  def task_publish(payload, opts \\ [])

  def task_publish(payload, opts) when is_map(payload) do
    case Jason.encode(payload) do
      {:ok, json} -> task_publish(json, opts)
      {:error, e} -> {:error, {:encode, e}}
    end
  end

  def task_publish(payload_json, opts) when is_binary(payload_json) do
    path = write_tmp(payload_json, "task-publish", ".json")

    try do
      cmd(["task", "publish", "--file", path], Keyword.put_new(opts, :verb, :task_publish))
    after
      File.rm(path)
    end
  end

  @doc "task bulletin [--project P]."
  @spec task_bulletin(keyword()) :: {:ok, [map()]} | error()
  def task_bulletin(opts \\ []) do
    args =
      ["task", "bulletin"]
      |> maybe_append_kv("--project", Keyword.get(opts, :project))

    with {:ok, out} <- cmd(args, Keyword.put_new(opts, :verb, :task_bulletin)) do
      {:ok, parse_task_bulletin(out)}
    end
  end

  @doc "task show [<slug>]."
  @spec task_show(String.t() | nil, keyword()) :: {:ok, map()} | error()
  def task_show(slug \\ nil, opts \\ [])

  def task_show(nil, opts) do
    with {:ok, out} <- cmd(["task", "show"], Keyword.put_new(opts, :verb, :task_show)) do
      {:ok, parse_task_show(out)}
    end
  end

  def task_show(slug, opts) when is_binary(slug) do
    with {:ok, out} <- cmd(["task", "show", slug], Keyword.put_new(opts, :verb, :task_show)) do
      {:ok, parse_task_show(out)}
    end
  end

  @doc "task list."
  @spec task_list(keyword()) :: {:ok, [map()]} | error()
  def task_list(opts \\ []) do
    with {:ok, out} <- cmd(["task", "list"], Keyword.put_new(opts, :verb, :task_list)) do
      {:ok, parse_task_bulletin(out)}
    end
  end

  @doc "task claim <slug>."
  @spec task_claim(String.t(), keyword()) :: {:ok, String.t()} | error()
  def task_claim(slug, opts \\ []) when is_binary(slug) do
    cmd(["task", "claim", slug], Keyword.put_new(opts, :verb, :task_claim))
  end

  @doc "task set-status <slug> <status>."
  @spec task_set_status(String.t(), String.t() | atom(), keyword()) ::
          {:ok, String.t()} | error()
  def task_set_status(slug, status, opts \\ []) when is_binary(slug) do
    cmd(
      ["task", "set-status", slug, to_string(status)],
      Keyword.put_new(opts, :verb, :task_set_status)
    )
  end

  @doc "task unassign <slug>."
  @spec task_unassign(String.t(), keyword()) :: {:ok, String.t()} | error()
  def task_unassign(slug, opts \\ []) when is_binary(slug) do
    cmd(["task", "unassign", slug], Keyword.put_new(opts, :verb, :task_unassign))
  end

  @doc "task reassign <slug> <agent>."
  @spec task_reassign(String.t(), String.t(), keyword()) :: {:ok, String.t()} | error()
  def task_reassign(slug, agent, opts \\ []) when is_binary(slug) and is_binary(agent) do
    cmd(["task", "reassign", slug, agent], Keyword.put_new(opts, :verb, :task_reassign))
  end

  @doc """
  task unpublish <slug> [--force] [--wipe-worktree] [--evict-owner].
  Flags: `:force`, `:wipe_worktree`, `:evict_owner`.
  """
  @spec task_unpublish(String.t(), keyword()) :: {:ok, String.t()} | error()
  def task_unpublish(slug, opts \\ []) when is_binary(slug) do
    args =
      ["task", "unpublish", slug]
      |> maybe_append(Keyword.get(opts, :force, false), "--force")
      |> maybe_append(Keyword.get(opts, :wipe_worktree, false), "--wipe-worktree")
      |> maybe_append(Keyword.get(opts, :evict_owner, false), "--evict-owner")

    cmd(args, Keyword.put_new(opts, :verb, :task_unpublish))
  end

  @doc "task handoff <new-supervisor>."
  @spec task_handoff(String.t(), keyword()) :: {:ok, String.t()} | error()
  def task_handoff(new_supervisor, opts \\ []) when is_binary(new_supervisor) do
    cmd(["task", "handoff", new_supervisor], Keyword.put_new(opts, :verb, :task_handoff))
  end

  ## Config / identity

  @doc false
  def config, do: Application.get_env(:lalia_bema, :lalia, [])

  @doc "Configured scope identity (used for `--as`)."
  @spec scope_identity() :: String.t() | nil
  def scope_identity do
    Keyword.get(config(), :caller)
  end

  ## Internals

  @typep error :: {:error, {:exit, non_neg_integer(), String.t()}} | {:error, :unauthorized, String.t()} | {:error, term()}

  defp cmd(args, opts) do
    cfg = config()
    bin = Keyword.fetch!(cfg, :binary)
    verb = Keyword.get(opts, :verb, :unknown)

    as =
      case Keyword.fetch(opts, :as) do
        {:ok, false} -> nil
        {:ok, nil} -> nil
        {:ok, other} when is_binary(other) -> other
        :error -> Keyword.get(cfg, :caller)
      end

    env = [
      {"LALIA_HOME", Keyword.fetch!(cfg, :home)},
      {"LALIA_WORKSPACE", Keyword.fetch!(cfg, :workspace)}
    ]

    args = if as, do: args ++ ["--as", as], else: args
    start = System.monotonic_time()

    result =
      try do
        case System.cmd(bin, args, env: env, stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, 6} -> {:error, :unauthorized, out}
          {out, status} -> {:error, {:exit, status, out}}
        end
      rescue
        e in ErlangError -> {:error, e}
      end

    duration_us =
      System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

    status_atom =
      case result do
        {:ok, _} -> :ok
        {:error, :unauthorized, _} -> :unauthorized
        {:error, {:exit, _, _}} -> :error
        {:error, _} -> :crash
      end

    :telemetry.execute(
      [:lalia_bema, :lalia, :cmd],
      %{duration_us: duration_us},
      %{verb: verb, status: status_atom, args: args}
    )

    result
  end

  defp maybe_append(args, true, flag), do: args ++ [flag]
  defp maybe_append(args, _, _), do: args

  defp maybe_append_kv(args, _key, nil), do: args
  defp maybe_append_kv(args, _key, ""), do: args
  defp maybe_append_kv(args, key, value), do: args ++ [key, to_string(value)]

  defp timeout_flag(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> []
      n when is_integer(n) -> ["--timeout", Integer.to_string(n)]
      str when is_binary(str) -> ["--timeout", str]
    end
  end

  defp write_tmp(contents, prefix, suffix) do
    name = "#{prefix}-#{System.unique_integer([:positive])}#{suffix}"
    path = Path.join(System.tmp_dir!(), name)
    File.write!(path, contents)
    path
  end

  ## Parsers

  defp parse_agents(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce({nil, []}, fn line, {repo, acc} ->
      cond do
        String.starts_with?(line, "repo:") ->
          {String.trim_leading(line, "repo:") |> String.trim(), acc}

        String.starts_with?(line, " ") ->
          case String.split(line, ~r/\s+/, trim: true) do
            [worktree_kind, name, branch, status, harness | rest] ->
              last_seen = rest |> Enum.join(" ") |> String.trim()

              agent = %{
                repo: repo || "",
                worktree: String.trim_trailing(worktree_kind, ":"),
                name: name,
                branch: branch,
                status: status,
                harness: harness,
                last_seen: last_seen
              }

              {repo, [agent | acc]}

            _ ->
              {repo, acc}
          end

        true ->
          {repo, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp parse_rooms(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [name | kvs] = String.split(line, ~r/\s+/, trim: true)

      props =
        kvs
        |> Enum.map(&String.split(&1, "=", parts: 2))
        |> Enum.reduce(%{}, fn
          [k, v], acc -> Map.put(acc, k, v)
          _, acc -> acc
        end)

      %{
        name: name,
        members: parse_int(props["members"]),
        messages: parse_int(props["messages"])
      }
    end)
  end

  defp parse_history(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^\[(\d+)\s+(\S+)\s+(\S+)\]\s(.*)$/, line) do
        [_, seq, ts, from, body] ->
          [%{seq: parse_int(seq), ts: ts, from: from, body: body} | acc]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_peek(output) do
    # The CLI prints lines like `pending=N` and an optional preview block.
    # We expose the full body plus a best-effort pending count.
    trimmed = String.trim(output)

    pending =
      case Regex.run(~r/pending[=:\s]+(\d+)/i, trimmed) do
        [_, n] -> parse_int(n)
        _ -> nil
      end

    %{raw: trimmed, pending: pending}
  end

  defp parse_read(output) do
    trimmed = String.trim(output)

    case Regex.run(~r/^\[(\d+)\s+(\S+)\s+(\S+)\]\s(.*)$/s, trimmed) do
      [_, seq, ts, from, body] ->
        %{seq: parse_int(seq), ts: ts, from: from, body: body, raw: trimmed}

      _ ->
        %{raw: trimmed}
    end
  end

  defp parse_participants(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_channels(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [pair | kvs] = String.split(line, ~r/\s+/, trim: true)

      props =
        kvs
        |> Enum.map(&String.split(&1, "=", parts: 2))
        |> Enum.reduce(%{}, fn
          [k, v], acc -> Map.put(acc, k, v)
          _, acc -> acc
        end)

      %{
        pair: pair,
        last_activity: Map.get(props, "last_activity") || Map.get(props, "last"),
        unread: parse_int(props["unread"])
      }
    end)
  end

  defp parse_nickname_list(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, ~r/\s+/, trim: true, parts: 3))
    |> Enum.flat_map(fn
      [name, nickname | rest] ->
        follow? =
          case rest do
            ["follow"] -> true
            ["follow=true"] -> true
            _ -> false
          end

        [%{name: name, nickname: nickname, follow: follow?}]

      _ ->
        []
    end)
  end

  defp parse_task_bulletin(output) do
    # Each task starts with "task <slug>" or a table-style row.
    # Be generous: split into blocks, extract "slug", "status", "owner",
    # "title" or the first non-header line.
    output
    |> String.split(~r/\n(?=task |slug:|\w+[\s]+\w+[\s]+\w+)/m, trim: true)
    |> Enum.map(&parse_task_block/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_task_show(output) do
    parse_task_block(String.trim(output)) || %{raw: String.trim(output)}
  end

  defp parse_task_block(block) do
    block = String.trim(block)

    if block == "" do
      nil
    else
      lines = String.split(block, "\n", trim: true)

      # Two common shapes:
      #   1. "task <slug>\n  status: …\n  owner: …\n  title: …"
      #   2. "<slug> <status> <owner> <title>"
      slug = first_match(lines, [~r/^task\s+(\S+)/, ~r/^slug:\s*(\S+)/])
      status = first_match(lines, [~r/^\s*status:\s*(\S+)/, ~r/\s+(published|claimed|in-progress|in_progress|ready|blocked|merged)\s+/])
      owner = first_match(lines, [~r/^\s*owner:\s*(\S+)/])
      project = first_match(lines, [~r/^\s*project:\s*(\S+)/])
      title = first_match(lines, [~r/^\s*title:\s*(.+)$/])

      if slug do
        %{
          slug: slug,
          status: status,
          owner: owner,
          project: project,
          title: title,
          raw: block
        }
      else
        nil
      end
    end
  end

  defp first_match(lines, regexes) do
    Enum.find_value(lines, fn line ->
      Enum.find_value(regexes, fn re ->
        case Regex.run(re, line) do
          [_, value] -> String.trim(value)
          _ -> nil
        end
      end)
    end)
  end

  defp parse_int(nil), do: 0
  defp parse_int(""), do: 0
  defp parse_int(int) when is_integer(int), do: int

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end
end
