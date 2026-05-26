# Act As Actor — "Drive The App As This User, Without The Login Dance"

> Requested by the PostOpGuard team, from a 75-session transcript audit (2026-05-25).
> The single most-repeated manual ritual in the transcripts was: fill the magic-link form,
> submit, wait, navigate — *just to land authenticated as a given persona* — before testing
> org isolation ("user in org B must not see org A's patients"). It's the most-tested
> invariant in a multi-tenant app and the most tedious to set up by hand every session.

## Goal

Let Claude land the panel's browser session authenticated as a chosen user/org in one call,
so the real driving tools (`click`/`fill`/`navigate`) then exercise the app *as that actor*.
Two user-facing scenarios:

1. **"Test org isolation."** — `act_as(org_b_admin)` → navigate to org A's patient → expect
   a 404 / forbidden. Then `act_as(org_a_admin)` → same URL → expect the record. No
   magic-link round-trip between personas.
2. **"Repro a role-specific bug."** — "the surgeon view crashes for non-admins" →
   `act_as(read_only_member)` → click the failing control → read the error.

## Constraint (decided)

- **live-agent never mints sessions itself.** It is app-agnostic and cannot know the host's
  auth scheme (AshAuthentication, custom, etc.). It will NOT guess cookies or forge tokens.
- **The host app supplies the credential closure.** Activation requires an explicit
  `:act_as` config function; absent that, the tool refuses with a clear message. This
  mirrors the existing ethos — live-agent provides plumbing, the app owns the privileged
  bit (cf. the Drive toggle being off by default in `01_agent_controls`).
- **Dev/test only.** Hard env gate. Impersonation never compiles into a prod path.

## Mechanism (grounded in current code)

- live-agent drives the **real browser** through `LiveAgent.CommandQueue` → panel JS
  executor (real DOM events / navigation), so auth is whatever session that browser holds.
  To "become" a user we must establish that browser's session — we cannot set an actor
  server-side and have the live socket pick it up.
- live-agent ships a **dev-only sign-in route** (`POST /live_agent/act_as`, mounted by the
  same plug that mounts `/api/commands`, behind the env gate). It calls the app-provided
  `:act_as` closure to write the session, then the panel reloads so the LiveSocket
  reconnects authenticated.
- The closure is the app's responsibility and the only place real credentials are minted,
  e.g. in a host app's config:

  ```elixir
  config :live_agent,
    act_as: fn conn, identifier ->
      user = MyApp.Accounts.get_user_for_dev!(identifier)   # app decides how to resolve
      MyAppWeb.AuthPlug.sign_in(conn, user)                 # app's own sign-in
    end
  ```

## Architecture

```
Claude ──MCP──▶ act_as(identifier)
                    │
                    ▼
              CommandQueue: enqueue {op: "act_as", identifier}
                    │
              Panel JS executor ── POST /live_agent/act_as {identifier}
                    │                         │
                    │                  Router (dev-gated plug)
                    │                    ├─ config[:act_as].(conn, identifier)   # app mints session
                    │                    └─ returns {ok, who}
                    │
              Panel JS: window.location.reload()   # LiveSocket reconnects as the new actor
                    │
              snapshot: new current_scope (via 04 get_scope) returned to Claude
```

## Host integration — worked example (AshAuthentication + multitenancy)

This is the closure for the requesting app (PostOpGuard: AshAuthentication, cookie
sessions, org-per-tenant). It is intentionally tiny — the app already owns a sign-in
primitive; the closure just calls it against a dev-resolved user. It also demonstrates the
two things every host integrator needs to get right.

```elixir
# config/dev.exs — both keys read by LiveAgent.Config (Slice 1).
# :session_options is a CO-REQUISITE of :act_as. Copy it VERBATIM from your endpoint's
# @session_options (same key + signing_salt + encryption_salt + same_site) — a mismatch
# does not error, it silently fails to authenticate after reload (the LiveSocket can't
# decode a cookie signed with a different salt). Prefer a named capture for :act_as so the
# privileged code is greppable, testable, and lives in lib/ (not buried in config).
config :live_agent,
  session_options: [store: :cookie, key: "_postopguard_key", signing_salt: "/UyvjwgL", same_site: "Lax"],
  act_as: &PostopguardWeb.DevActAs.sign_in/2
```

