# Actor & Scope Surfacing — "Run It As The User On Screen"

> Requested by the PostOpGuard team, from a 75-session transcript audit (2026-05-25).
> Inside live-agent sessions we dropped to Tidewave `project_eval` **236 times** and raw
> `execute_sql_query` **44 times** — and the overwhelmingly common reason was *"reconstruct
> the actor/tenant/scope by hand so this Ash call returns what the logged-in user actually
> sees."* live-agent already knows the live socket; it should hand us that scope instead of
> making us rebuild it.

## Goal

Surface the multi-tenant security context bound to a running LiveView so Claude can reason
about — and evaluate against — exactly what the user on screen is authorized to see. Two
user-facing scenarios:

1. **"What's this user's scope?"** — Claude asks for the actor / tenant / scope on a LV and
   gets a compact, sanitized map (`actor: User MRN-…, tenant: "org_abc", …`) instead of
   grepping a 350k-char assigns dump for `current_scope`.
2. **"Would this query leak across orgs?"** — Claude evaluates an Ash read *with the live
   socket's scope already bound*, reproducing the user's exact authorization boundary,
   rather than passing `authorize?: false` or a hand-built scope that doesn't match.

## Constraint (decided)

- **live-agent does not build a second eval engine.** Tidewave already owns
  `project_eval`. live-agent's job is to *supply the bindings* — extract the scope from the
  live socket and make it trivially usable. The flagship deliverable is read-only
  (`get_scope`); the eval convenience is a thin, opt-in layer (see Slice 3) and is gated to
  dev like the existing Drive toggle.
- **No assumptions about the app's scope shape.** Ash apps vary: `current_scope`,
  `current_user` + `__tenant__`, `current_organization`. The extractor is heuristic +
  config-overridable, never hard-coded to one key.

## Mechanism (grounded in current code)

- `LiveAgent.SocketInspector.get_assigns/1` and `get_socket_info/1` already read the live
  socket via `:sys.get_state(pid, …)` and sanitize structs. Scope extraction is a
  specialization of that read — no new capture path.
- The bound scope lives in `socket.assigns`. In Ash 3 apps that is typically an
  `Ash.Scope`-carrying struct under `:current_scope` (actor + tenant + context), or the
  `:current_user` / `:__tenant__` pair. We read those keys and sanitize.
- `eval_as` (Slice 3) is **verify-first**: whether live-agent can inject bindings into
  Tidewave's eval cleanly depends on Tidewave's public surface. If there is no supported
  hook, Slice 3 degrades to returning a *paste-ready preamble* (binding assignments) that
  Claude prepends to its own `project_eval` call — still removing the hand-reconstruction.

## Architecture

```
Claude ──MCP──▶ get_scope(pid)
                    │
                    ▼
         LiveAgent.ScopeInspector            (new, sits beside SocketInspector)
           ├─ SocketInspector.get_socket(pid)        # existing :sys.get_state read
           ├─ resolve scope keys (config + heuristics):
           │     :current_scope | :current_user + :__tenant__ | :current_organization
           ├─ sanitize via existing SocketInspector struct sanitizer
           └─ return %{actor: …, tenant: …, context: …, source_keys: [...]}

         eval_as(pid, code)  (Slice 3, dev-gated)
           ├─ get_scope(pid) → bindings
           └─ Tidewave eval WITH scope/actor/tenant pre-bound   (or paste-ready preamble)
```

**`get_scope` return shape:**

```elixir
%{
  actor:   %{module: "Postopguard.Accounts.User", id: "…", summary: "MRN-48201"},
  tenant:  "org_abc123" | nil,
  context: %{...},                 # Ash.Scope context, sanitized + size-capped
  source_keys: ["current_scope"],  # which assign(s) we read it from
  raw_present: true                # false → no scope-like assign found
}
```

## Slices

Mark each slice complete by changing `[ ]` to `[x]` as it lands.

### Slice 1 — Scope extraction (read-only, flagship)
- [x] `LiveAgent.ScopeInspector.get_scope/1` (pid or pid-string), reusing
      `SocketInspector.get_socket/1` + the existing struct sanitizer (exposed as
      `SocketInspector.sanitize_value/1`).
- [x] Heuristic key resolution: try `:current_scope` / `:scope` first, then
      `:current_user` (+ `:__tenant__` / `:current_organization` / …), then a
      tenant-only assign. Config override `:scope_assign_keys` in `LiveAgent.Config`
      (plumbed through `LiveAgent.init/1`), tried *before* the built-in keys.
- [x] Return `raw_present: false` (not an error) when no scope-like assign exists, so
      Claude can tell "unscoped LV" from "lookup failed". Context is sanitized and
      size-capped (4 KB → `__truncated__` summary).

### Slice 2 — MCP tool
- [x] Register `get_scope` in `LiveAgent.MCP.Tools.tools/0` (name/description/callback
      pattern, same as `get_assigns`).
- [x] Description states the rubric: call this before any `project_eval` that touches
      tenant-scoped data; describes binding the returned actor/tenant into the eval.

### Slice 3 — `eval_as` convenience (dev-gated, verify-first) — DEFERRED
- [x] Spike finding (2026-05-25): **Tidewave is not a dependency of live-agent** — it
      is a host-app dep, so its eval surface (`Tidewave.MCP.Tools.FS`/eval internals)
      is not introspectable from this repo, and live-agent must not hard-couple to
      private Tidewave functions across versions. Per the plan's own degrade clause,
      `eval_as` would ship as the **paste-ready preamble** form, not a binding
      injection. That preamble is just a string built from `get_scope` output —
      low marginal value over the `get_scope` rubric Claude already follows — so the
      eval convenience is **deferred** until there's a confirmed, version-stable
      Tidewave hook *or* demonstrated demand. The flagship read path (Slices 1/2)
      ships standalone, as the plan intends.
- [ ] (deferred) `eval_as(pid, code)` with `scope`/`actor`/`tenant` pre-bound.
- [ ] (deferred) paste-ready binding preamble fallback.

### Slice 4 — Docs
- [x] README MCP-tools table: `get_scope`; `scope_assign_keys` in the Options table.
- [x] Demo script: "Via the scope inspector" section — read scope + reproduce an
      org-isolation check as the logged-in user.

## Decisions deferred
- **Mutating as the actor** (running a create/update with the bound scope) — write surface;
  park until the read path proves out and demand is real.
- **Multi-root scope** (nested LVs with different scopes) — MVP reads the queried pid only.

## Risks
- **Scope shape drift / non-Ash apps**: heuristics miss a custom key. Mitigation: config
  override + `raw_present: false` rather than guessing wrong.
- **Sensitive context** (tokens, secrets inside `Ash.Scope` context): same redaction
  concern as the assigns reader. Mitigation: reuse the assigns sanitizer's size cap and
  honor `:redact_keys` if/when it lands; document it.
- **`eval_as` as an attack surface**: arbitrary eval with elevated scope. Mitigation: hard
  env gate (`:dev`/`:test` only), event-store logging, and it ships **off** if Tidewave has
  no clean hook (degrade to paste-ready preamble).
