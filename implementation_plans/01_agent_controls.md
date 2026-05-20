# Agent Controls — Highlight + Drive the App

## Goal

Let Claude (via MCP) point at UI elements and drive the LiveView from a browser
tab where the LiveAgent panel is open. Two user-facing scenarios:

1. **Highlight** — "Claude, highlight the cart summary" → that container gets a
   Chrome DevTools-style overlay in the user's browser.
2. **Demo** — "Claude, demo the checkout flow" → Claude clicks buttons, fills
   inputs, navigates, observing the result of each step before continuing.

## Constraint (decided)

- Panel must be open in a browser tab. We will NOT inject events server-side
  via `Phoenix.LiveView.Channel` — clicks/fills go through the real DOM so they
  exercise the same path a real user hits (`phx-click`, hooks, JS commands).

## Transport (decided)

- Long-poll endpoint `GET /live_agent/commands` (≈25s hold). Panel runs a
  reconnect loop. No SSE/WebSocket for the first cut.
- Result endpoint `POST /live_agent/commands/:id/result` — panel reports the
  outcome of each executed command back to the queue.
- MCP tool blocks (with timeout) on the result before returning to Claude, so
  Claude always sees what actually happened.

## Architecture

```
Claude ──MCP──▶ Tools.click(...)
                    │
                    ▼
              CommandQueue (GenServer)
                ├─ enqueue {id, op, args, from}
                ├─ long-poll waiter from panel browser
                └─ result-waiter (the MCP call)
                    ▲
                    │ POST /commands/:id/result
                    │
              Panel JS executor
                ├─ resolves target (cid / selector / text)
                ├─ dispatches DOM event (click / input / submit)
                ├─ waits for next LV patch (MutationObserver / liveSocket hooks)
                └─ POSTs {id, ok, snapshot}
```

- **CommandQueue** holds pending commands and parked GenServer callers.
  One queue per panel session keyed by a session id (panel generates UUID on
  load, sends as header / query param). MVP: single global queue is fine.
- **Targeting resolver (browser side)** accepts:
  - `cid: 42` → `[data-phx-component="42"]`
  - `selector: "#submit"` → CSS
  - `text: "Submit"` → role/text scan
- **Snapshot returned per command**: `{ url, view_module, changed_assigns, flash }`
  so Claude reads the consequence without a second tool call.

## Slices

Mark each slice complete by changing `[ ]` to `[x]` as it lands.

### Slice 1 — Plumbing
- [x] `LiveAgent.CommandQueue` GenServer: enqueue/await-result/poll-next/post-result, add to Application supervisor
- [x] Router: `GET /api/commands` (long-poll) + `POST /api/commands/result`
- [x] Panel JS: command long-poll loop with backoff + reconnect on disconnect
- [x] Panel UI: "Agent control" status pill (connected / idle / executing)

### Slice 2 — Highlight (read-only, lowest risk)
- [x] MCP tool `highlight_element` — args: `cid` | `selector` | `text`, optional `duration_ms`, `label`
- [x] Panel JS: overlay div positioned over target's bounding rect with margin band + tooltip
- [x] Panel JS: `clear_highlight` command
- [x] MCP tool returns `{ ok, matched_count, rect, resolved_target }`

### Slice 3 — Drive: click + navigate
- [x] Per-session "Allow agent to drive" toggle in panel (off by default; click/navigate refuse without it). Note: highlight stays allowed even when toggle is off.
- [x] MCP tool `click` — dispatches real `click` event on resolved target
- [x] MCP tool `navigate` — synthesises an LV link click for patch/redirect, falls back to `window.location` for `href` mode or when liveSocket is absent
- [x] Post-action snapshot: capture URL, view module, flash, and assigns diff for all root LVs; return to Claude
- [x] Bound on snapshot wait: MutationObserver settle (120ms quiet) capped at 2s

### Slice 4 — Drive: fill + submit
- [x] MCP tool `fill` — sets `value` (or `checked` for checkbox/radio, `textContent` for contenteditable) and dispatches `input` + `change` (covers `phx-change`)
- [x] MCP tool `submit` — `form.requestSubmit()` on nearest form ancestor (triggers `phx-submit` + HTML5 validation)
- [x] MCP tool `wait_for` — `{ assign: {pid, key, equals?} }` (server-side poll, panel not required) | `{ selector }` | `{ text }` (browser MutationObserver), with `timeout_ms`

### Slice 5 — Targeting cues for Claude
- [x] Extend `get_component_tree` to include forms (id, phx-submit, phx-change), named inputs (name/type/id), and buttons (text, phx-click, id, type) — surfaced in both the MCP text output and the `/api/component_tree` JSON
- [x] Document the targeting rubric in each driving tool's description (click, fill, submit, get_component_tree). The recommended order differs per tool: click → cid|selector|text, fill → selector|cid|text, submit → selector|cid|text.

### Slice 6 — Docs
- [x] README: new "Agent controls" section listing the tools, status dot, and Drive toggle, plus a cross-link from the in-browser panel section
- [x] Three demo scripts in README (highlight an element, click + read assigns diff, multi-step checkout flow with wait_for)

## Decisions deferred

- Multi-panel / multi-session command routing (MVP: one panel). If we need it,
  key the queue by session id passed in headers.
- SSE upgrade — revisit only if long-poll proves laggy in practice.
- Screenshot tool — out of scope for this plan.

## Risks

- **LV async patches**: action completes before assigns update. Mitigation: the
  panel waits for the next `phx:update` / channel reply before snapshotting,
  with a 2s ceiling.
- **Stale targets**: element re-rendered between resolve and dispatch. Mitigation:
  re-resolve immediately before dispatch; return clear error if not found.
- **Drive safety**: surface a clear toggle + log every executed command in the
  event store so the user can see what Claude did.
