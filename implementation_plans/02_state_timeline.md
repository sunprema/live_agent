# State Timeline — "What Changed and Why"

## Goal

Record every assigns transition for each live LiveView process so Claude can
answer "what changed when, and what triggered it" without re-running the user's
flow. Two user-facing scenarios:

1. **Forensics** — "Claude, why did `cart.total` flip to nil?" → Claude reads
   the timeline, finds the `handle_event` that produced the diff, reports the
   triggering event + params.
2. **Sequence review** — "Claude, walk me through what happened after I clicked
   Submit" → Claude returns an ordered list of transitions with diffs and
   durations.

## Constraint (decided)

- Capture is **passive**: subscribe to LiveView's built-in `:telemetry` events.
  No process tracing, no monkey-patching the channel, no user code changes.
- `handle_info` is **not** covered by core LV telemetry — known gap for v1, see
  Slice 5 for the workaround. Document it; don't fake it.

## Capture surface (decided)

These events expose the socket in `:stop` metadata, which is what we need:

- `[:phoenix, :live_view, :mount, :stop]`
- `[:phoenix, :live_view, :handle_params, :stop]`
- `[:phoenix, :live_view, :handle_event, :stop]`
- `[:phoenix, :live_component, :handle_event, :stop]`
- Matching `:exception` events for crash records.

We do **not** subscribe to `:render` (too chatty) or `:start` (no diff needed
since we cache the previous snapshot per pid).

## Architecture

```
LiveView process ──[:telemetry emit]──▶ LiveAgent.StateTimeline (GenServer)
                                              │
                                              ├─ %{pid => %{
                                              │     prev_assigns,
                                              │     entries: [..],   # newest-first list,
                                              │                      # capped via Enum.take/2
                                              │                      # (mirrors EventStore)
                                              │     next_id,
                                              │     monitor_ref
                                              │   }}
                                              │
                                              ├─ on :stop:
                                              │     diff = diff(prev, socket.assigns)
                                              │     push entry
                                              │     prev = socket.assigns
                                              │
                                              ├─ on :exception:
                                              │     push entry with reason+stack
                                              │
                                              └─ on :DOWN (pid):
                                                    drop after 60s grace
```

## Reuses (verified against the codebase)

- **Telemetry attachment template:** `LiveAgent.EventStore` lines 32–37
  (`:telemetry.attach_many` + detach-on-init for hot reload, handler signature
  `handle_telemetry(event, measurements, metadata, _config)` casting to self).
- **Per-pid storage template:** combine `EventStore`'s in-list ring cap
  (`Enum.take(@max_entries)` at event_store.ex:57) with `ComponentTreeStore`'s
  per-key map (component_tree_store.ex:23). Outer `%{pid => state}` cleared on
  `:DOWN` after 60s grace.
- **PID/view resolution:** `LiveAgent.SocketInspector.parse_pid/1`
  (socket_inspector.ex:289). New tools accept a pid string and dispatch
  through it, same as `get_assigns`.
- **MCP tool output:** match `get_assigns` style — `{:ok, Jason.encode!(result,
  pretty: true)}` with a human-readable preamble (tools.ex around lines 452–
  497).
- **Supervisor insertion point:** add `LiveAgent.StateTimeline` to the
  `children` list in `lib/live_agent/application.ex` immediately after
  `LiveAgent.EventStore`.
- **Telemetry events confirmed to expose post-callback socket in `:stop`
  metadata:** `:mount`, `:handle_params`, `:handle_event`,
  `:live_component, :handle_event`, and `:render` (all in
  `deps/phoenix_live_view/lib/phoenix_live_view/{channel,utils}.ex`). The
  `:exception` variants are emitted automatically by `:telemetry.span/3` — no
  explicit subscription needed beyond listing them in `attach_many`.

**Entry shape:**

```elixir
%{
  id: 17,                          # monotonic per pid
  at: ~U[2026-05-20 14:22:01.123Z],
  trigger: {:handle_event, "add_to_cart", %{"sku" => "A1"}},
  cid: nil,                        # set for live_component events
  duration_us: 4_211,
  result: :ok,                     # :ok | :exception
  diff: %{
    changed: %{cart_total: {1290, 1540}},
    added:   %{flash: %{info: "Added"}},
    removed: %{}
  },
  exception: nil                   # %{kind, reason, stacktrace_top_5} on crash
}
```

**Diff rules** (kept simple, recursive 2 levels deep):
- `changed`: keys present in both with `!=` values → `{old, new}`
- `added` / `removed`: top-level only
- Values truncated: binaries > 256 bytes → `{:truncated, byte_size}`; lists/maps
  > 50 elements → `{:summary, count}`
