# Async / Task Inspector — "What's Still Loading?"

## Goal

Make `Phoenix.LiveView.start_async` and `assign_async` tasks visible to Claude
(and to the developer) while they're in flight and after they complete. Three
user-facing scenarios:

1. **"Why is this spinner still spinning?"** — Claude lists pending async
   tasks for the LV, shows how long each has been running, and which assign
   key (`AsyncResult`) it will fill.
2. **"What did that failed call return?"** — Claude reads the async history,
   finds the most recent failure for `:load_user`, returns the exception +
   stacktrace.
3. **"Race-condition forensics."** — Two async tasks finished out of order;
   Claude shows the completion order and the resulting assigns diffs.

## Constraint (decided)

- Capture is **passive**: subscribe to LiveView's built-in async telemetry
  (if it exists — see verification below) and/or read `socket.private` for
  pending tasks. No monkey-patching, no user code changes.
- Pending tasks are **read live** (point-in-time inspection); completed tasks
  are recorded into a ring buffer like `StateTimeline`.

## Capture surface (verified against Phoenix LiveView 1.1.26)

- **No `handle_async` telemetry exists.** Zero `:telemetry` calls cover the
  async callback (`deps/phoenix_live_view/lib/phoenix_live_view/async.ex:327`–
  `361`; `channel.ex:265`–`281`). We **cannot** rely on telemetry for
  completion capture — see Architecture for the polling-plus-monitor model.
- **In-flight registry:** `socket.private[:live_async]` is a map of
  `key => {ref, pid, kind}` where `key` is the atom passed to `start_async`
  / `assign_async`, `pid` is the task pid, `ref` is a monitor ref, and `kind`
  is one of `:start`, `:assign`, or `:stream`
  (`async.ex:423`–`430` and `:279`). Both `start_async` and `assign_async`
  share this key. **No start time is stored in the registry** — the inspector
  must stamp it on first observation.
- **`AsyncResult` is fully public.** Fields: `:ok?`, `:loading`, `:failed`,
  `:result`. All four are documented and safe to pattern-match
  (`async_result.ex:1`–`143`).
- **No usable supervisor fallback.** Tasks are launched via `Task.start_link`
  by default (`async.ex:271`); a user can pass `:supervisor` to bind a custom
  `Task.Supervisor`, but that's opt-in and uncommon. We cannot enumerate
  unlinked tasks globally.

## Architecture

```
LV channel ──start_async/assign_async──▶ Task (unlinked, no telemetry)
     │                                          │
     │                                          │  (work)
     │                                          ▼
     │                                     task exits
     │                                          │
     ▼                                          │
LiveAgent.AsyncInspector (GenServer)            │
  ├─ Poll loop (every 250ms):                   │
  │     for each LV pid:                        │
  │       read socket.private[:live_async]      │
  │       diff against last-seen registry       │
  │       on new task: stamp started_at;        │
  │         Process.monitor(task_pid)           │
  │                                             │
  ├─ on :DOWN(task_pid, reason) ────────────────┘
  │     push history entry (name, kind,
  │     started_at, duration, ok/exit, reason)
  │     attempt value attribution by reading
  │     the LV's assigns for an %AsyncResult{}
  │     under the same key, OR cross-link to
  │     the next StateTimeline entry within ~150ms
  │
  └─ %{lv_pid => %{
       tasks: %{name => %{task_pid, kind, started_at, monitor_ref}},
       history: [..., capped at 25],
       next_id,
       lv_monitor_ref     # to drop the LV when it dies
     }}
```

Two collaborating pieces:

- **`LiveAgent.AsyncInspector`** (GenServer) — runs a single shared 250ms
  poll loop across all live LV pids, discovers new entries in
  `socket.private[:live_async]`, and monitors each task pid. When the task
  dies, pushes a history entry into a per-LV ring buffer (default 25). Same
  monitor / 60s grace cleanup model as `StateTimeline`.
- **`LiveAgent.AsyncRegistry`** (plain module, no state) — inspection
  helpers reading `socket.private[:live_async]` and scanning
  `socket.assigns` for `%AsyncResult{}` values. Used by `list_async_tasks`
  for the live "what's loading right now" view. Lives next to
  `SocketInspector`.

Why polling and not just monitoring? Without telemetry we have no event at
task launch, so we can't `Process.monitor` until we discover the task pid by
reading the LV's state. 250ms is the trade-off: short enough to catch nearly
every task before it completes, long enough that the cost of
`:sys.get_state` on every LV pid is negligible. Tasks that complete in
under ~250ms may be missed by the poll loop — we record what we can but
this is a documented limitation (see Risks).

