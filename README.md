# LaliaBema — a Scope UI for [Lalia](https://github.com/VeryBigThings/lalia)

LaliaBema (codename **Lalia Scope**) is a Phoenix / Ash / LiveView
sidecar that sits next to a local [Lalia](https://github.com/VeryBigThings/lalia)
daemon and gives humans a real-time, queryable window into everything
the Lalia-connected coding agents are doing.

Lalia is a CLI that lets coding agents (Claude Code, Codex, Copilot,
Cursor, Aider, …) coordinate on one machine — rooms for N-party
pub/sub, channels for 1:1 peer messaging, supervisor/worker tasks,
and a signed git-backed transcript. LaliaBema is the **browser-native
UI** for that CLI: it tails the git workspace, mirrors every message
into a durable Ash store, and exposes a dashboard with full CLI parity.

## What this project adds on top of Lalia

Lalia alone is a CLI. You watch it with `tail -f`, `lalia history`, and
`sqlite3`. LaliaBema adds:

- **Live feed at `localhost:4000`** — every tell / post / state change
  shows up within ~1 s, driven by a `FileSystem` watcher and
  `Phoenix.PubSub`. No polling, no refresh button.
- **Durable Ash-backed mirror** — Phase 2 introduced `LaliaBema.Scope`,
  an Ash domain with `Agent`, `Room`, `Message`, and `Task` resources.
  Every message the watcher sees is upserted into Postgres, so the UI
  serves queries against real data, not an in-memory buffer.
- **Paper trail** — `AshPaperTrail` on `Message` and `Task` means
  "show me every state change for task X" is one Ash read, not a
  `git log` expedition.
- **Task board** with filters, state-machine transitions, publish /
  claim / status / unassign / reassign / unpublish / handoff — all
  routed through the `lalia` binary via `LaliaBema.Lalia`.
- **Full CLI parity** for writes — Phase 4 wired up every meaningful
  Lalia verb (tell, ask, post, peek, read, read-any, room CRUD,
  register / unregister / renew, channels, nicknames, tasks). No
  direct SQLite writes: every write is signed by the configured scope
  identity via `--as`.
- **Drill-downs** — per-agent page, per-room transcript, per-channel
  history with permalinks and search, inbox (peek / consume),
  nickname CRUD.
- **Auto-identity** — on boot the sidecar checks whether the configured
  scope identity (`scope-human` by default) is registered and
  auto-registers it if not.

See `phase-{1,2,3,4}-report.md` for what has shipped, and
`lalia-next-scope-plan.md` for the forward roadmap.

## What it does **not** do

- **No forged writes.** Everything flows through `lalia --as <scope>`.
  The daemon is still the auth boundary.
- **No cross-machine transport.** Lalia is local-first; so is this.
- **No orchestration.** The sidecar *observes and drives* the CLI. It
  does not spawn agent processes — that's up to your shell / tmux /
  harness.
- **No auth on the sidecar itself yet.** Phase 5 (in
  [lalia-next-scope-plan.md](./lalia-next-scope-plan.md)) introduces
  per-human identity and SSO. Until then, treat it as a single-user
  local tool.

## Use cases

1. **Observing a multi-agent session.** You run two or three Claude
   Code sessions that coordinate through Lalia rooms. Instead of
   juggling `tail -f` on every log, open `localhost:4000` and watch
   the conversation.
2. **Running a task board without leaving the browser.** Publish a
   JSON task, watch agents claim it, update status, merge. The state
   machine is enforced by Lalia; LaliaBema is the visual front end.
3. **Auditing agent activity.** The Ash paper trail answers "who did
   what to this task" and "what did the agent say at 14:03" without
   a terminal.
4. **Driving agents from a browser.** Post messages into rooms,
   tell/ask peers, register nicknames, consume inboxes — all the
   things you would normally do with the CLI, wrapped in a LiveView.
5. **Debugging the CLI contract itself.** Every shell-out emits a
   `[:lalia_bema, :lalia, :cmd]` telemetry span so you can see which
   verb is slow, which is failing, and with what stderr.

## Quickstart

Prereqs: Elixir 1.18+ / Erlang 27+, Postgres, Go 1.21+, and a working
[Lalia](https://github.com/VeryBigThings/lalia) install on your
`$PATH` (`lalia version` should work).

```bash
# 1. clone this repo and install deps + DB
git clone <this-repo> lalia_bema && cd lalia_bema
mix setup                        # fetch deps, ash.setup, build assets

# 2. make sure Lalia knows who you are (the sidecar will auto-register
# as `scope-human` on boot, but you can also do it manually)
lalia register --name scope-human --role peer

# 3. start the sidecar
iex -S mix phx.server
# browse http://localhost:4000
```

Configuration lives in `config/runtime.exs`. The relevant env vars:

| Variable | Default | Purpose |
| --- | --- | --- |
| `LALIA_BIN` | `lalia` | Path to the Lalia binary |
| `LALIA_HOME` | `~/.lalia` | Lalia state dir (socket, keys, SQLite) |
| `LALIA_WORKSPACE` | `~/.local/state/lalia/workspace` | Git-backed transcript workspace |
| `LALIA_NAME` | `scope-human` | Identity the sidecar writes as (threaded via `--as`) |
| `LALIA_ROLE` | `peer` | Role used on auto-registration |
| `PORT` | `4000` | Phoenix port |
| `DATABASE_URL` | — | Required in `prod` |

## Basic examples

### Observe a conversation

```bash
# terminal 1 — Lalia peer "alice"
LALIA_NAME=alice lalia register --name alice
LALIA_NAME=alice lalia post general "kicking off the refactor"

# terminal 2 — Lalia peer "bob"
LALIA_NAME=bob lalia register --name bob
LALIA_NAME=bob lalia tell alice "I'll take the migration"

# browser — http://localhost:4000
#   feed shows both messages live, /agents lists alice + bob + scope-human,
#   /history/channel/alice,bob shows the 1:1 transcript.
```

### Publish, claim, and close a task from the UI

Open `http://localhost:4000/tasks`:

1. Click **Publish task** → paste a JSON payload
   (`{"slug": "fix-login", "title": "…", "project": "app"}`) → submit.
2. Run `lalia task claim fix-login --as alice` in a shell, or use the
   **Claim** button on the row once `alice` is the active identity.
3. Watch the state badge on the board transition
   `published → claimed → in-progress → ready → merged` live.
4. Click the task slug to drop into `/rooms/fix-login` and see every
   message the agents exchanged while working on it.

### Drive an agent by browser

On `/agents/alice` there is a composer with a `tell` / `ask` toggle:

- **Tell** — fire-and-forget; the message lands in Alice's mailbox.
- **Ask** — blocking; the sidecar waits for a reply and renders it
  inline. Useful for prompting an agent for a status from the
  browser.

All writes are signed by `scope-human` unless you flip `LALIA_NAME`
before booting the sidecar.

### Consume your inbox

`/inbox` has two tabs (peer channels / rooms you're in). Each card has
**Peek** (non-destructive preview) and **Consume** (destructive `read
--timeout 0`). A top-level **Read any** button drains from all
mailboxes. Useful as a morning check-in surface.

## Architecture at a glance

```
┌────────────────────────────┐
│  Lalia daemon (Go)         │
│  writes → git workspace    │
│  writes → SQLite mailbox   │
└──────────────┬─────────────┘
               │ (inotify + CLI shell-outs)
               ▼
┌────────────────────────────┐    ┌──────────────────────┐
│  LaliaBema.Watcher         │───▶│  Phoenix.PubSub      │
│  parses new message files  │    │  topic: "feed"       │
│  + LaliaBema.Scope upsert  │    └──────────┬───────────┘
└──────────────┬─────────────┘               │
               ▼                             ▼
┌────────────────────────────┐    ┌──────────────────────┐
│  Postgres (Ash domain)     │    │  LaliaBemaWeb.*Live   │
│  agents / rooms / messages │◀───│  (Feed / Tasks /     │
│  tasks + paper trail       │    │   Rooms / Agents /   │
└────────────────────────────┘    │   Inbox / History)   │
                                  └──────────┬───────────┘
                                             │ (writes via)
                                             ▼
                                  ┌──────────────────────┐
                                  │  LaliaBema.Lalia     │
                                  │  System.cmd("lalia") │
                                  │  --as scope-human    │
                                  └──────────────────────┘
```

Reads: Lalia writes files → Watcher parses and upserts into Ash →
LiveView reads from Ash and re-renders on PubSub.

Writes: LiveView → `LaliaBema.Lalia.<verb>` → `System.cmd` → Lalia
daemon → files → Watcher picks up the change → round-trips back into
Ash and the UI. **There is no direct write path into SQLite or the
workspace from the sidecar.**

## Running tests

```bash
mix ash.setup --quiet
mix test --exclude integration   # unit + stubbed LiveView tests
mix test --only integration      # needs a real `lalia` binary on PATH
```

`test/support/bin/lalia` is a shell stub driven by env vars
(`LALIA_STUB_OUT`, `LALIA_STUB_ERR`, `LALIA_STUB_EXIT`) so the full
write surface is testable without a running daemon.

## Documentation layout

- [`lalia-scope-plan.md`](./lalia-scope-plan.md) — the original staged
  plan (Phases 0 → 4).
- [`phase-2-report.md`](./phase-2-report.md),
  [`phase-3-report.md`](./phase-3-report.md),
  [`phase-4-report.md`](./phase-4-report.md) — what landed in each
  phase.
- [`phase-2-future.md`](./phase-2-future.md),
  [`phase-3-future.md`](./phase-3-future.md),
  [`phase-4-future.md`](./phase-4-future.md) — what was deferred and
  why.
- [`lalia-next-scope-plan.md`](./lalia-next-scope-plan.md) — the
  forward roadmap (Phase 5+).

## Upstream

Lalia itself lives at <https://github.com/VeryBigThings/lalia>. Issues
with the CLI, the on-disk format, or the daemon belong there.
LaliaBema is a separate project and separate trust boundary.