- Skip recording entirely if diff is empty (e.g. event that didn't touch state)

## Slices

Mark each slice complete by changing `[ ]` to `[x]` as it lands.

### Slice 1 — Storage + telemetry capture
- [x] `LiveAgent.StateTimeline` GenServer with per-pid ring buffer (default 50,
      configurable), Process.monitor for cleanup with 60s grace
- [x] Telemetry handler attached in `Application.start/2` for the four `:stop`
      events listed above
- [x] Cache `prev_assigns` per pid; first capture diffs against `%{}`
- [x] Drop entries where the diff is empty

### Slice 2 — Diff + truncation
- [x] `LiveAgent.AssignsDiff.diff/2` — recursive 2 levels, truncation rules
      above, handles structs by comparing as maps (skip `:__struct__` from diff)
- [x] Property test: round-trip `apply_diff(prev, diff) == next` for the
      non-truncated case
- [x] Bound entry serialized size to ~16KB; if larger, replace `diff` with
      `{:oversize, summary}` and keep the entry

### Slice 3 — Exception capture
- [x] Subscribe to the `:exception` variants; record entry with `result:
      :exception`, `exception: %{kind, reason, stacktrace: top_5_frames}`
- [x] On `:DOWN`, mark the timeline as "process exited" and keep entries for
      60s so Claude can post-mortem the last state

### Slice 4 — MCP tools
- [x] `get_state_history(pid_or_view, last_n \\ 20)` — returns entries newest
      first. Accept pid string or view module (resolves via `SocketInspector`).
- [x] `get_state_event(pid, entry_id)` — single entry with untruncated diff if
      it fits, else the original truncated form plus key paths to inspect
      manually via `get_assign`
- [x] Extend `get_assigns` output with `last_change: %{at, trigger, entry_id}`
      so Claude sees the most recent transition inline
- [x] Tool descriptions document the targeting rubric (pid preferred, view
      module if only one instance, error if ambiguous)

### Slice 5 — `handle_info` gap workaround
- [x] Subscribe to `[:phoenix, :live_view, :render, :stop]` as a low-priority
      sentinel — if assigns differ from `prev_assigns` and no transition was
      recorded in the last 10ms, push an entry with `trigger:
      {:unknown, :likely_handle_info}` so Claude at least sees *that*
      something changed and from where in the diff
- [x] Document the limitation in the README and the `get_state_history`
      tool description

### Slice 6 — Panel UI
- [x] Wire new pane "timeline" through the existing pane plumbing: add to the
      add-pane button list (live_agent.js:834), `paneTitle()` (line 934),
      `renderPaneContent()` case (line 1091), and `attachPaneEvents()`
      (line 1102). Add a `_timelineTimer` polling `/api/state_timeline` on
      `addPane("timeline")`, mirroring `_eventsTimer` (line 945).
- [x] Render entries grouped per-pid (same shape as the Assigns pane today —
      no need to introduce a `state.selectedLVPid` for v1; revisit if the pane
      gets crowded). Use `toggleAssigns` (line 1138) as the template for
      expand/collapse per entry, storing expanded state in
      `state.expandedTimelineEntries`.
- [x] Color-code by trigger kind. Reuse existing CSS tokens:
      `.la-ev-mount` (green), `.la-ev-event` (purple), `.la-ev-params` (blue),
      `.la-ev-error` (pink) for `mount` / `handle_event` / `handle_params` /
      `exception`. Add one new class `.la-ev-unknown` for the Slice 5 sentinel
      entries.
- [x] "Copy as MCP query" button — emits the exact `get_state_event` call

### Slice 7 — Docs
- [x] README: new "State timeline" section in the MCP tools table and a
      "How it works" subsection covering the telemetry capture model and the
      `handle_info` caveat
- [x] One demo script: trigger an event, ask Claude "what just changed", show
      the diff response

## Decisions deferred

- **Cross-PID correlation** (one user action that fans out via PubSub to N
  LVs). MVP: each pid has its own timeline; Claude can query multiple. Revisit
  if real flows need it.
- **Persistent storage** — everything is in-memory and dies with the BEAM.
  Fine for dev; would need ETS/disk if we ever want crash post-mortem across
  restarts.
- **Replay / time-travel** — reconstructing assigns at step N by walking diffs
  backward. Useful but not MVP; depends on Slice 2's invertibility.
- **Per-LiveComponent timeline view** — for now component events appear in the
  parent pid's timeline with `cid` set. Split view if it gets noisy.

## Risks

- **Memory pressure on chatty LVs**: 50 entries × ~16KB cap = ~800KB per LV
  worst case. Mitigation: ring buffer + per-entry size cap; expose
  `:timeline_limit` config.
- **Telemetry handler crash**: a bad diff blows up handler and detaches it
  silently. Mitigation: wrap handler body in `try`; on failure log + record a
  sentinel entry so we notice instead of going dark.
- **Sensitive data in assigns** (tokens, PII): timeline persists them in
  memory and exposes via MCP. Mitigation: respect an opt-in `:redact_keys`
  config that masks matching keys in the diff before storage.
- **Render-cycle sentinel false positives** (Slice 5): a delayed assign update
  might be attributed to "unknown" when it was actually a handle_event whose
  diff we missed. Mitigation: 10ms guard window + clear labelling so Claude
  knows the trigger is a guess.