```elixir
# lib/postopguard_web/dev_act_as.ex
defmodule PostopguardWeb.DevActAs do
  @moduledoc "Dev-only: mint a real session for an arbitrary user so live-agent can drive as them."
  import AshAuthentication.Phoenix.Plug, only: [store_in_session: 2]

  # identifier is whatever live-agent passed through verbatim (here: an email).
  def sign_in(conn, identifier) do
    user =
      Postopguard.Accounts.User
      |> Ash.get!(%{email: identifier}, action: :get_by_email, authorize?: false)

    store_in_session(conn, user)   # exactly what AuthController.success/2 does after a real login
  end
end
```

Three host-specific points that generalise to any AshAuthentication app:

1. **Resolve with `authorize?: false`.** The `User` read is policy-forbidden for an
   interactive actor (no actor exists yet — that's the whole point), so a normal scoped
   read would refuse. Bypassing is correct here: this is dev-only code whose entire job is
   to mint a session. Same posture as seed/mix-task user reads.

2. **Org/tenant isolation comes for free — do not thread tenant through the closure.**
   In this app `User` is global and the tenant is *derived* from the user's
   `organization_id`, loaded into `current_scope` by the on_mount when the LiveSocket
   reconnects after the reload. So `act_as("orgB-admin@…")` lands the panel scoped to org B
   automatically. The closure mints the *actor*; the app's existing scope-resolution mints
   the *tenant*. This is precisely why the org-isolation scenario (the feature's headline
   use case) needs no extra wiring — `act_as` then `navigate` to org A's record yields the
   expected forbidden/404.

3. **The closure must NOT fetch the session — live-agent does it first.** With
   `plug LiveAgent` mounted *before* `Plug.Session` (the README setup, and this app's
   endpoint), the `/live_agent/act_as` forward halts before the endpoint's `Plug.Session`
   runs. So the conn arrives with (a) no fetched session — `store_in_session/2` →
   `put_session/3` would raise — and (b) no registered `before_send`, so even a written
   session would never be re-encoded into the response cookie. live-agent therefore runs the
   session plug itself in the route, from `:session_options`, *before* invoking the closure:

   ```elixir
   conn =
     if match?(%{plug_session_fetch: _}, conn.private) do
       conn                                            # host mounted us AFTER Plug.Session
     else
       conn
       |> Plug.Session.call(Plug.Session.init(session_options))
       |> fetch_session()
     end
   ```

   This is why `:session_options` is a co-requisite, and why the closure above stays verbatim
   (`store_in_session` only — no `fetch_session`, no session plumbing). The "let the closure
   call `fetch_session`" alternative does **not** work: a bare `fetch_session/1` with no prior
   `Plug.Session.call` raises `"cannot fetch session without a configured session plug"`, and
   would still leave the cookie unwritten — the closure would have to run `Plug.Session.call`
   itself, duplicating `session_options` into every host. Centralising it in live-agent is the
   right call. If `:session_options` is missing, `act_as` must return the same shape of clear
   error as the missing-closure case, pointing the user at their endpoint's `@session_options`.

Why this stays safe in this app specifically: the host depends on live_agent with
`only: :dev` (`mix.exs`), so the plug, the `/live_agent/act_as` route, and the MCP tool
**do not compile** outside `:dev` at all — a fourth, build-level lock underneath the three
in Risks. (Trade-off: such hosts cannot exercise `act_as` from `:test`; the panel-driven
flow is a dev activity regardless. If a host pulls live_agent into `:test` too, the
`:dev`/`:test` env gate in Slice 1 is the operative lock.)

Contract for `LiveAgent.Config.act_as_fun/0` (Slice 1), confirmed against this example:
- arity `2`, called as `fun.(conn, identifier)`; `identifier` is the raw MCP string.
- **must return a `%Plug.Conn{}`** with the session written; live-agent then signals the
  panel to reload. A raised exception (e.g. user not found) must surface as the structured
  error from Slice 2, never a half-written session.
- live-agent inspects nothing inside the returned conn except that it is a conn — it does
  not know or care which session keys the app set.

## Slices

Mark each slice complete by changing `[ ]` to `[x]` as it lands.

### Slice 1 — Config + guard rails
- [x] `LiveAgent.Config.act_as_fun/0` reads `:act_as` (`{:ok, fun}` | `:not_configured` |
      `:bad_arity`); `act_as_enabled?/0` is a compile-time boolean, true only in
      `:dev`/`:test`.
- [x] `LiveAgent.Config.session_options/0` reads `:session_options` (co-requisite of
      `:act_as` — see "Host integration"). Required because `plug LiveAgent` mounts before
      `Plug.Session`, so the act_as route must set up the session itself.
- [x] If `:act_as` OR `:session_options` is unset, or wrong env: both the route and the
      `act_as` MCP tool return a precise error naming the missing key (pointing
      `:session_options` at the endpoint's `@session_options`) and that it is dev-only.
      Never a silent no-op.

### Slice 2 — Sign-in route
- [x] `POST /live_agent/act_as` in `lib/router.ex`, behind the env gate. Before the closure,
      establishes the session from `:session_options`
      (`Plug.Session.call(Plug.Session.init(opts)) |> fetch_session()`), guarded with
      `match?(%{plug_session_fetch: _}, conn.private)` to skip if already session-fetched.
      Then invokes the closure with `{conn, identifier}`, validates it returned a
      `%Plug.Conn{}`, and sends *that* conn so the cookie is written back. A raising closure
      → structured 422, never a half-written session.
- [x] Logs every impersonation to the existing event store via `EventStore.push_custom/1`
      (type `act_as`, the identifier, timestamp), so it shows in the Events pane —
      same audit posture as Drive commands. (Command-id not threaded to the route; the
      identifier + timestamp cover the audit need.)

### Slice 3 — MCP tool + panel executor
- [x] `act_as(identifier)` MCP tool: gates env/config first, enqueues the command; `cmdActAs`
      POSTs the route then reloads (result posted before reload, like href-navigate). Reuses
      the CommandQueue await-result pattern.
- [x] On success, returns the post-reload scope: the tool snapshots LV pids before, then
      polls for the *fresh* connected LV after reconnect and reads `get_scope` (plan 04) on
      it — Claude confirms who it now is without a second call. Reconnect-settle is
      server-side (no browser signaling needed).
- [x] Refuses if the Drive toggle is off — `act_as` is in the browser `driveOps` set, so it
      errors exactly like `click`/`fill` when Drive is off.

### Slice 4 — Docs
- [x] README "Agent controls" section: `act_as` tool-table row, an "Acting as a user"
      subsection with the four locks, the `:act_as` closure + `:session_options`
      co-requisite (copy verbatim — salt-mismatch footgun called out), the dev-only gate,
      and the org-isolation demo script.

## Decisions deferred
- **Sign-out / restore previous session** — a `restore_session` companion. Useful but adds
  state tracking; park until `act_as` is in use.
- **Resolving identifiers** (email vs id vs persona name) — left entirely to the app's
  closure; live-agent passes the string through verbatim.
- **Multi-tab / multi-session** — MVP impersonates the single panel browser.

## Risks
- **Privileged surface**: a route that logs you in as anyone. Mitigation: dev/test env gate
  *and* a required app-supplied closure *and* the Drive toggle — three independent locks,
  none of which exist in prod builds. Document loudly in the README.
- **App-coupling**: the closure must match the app's auth. Mitigation: live-agent owns none
  of it; a missing/raising closure returns a clear error, never a half-authenticated state.
- **Stale socket after reload**: the LiveSocket must fully reconnect before the next drive
  command. Mitigation: the panel signals reconnection complete before the command result is
  posted (reuse the snapshot-settle wait from `01_agent_controls`).
