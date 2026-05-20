# Feature Request: Improved `get_assigns` in live-agent MCP Server

## Context

While debugging a LiveView bug where `Ash.reload!` was clobbering loaded aggregates after a
PubSub broadcast, the `get_assigns` tool returned the full assigns map for the LiveView process.
The result was ~356,000 characters — exceeding the token limit — and had to be saved to a file
and parsed manually with a Python script just to extract the relevant fields.

---

## Requested Improvements

### 1. Key-path filtering on `get_assigns`

Allow callers to request a specific key or nested dot-path instead of the full map.

**Proposed API:**

```json
{
  "pid": "<0.1408.0>",
  "keys": [
    "current_user.total_amount_of_bounties_sponsored",
    "current_user.claimable_usd"
  ]
}
```

**Why:** The full assigns map for a LiveView with loaded Ash records (relationships, aggregates,
metadata) is enormous. In this case, only 9 fields out of hundreds were relevant to the bug.

---

### 2. Diff-aware `watch_assigns`

When watching assigns, return only what **changed** between two snapshots rather than the full
map each time.

**Proposed behaviour:**

- Capture a baseline snapshot on first call
- On subsequent calls (or after a specified event), return only the keys whose values changed

**Why:** The bug was that specific aggregate fields on `current_user` flipped from loaded values
to `%Ash.NotLoaded{}` after a button click. A before/after diff would have surfaced this
immediately without any manual parsing.

**Example output:**

```json
{
  "changed": {
    "current_user.total_amount_of_bounties_sponsored": {
      "before": { "coef": 31, "exp": -2, "sign": 1 },
      "after": {
        "field": "total_amount_of_bounties_sponsored",
        "type": "aggregate"
      }
    }
  }
}
```

---

### 3. Ash-aware value rendering

Recognise common Ash structs in the assigns output and render them in a human-readable form
rather than raw maps.

| Struct             | Raw output                            | Suggested output         |
| ------------------ | ------------------------------------- | ------------------------ |
| `%Ash.NotLoaded{}` | `{"field": "x", "type": "aggregate"}` | `"<not loaded>"`         |
| `%Decimal{}`       | `{"coef": 31, "exp": -2, "sign": 1}`  | `"0.31"`                 |
| `%DateTime{}`      | `{"year": 2026, "month": 3, ...}`     | `"2026-03-10T00:01:51Z"` |

**Why:** Raw Ash/Elixir struct representations make it hard to quickly read values and identify
problems. `%Ash.NotLoaded{}` vs a real value was the crux of this bug, but it was obscured
behind the generic map representation.

---

## Summary

| #   | Feature                             | Benefit                                                    |
| --- | ----------------------------------- | ---------------------------------------------------------- |
| 1   | Key-path filtering on `get_assigns` | Avoids token limit; faster targeted inspection             |
| 2   | Diff-aware `watch_assigns`          | Immediately surfaces what changed after a user action      |
| 3   | Ash-aware value rendering           | Makes assigns output human-readable without manual parsing |
