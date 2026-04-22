defmodule LaliaBema.Watcher do
  @moduledoc """
  Tails Lalia's on-disk workspace and projects new events onto `Phoenix.PubSub`.

  * Subscribes to `FileSystem` events on `LALIA_WORKSPACE`.
  * Bootstraps a set of already-seen message files so history doesn't re-broadcast on boot.
  * Periodically re-queries `lalia agents` / `lalia rooms` and emits structural deltas.
  * Exposes a `snapshot/0` call so LiveView can hydrate on mount.
  """
  use GenServer

  require Logger

  alias LaliaBema.Lalia
  alias LaliaBema.Scope

  @topic "feed"
  @pubsub LaliaBema.PubSub
  @tick_ms 5_000
  @recent_cap 200

  defmodule Message do
    @moduledoc false
    defstruct [:id, :kind, :target, :from, :seq, :body, :ts, :path]
  end

  ## Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Snapshot of known agents, rooms, and recently seen messages."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc "PubSub topic clients should subscribe to."
  def topic, do: @topic

  @doc "PubSub server name."
  def pubsub, do: @pubsub

  ## GenServer

  @impl true
  def init(opts) do
    workspace = Keyword.get(opts, :workspace) || Keyword.fetch!(Lalia.config(), :workspace)

    case start_file_system(workspace) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        {recent, seen} = bootstrap(workspace)
        {agents, rooms} = query_structural()
        schedule_tick()

        {:ok,
         %{
           workspace: workspace,
           fs: pid,
           seen: seen,
           recent: recent,
           agents: agents,
           rooms: rooms
         }}

      {:error, reason} ->
        Logger.warning("LaliaBema.Watcher could not watch #{workspace}: #{inspect(reason)}")
        {agents, rooms} = query_structural()
        schedule_tick()

        {:ok,
         %{
           workspace: workspace,
           fs: nil,
           seen: MapSet.new(),
           recent: [],
           agents: agents,
           rooms: rooms
         }}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap = %{agents: state.agents, rooms: state.rooms, recent: state.recent}
    {:reply, snap, state}
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, events}}, state) do
    state =
      cond do
        not message_file?(path) -> state
        :deleted in events -> state
        MapSet.member?(state.seen, path) -> state
        true -> ingest(path, state)
      end

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    Logger.warning("LaliaBema.Watcher: file_system watcher stopped")
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    {agents, rooms} = query_structural()

    if agents != state.agents do
      broadcast({:agents, agents})
    end

    if rooms != state.rooms do
      broadcast({:rooms, rooms})
    end

    schedule_tick()
    {:noreply, %{state | agents: agents, rooms: rooms}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp start_file_system(workspace) do
    if File.dir?(workspace) do
      FileSystem.start_link(dirs: [workspace], name: :"#{__MODULE__}.FS.#{System.unique_integer([:positive])}")
    else
      {:error, :workspace_missing}
    end
  end

  defp bootstrap(workspace) do
    paths =
      [Path.join(workspace, "rooms"), Path.join(workspace, "peers")]
      |> Enum.flat_map(&list_message_files/1)

    messages =
      paths
      |> Enum.map(&parse_message_file/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(& &1.ts, :desc)
      |> Enum.take(@recent_cap)

    seen = MapSet.new(paths)
    {messages, seen}
  end

  defp list_message_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          sub = Path.join(dir, entry)

          if File.dir?(sub) do
            case File.ls(sub) do
              {:ok, files} ->
                files
                |> Enum.filter(&message_basename?/1)
                |> Enum.map(&Path.join(sub, &1))

              _ ->
                []
            end
          else
            []
          end
        end)

      _ ->
        []
    end
  end

  defp message_basename?(name) do
    String.ends_with?(name, ".md") and
      not (name in ["ROOM.md", "MEMBERS.md", "README.md"])
  end

  defp message_file?(path) do
    base = Path.basename(path)

    message_basename?(base) and
      (String.contains?(path, "/rooms/") or String.contains?(path, "/peers/"))
  end

  defp ingest(path, state) do
    case parse_message_file(path) do
      nil ->
        state

      %Message{} = msg ->
        write_through(msg)
        broadcast({:new_message, msg})
        recent = [msg | state.recent] |> Enum.take(@recent_cap)
        %{state | seen: MapSet.put(state.seen, path), recent: recent}
    end
  end

  defp write_through(%Message{kind: kind, target: target, from: from, seq: seq} = msg)
       when kind in [:room, :channel] and is_binary(target) and is_binary(from) and target != "" and
              from != "" and is_integer(seq) do
    attrs = %{
      kind: msg.kind,
      target: msg.target,
      from: msg.from,
      seq: msg.seq,
      body: msg.body,
      posted_at: parse_ts(msg.ts),
      path: msg.path
    }

    case Scope.upsert_message(attrs) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning("LaliaBema.Watcher: Ash write-through failed for #{msg.path}: #{inspect(error)}")
        :error
    end
  rescue
    e ->
      Logger.warning("LaliaBema.Watcher: Ash write-through raised for #{msg.path}: #{inspect(e)}")
      :error
  end

  defp write_through(_), do: :skip

  defp parse_ts(nil), do: nil
  defp parse_ts(""), do: nil

  defp parse_ts(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @doc false
  def parse_message_file(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, meta, body} <- split_frontmatter(content) do
      {kind, target} = classify(path)
      seq = meta |> Map.get("seq") |> to_int()

      %Message{
        id: path,
        kind: kind,
        target: target,
        from: Map.get(meta, "from", ""),
        seq: seq,
        body: body,
        ts: Map.get(meta, "ts", ""),
        path: path
      }
    else
      _ -> nil
    end
  end

  defp split_frontmatter("---\n" <> rest), do: split_frontmatter_body(rest)
  defp split_frontmatter("---\r\n" <> rest), do: split_frontmatter_body(rest)
  defp split_frontmatter(_), do: :error

  defp split_frontmatter_body(rest) do
    case String.split(rest, ~r/\n---\r?\n/, parts: 2) do
      [meta_str, body] -> {:ok, parse_meta(meta_str), String.trim(body)}
      _ -> :error
    end
  end

  defp parse_meta(str) do
    str
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  defp classify(path) do
    cond do
      String.contains?(path, "/rooms/") ->
        {:room, path |> Path.dirname() |> Path.basename()}

      String.contains?(path, "/peers/") ->
        {:channel, path |> Path.dirname() |> Path.basename()}

      true ->
        {:unknown, ""}
    end
  end

  defp to_int(nil), do: nil
  defp to_int(int) when is_integer(int), do: int

  defp to_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp query_structural do
    agents =
      case Lalia.agents() do
        {:ok, list} -> list
        _ -> []
      end

    rooms =
      case Lalia.rooms() do
        {:ok, list} -> list
        _ -> []
      end

    {agents, rooms}
  end

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, message)
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_ms)
  end
end
