# Assertions — "Tell Me Pass Or Fail, Not Just The State"

> Requested by the PostOpGuard team, from a 75-session transcript audit (2026-05-25).
> `get_assigns` (75 calls) and `get_errors` (22 calls) are read-then-Claude-eyeballs-it.
> The recurring shape is "navigate / click, dump the assigns, reason about whether the value
> is what I expected." A pass/fail primitive would tighten every verify loop and give the
> project's `verify` skill a real assertion to hang on instead of re-improvising the
> read-and-judge each time.

## Goal

Add thin, explicit **verdict** tools on top of the existing read tools, so Claude can state
"this passed" / "this failed, here's the gap" without dumping and re-interpreting state. Two
user-facing scenarios:

1. **"Confirm the alert flipped to red."** — `expect_assign(pid, "alert.level", equals:
   "emergency")` → `{pass: true}` or `{pass: false, actual: "yellow", expected:
   "emergency"}`. No 350k-char dump to scan.
2. **"Did that click error anything?"** — `clear_errors` → click → `expect_no_errors` →
   `{pass: true}` or the captured errors. A clean gate around an action.

## Constraint (decided)

- **These are framing layers, not new capture.** `expect_assign` reuses the server-side
  assign poll already behind `wait_for`; `expect_no_errors` reuses `ErrorStore`. The value
  is the *contract* (pass/fail + the gap), not new plumbing.
- **Key-path support comes along for free** and is shared with the `features.md` request #1
  (key-path filtering on `get_assigns`) — implement the path resolver once, use it in both.

## Mechanism (grounded in current code)

- `wait_for(%{"assign" => %{"pid", "key", "equals"}})` (tools.ex ~line 2028) already polls a
  LV assign server-side until it equals a value or times out. `expect_assign` is that poll
  with `timeout_ms` defaulting low (or 0 for an immediate check) and a structured verdict
  instead of a wait result — plus nested dot-path support (`alert.level`).
- `LiveAgent.ErrorStore.get_errors(since_id)` (tools.ex ~line 1279) already backs
  `get_errors`/`clear_errors`. `expect_no_errors` calls it and turns "empty" into `pass`.

## Architecture

```
expect_assign(pid, key, equals|matches, timeout_ms?)
   └─ resolve dot-path → poll assign (reuse wait_for's poller)
        └─ {pass, actual, expected, path, waited_ms}

expect_no_errors(since_id?)
   └─ ErrorStore.get_errors(since_id)
        └─ {pass: errors == [], errors: [...], count}
```

**`expect_assign` return shape:**

```elixir
%{
  pass: false,
  path: "alert.level",
  expected: %{equals: "emergency"},
  actual: "yellow",
  waited_ms: 0
}
```

## Slices

Mark each slice complete by changing `[ ]` to `[x]` as it lands.

### Slice 1 — Key-path resolver (shared)
- [x] `LiveAgent.KeyPath.get(data, "a.b.c")` — nested map/struct access, returns
      `{:ok, value}` | `:not_found`; matches string keys first, then existing-atom keys
      (so it works on both sanitized and raw assigns). Used by `expect_assign`; available
      to unblock `features.md` #1. Covered by `test/key_path_test.exs`.

### Slice 2 — `expect_assign`
- [x] MCP tool `expect_assign` — args `pid`, `key` (dot-path via KeyPath), one of
      `equals` / `matches` (regex, falling back to substring, on the stringified value),
      optional `timeout_ms` (default 0 = check now; >0 = poll, clamped to 30s like
      `wait_for`).
- [x] Reuses the `wait_for` assign poll (`SocketInspector.get_assigns` + 100ms loop); on
      timeout returns `pass: false` with the last observed `actual`, never an error.
      `equals` is a typed compare with a stringified fallback; `matches` operates on the
      stringified form. Missing key path → `pass: false` + a note, not an error.
- [x] Description states it's the assertion sibling of `get_assign` and feeds the `verify`
      skill.

### Slice 3 — `expect_no_errors`
- [x] MCP tool `expect_no_errors(since_id?)` over `ErrorStore.get_errors/1`; `pass` iff
      empty, else returns the errors + count.
- [x] Description documents the gate pattern: `clear_errors` → act → `expect_no_errors`.

### Slice 4 — Docs
- [x] README MCP-tools table rows for `expect_assign` / `expect_no_errors`, plus a
      "Via assertions" section with the clear→act→assert demo and matcher semantics.

## Decisions deferred
- **Richer matchers** (numeric `>`/`<`, list membership, "is loaded" for Ash aggregates) —
  start with `equals` / `matches`; extend on demand.
- **`expect_element` / `expect_text`** (DOM-side assertions, browser MutationObserver) —
  natural companions, but the assign + error pair covers the highest-frequency cases first.
- **Batch assertions** (assert several at once, get a combined report) — park until single
  assertions are in use.

## Risks
- **Over-stringification**: comparing complex structs via `inspect` is brittle. Mitigation:
  `equals` does a typed compare for scalars and a stringified compare only as fallback;
  document that `matches` operates on the stringified form.
- **`since_id` drift for `expect_no_errors`**: callers forget to `clear_errors` first and
  see stale errors. Mitigation: support an explicit `since_id` and document the
  clear→act→assert order in the tool description.
- **False confidence on async**: an assign not yet updated reads as a fail. Mitigation: the
  optional `timeout_ms` poll (Slice 2) lets Claude wait out the async settle, same bound as
  `wait_for`.