**Entry shape (history):**

```elixir
%{
  id: 8,                              # monotonic per LV pid
  at: ~U[...],                        # completion time
  name: :load_user,                   # the registry key
  kind: "start" | "assign" | "stream", # from the registry (verbatim)
  duration_us: 312_004,
  result: :ok | :exit,                # only what :DOWN exposes
  exit_reason: <truncated>,           # nil if :ok
  async_result: %{ok?, loading, failed, result_preview}
                                      # for :assign kind, pulled from
                                      # the LV's assigns post-completion
  state_timeline_id: 17 | nil         # cross-link if a matching entry was
                                      # recorded within ~150ms
}
```

For `:start` kind tasks the callback's raw return value is not available to
us (no telemetry, the value lives only inside the LV's mailbox). The
`state_timeline_id` cross-link is how Claude reaches the resulting assigns
diff. For `:assign` kind tasks the result lands in an `%AsyncResult{}` under
`assigns[name]`, which we capture into `async_result`.

**Pending shape (live read):**

```elixir
%{
  name: :load_user,
  kind: "start" | "assign" | "stream",
  started_at: ~U[...],                # nil if we discovered it on the first
                                      # poll and have no earlier sighting
  elapsed_ms: 1_240,
  task_pid: "#PID<...>"
}
```

**`AsyncResult` introspection:** when an assign value is a
`%Phoenix.LiveView.AsyncResult{}`, sanitize it to a plain map so Claude sees
`%{loading: true | false, ok?: bool, result: …, failed: …}` instead of
`#AsyncResult<…>`. Handled centrally in `SocketInspector` so every
`get_assigns` call benefits, not just async-specific tools.

## Slices

Mark each slice complete by changing `[ ]` to `[x]` as it lands.

### Slice 1 — Pending-task inspection (read-only)
- [x] `LiveAgent.AsyncRegistry.list_pending(pid)` reads `socket.private`
      (via `:sys.get_state` + existing `SocketInspector.get_socket/1` pattern)
      and returns the pending list shape above. Returns `[]` if the private
      key is missing or shape unrecognized — log a one-time warning so
      version drift is visible.
- [x] `LiveAgent.AsyncRegistry.list_async_results(pid)` scans
      `socket.assigns` for `%AsyncResult{}` values and returns
      `[{assign_key, loading?, ok?, failed_reason}]`.
- [x] Extend `SocketInspector` sanitization to render `AsyncResult` as a
      plain map (loading/ok?/result/failed) instead of via `inspect/1`. One
      branch in `sanitize_struct/2`.

### Slice 2 — Completed-task history (polling + monitor)
- [x] `LiveAgent.AsyncInspector` GenServer, mirroring `StateTimeline`'s
      per-pid shape (ring buffer of 25, monitor on LV pid, 60s grace on
      `:DOWN`).
- [x] Single 250ms `Process.send_after` poll loop that lists LV pids
      (`SocketInspector.list_live_views/0` — already returns the set we
      need), reads each `socket.private[:live_async]`, and diffs against
      the last-seen registry per LV. On new entries: stamp `started_at`,
      `Process.monitor(task_pid)`, store in per-LV `tasks` map.
- [x] `handle_info({:DOWN, ref, :process, task_pid, reason}, state)`:
      look up which LV+name the task belonged to, compute duration, push
      a history entry, drop from `tasks`. For `:assign` kind, read the
      LV's assigns and capture the `AsyncResult` post-completion. For
      `:start` kind, record only what `:DOWN` gives us.
- [x] Cross-link to the state timeline: after pushing a history entry,
      look up `StateTimeline.last_change/1` and, if its timestamp is
      within 150ms of `at`, store its `id` as `state_timeline_id`.
- [x] Add `LiveAgent.AsyncInspector` to the supervisor in
      `lib/live_agent/application.ex`, after `StateTimeline`.

### Slice 3 — Value truncation + sanitization
- [x] Share the `AssignsDiff` truncation rules (256-byte binary cap,
      50-element collection cap) for the `value` / `reason` fields. Lift the
      relevant helpers into `LiveAgent.AssignsDiff` (or a thin
      `LiveAgent.Sanitize` module) so both `StateTimeline` and
      `AsyncInspector` use the same cap.
- [x] Bound the entry's overall serialized size to ~8KB (smaller than state
      timeline since async values often include large payloads); on
      overflow, replace `value` with `{:oversize, byte_size}` summary.

### Slice 4 — MCP tools
- [x] `list_async_tasks(pid)` — returns pending tasks + currently-loading
      `AsyncResult` assigns. The "loading" view of the LV.
