defmodule LaliaBema.Backfill do
  @moduledoc """
  One-shot importer that walks the Lalia git workspace and upserts every
  registry, room, and message into the Ash Scope domain. Idempotent by
  resource primary key / identity — safe to run repeatedly.

  Callable from the supervision tree on boot and from `mix lalia.backfill`.
  """
  require Logger

  alias LaliaBema.Scope

  @type stats :: %{
          agents: non_neg_integer(),
          rooms: non_neg_integer(),
          messages: non_neg_integer(),
          tasks: non_neg_integer(),
          errors: non_neg_integer()
        }

  @spec run(keyword()) :: {:ok, stats()}
  def run(opts \\ []) do
    cfg = Application.get_env(:lalia_bema, :lalia, [])
    workspace = Keyword.get(opts, :workspace) || Keyword.fetch!(cfg, :workspace)

    stats = %{agents: 0, rooms: 0, messages: 0, tasks: 0, errors: 0}

    stats
    |> backfill_agents(workspace)
    |> backfill_rooms(workspace)
    |> backfill_messages(workspace)
    |> then(&{:ok, &1})
  end

  defp backfill_agents(stats, workspace) do
    dir = Path.join(workspace, "registry")

    case File.ls(dir) do
      {:ok, files} ->
        Enum.reduce(files, stats, fn file, acc ->
          path = Path.join(dir, file)

          case load_agent(path) do
            {:ok, attrs} ->
              case Scope.upsert_agent(attrs) do
                {:ok, _} -> %{acc | agents: acc.agents + 1}
                {:error, e} -> log_error(path, e, acc)
              end

            :skip ->
              acc
          end
        end)

      _ ->
        stats
    end
  end

  defp backfill_rooms(stats, workspace) do
    dir = Path.join(workspace, "rooms")

    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, stats, fn name, acc ->
          room_dir = Path.join(dir, name)

          if File.dir?(room_dir) do
            attrs = load_room(room_dir, name)

            case Scope.upsert_room(attrs) do
              {:ok, _} -> %{acc | rooms: acc.rooms + 1}
              {:error, e} -> log_error(room_dir, e, acc)
            end
          else
            acc
          end
        end)

      _ ->
        stats
    end
  end

  defp backfill_messages(stats, workspace) do
    stats
    |> backfill_message_tree(Path.join(workspace, "rooms"), :room)
    |> backfill_message_tree(Path.join(workspace, "peers"), :channel)
  end

  defp backfill_message_tree(stats, dir, kind) do
    case File.ls(dir) do
      {:ok, targets} ->
        Enum.reduce(targets, stats, fn target, acc ->
          target_dir = Path.join(dir, target)

          if File.dir?(target_dir) do
            target_dir
            |> File.ls!()
            |> Enum.filter(&message_file?/1)
            |> Enum.reduce(acc, fn file, acc2 ->
              path = Path.join(target_dir, file)

              case parse_message(path, kind, target) do
                {:ok, attrs} ->
                  case Scope.upsert_message(attrs) do
                    {:ok, _} -> %{acc2 | messages: acc2.messages + 1}
                    {:error, e} -> log_error(path, e, acc2)
                  end

                :skip ->
                  acc2
              end
            end)
          else
            acc
          end
        end)

      _ ->
        stats
    end
  end

  defp load_agent(path) do
    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body),
         agent_id when is_binary(agent_id) <- Map.get(json, "agent_id") do
      {:ok,
       %{
         agent_id: agent_id,
         name: Map.get(json, "name"),
         project: Map.get(json, "project"),
         branch: Map.get(json, "branch"),
         harness: Map.get(json, "harness"),
         registered_at: parse_ts(Map.get(json, "started_at")),
         last_seen_at: parse_ts(Map.get(json, "last_seen_at")),
         lease_expires_at: parse_ts(Map.get(json, "expires_at")),
         repo_root: Map.get(json, "repo_root") || Map.get(json, "main_repo_root"),
         pubkey: Map.get(json, "pubkey")
       }}
    else
      _ -> :skip
    end
  end

  defp load_room(room_dir, name) do
    meta =
      case File.read(Path.join(room_dir, "ROOM.md")) do
        {:ok, content} -> parse_room_meta(content)
        _ -> %{}
      end

    members =
      case File.read(Path.join(room_dir, "MEMBERS.md")) do
        {:ok, content} -> parse_member_count(content)
        _ -> 0
      end

    %{
      name: name,
      description: Map.get(meta, "desc"),
      created_at: parse_ts(Map.get(meta, "created_at")),
      created_by: Map.get(meta, "created_by"),
      archived?: false,
      member_count: members
    }
  end

  defp parse_room_meta(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^(created_by|created_at|desc):\s*(.+)$/, line) do
        [_, k, v] -> Map.put(acc, k, String.trim(v))
        _ -> acc
      end
    end)
  end

  defp parse_member_count(content) do
    case Regex.run(~r/^count:\s*(\d+)/m, content) do
      [_, n] -> String.to_integer(n)
      _ -> 0
    end
  end

  defp parse_message(path, kind, target) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, meta, body} <- split_frontmatter(content),
         seq when is_integer(seq) <- to_int(Map.get(meta, "seq")),
         from when is_binary(from) and from != "" <- Map.get(meta, "from") do
      {:ok,
       %{
         kind: kind,
         target: target,
         from: from,
         seq: seq,
         body: body,
         posted_at: parse_ts(Map.get(meta, "ts")),
         path: path
       }}
    else
      _ -> :skip
    end
  end

  defp split_frontmatter("---\n" <> rest), do: split_body(rest)
  defp split_frontmatter("---\r\n" <> rest), do: split_body(rest)
  defp split_frontmatter(_), do: :error

  defp split_body(rest) do
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

  defp message_file?(name) do
    String.ends_with?(name, ".md") and
      name not in ["ROOM.md", "MEMBERS.md", "README.md"]
  end

  defp to_int(nil), do: nil
  defp to_int(int) when is_integer(int), do: int

  defp to_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_ts(nil), do: nil
  defp parse_ts(""), do: nil

  defp parse_ts(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp log_error(path, error, stats) do
    Logger.warning("LaliaBema.Backfill failed on #{path}: #{inspect(error)}")
    %{stats | errors: stats.errors + 1}
  end
end