- [x] `get_async_history(pid, last_n \\ 10)` — returns completed entries
      newest first.
- [x] `get_async_event(pid, entry_id)` — single completed entry with full
      (non-summarized) value/reason where it fits.
- [x] Tool descriptions document the rubric: pending vs history, what
      `AsyncResult` means, and when to call which. Include the trigger
      cross-link: `handle_async` transitions also show up in
      `get_state_history` (currently as `"unknown"` — see Slice 6).

### Slice 5 — Panel UI
- [x] Wire a new "Async" pane through the existing plumbing
      (`la-launcher` button, `paneTitle()`, `renderPaneContent()`,
      `attachPaneEvents()`, `_asyncTimer` mirroring `_timelineTimer`).
      Endpoint: `GET /api/async?pid=...` returning `{pending, history}`.
- [x] Pending tasks rendered with a live elapsed-time counter (updates every
      second from the panel side; no extra server roundtrip).
- [x] History rendered grouped per-pid, newest first. Status badge: green
      (ok), red (error), gray (cancelled). Click to expand value/reason.
      Reuse the `.la-ev-*` color tokens; add `.la-ev-pending` (amber).
- [x] Link from history entries to the matching `StateTimeline` entry id
      when available (Slice 6 wires up the cross-reference).

### Slice 6 — State timeline integration
- [x] Without telemetry we cannot pre-set the pending trigger on
      `StateTimeline` from the LV side. Instead, post-hoc: when
      `AsyncInspector` records a completion, **rewrite** the most recent
      matching `StateTimeline` entry (if it's still `kind: "unknown"`)
      to `%{kind: "handle_async", name: <atom>}`. New
      `StateTimeline.relabel_entry/3` call.
- [x] The reverse link (entry → async record) is the
      `state_timeline_id` field already on the async history entry from
      Slice 2.
- [x] If no matching timeline entry exists (because the diff was empty),
      do nothing — the async history entry still stands alone.

### Slice 7 — Docs
- [x] README: new "Async / Task inspector" section in the MCP tools table,
      a "How it works" subsection (telemetry capture, `AsyncResult`
      introspection, version caveat for `socket.private` reads), and one
      demo script.
- [x] Update the existing State Timeline "Caveat" paragraph: `handle_async`
      is no longer `"unknown"` — only true `handle_info` is.

## Decisions deferred

- **Cancellation API** — exposing a `cancel_async(pid, name)` MCP tool would
  be high-value but adds a write surface. Park until the inspector lands and
  we see real demand.
- **Cross-pid async correlation** (one event fans out async work in several
  LVs). MVP: each pid is independent; Claude can query multiple.
- **Replay / retry** — re-running a failed async task with the same args.
  Requires capturing the function closure, which is not possible from
  telemetry alone. Out of scope.
- **Per-name baseline durations** — "this load_user usually takes 200ms but
  the last 3 took 4s". Useful but needs aggregation; not MVP.

## Risks

- **LV internals drift**: `socket.private[:live_async]` is not public API.
  Mitigation: feature-detect the shape (match on
  `{ref, pid, kind}` per entry); if it doesn't match, return `[]` and log
  a one-time warning naming the LV version. Document the supported version
  range in the README.
- **Tasks shorter than the poll interval**: a 50ms HTTP request that
  finishes before the next 250ms tick won't be discovered, so it never
  enters history. Mitigation: keep the interval tunable (default 250ms);
  document the floor in the tool description so Claude knows the inspector
  is best-effort for sub-tick tasks. We catch every task that survives at
  least one tick — empirically that's nearly all real-world async work.
- **Polling cost**: `:sys.get_state` on every LV pid every 250ms. For
  typical dev environments with <10 LV pids, this is ~1ms per pid = <40ms/s
  of overhead, negligible. Mitigation: gate the poll loop to only run while
  the inspector has at least one subscriber (panel pane open OR an MCP call
  in the last 30s) — eliminates the cost when nothing is watching.
- **Large async results** (file uploads, big API responses): a 50MB payload
  shouldn't blow up the inspector. Mitigation: the 8KB serialized cap in
  Slice 3, with `{:oversize, byte_size}` fallback so the entry is still
  recorded.
- **Sensitive results** (auth tokens fetched async): same redaction concern
  as the state timeline. Mitigation: respect the same `:redact_keys` config
  if/when that lands; for now, document it.
- **Poll-loop crash**: if reading `socket.private` raises, the loop must
  keep going. Mitigation: `try`/`rescue` around the per-LV read; on
  failure, log once and skip that LV for this tick.
