defmodule LiveAgent.CommandQueue do
  @moduledoc false
  # Bridges MCP tool callers (which want to dispatch a browser command and
  # block until they see the result) with the panel JS (which long-polls
  # for commands and POSTs results back).
  #
  # Multi-tab routing
  # ─────────────────
  # When several browser tabs are open, each runs its own command long-poll.
  # We must deliver a command to the tab the user actually wants driven, not
  # whichever happens to poll first. The "Drive" toggle in the panel is that
  # selector: the tab with Drive ON is the agent's target.
  #
  # Every poll (and the /api/hello beacon fired when Drive is toggled) carries
  # the panel's `panel_id` (the per-page-load `gen`) and its `drive` flag, so
  # the server keeps a small registry:
  #
  #   panels: panel_id => %{drive: bool, last_seen: ts, waiter: {from, ref} | nil}
  #
  #   - mcp_waiters: id => from   (MCP tool call awaiting its result)
  #   - waiter (per panel)        (that tab's parked long-poll awaiting work)
  #
  # On enqueue we deliver to the *target* panel (the freshest Drive-on tab). If
  # no tab has Drive on we fall back to any parked tab, preserving single-tab
  # behaviour where the user never flips Drive (read-only ops still work; the
  # mutating ops are gated browser-side as before).

  use GenServer

  @poll_timeout_ms 25_000

  # A panel is considered gone if we haven't heard from it for this long and it
  # has no parked poll. Kept just above @poll_timeout_ms so a healthy panel
  # mid-park is never treated as stale.
  @panel_stale_ms 30_000

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Enqueue a command for the browser and block until the panel posts the
  result.

  Options:
    * `:timeout_ms` (default 15_000) — total time to wait for the panel to
      execute the command and POST back its result.
    * `:wait_ready_ms` (default 3_000) — best-effort readiness gate. Blocks
      briefly waiting for `LiveAgent.PanelStatus` to report the panel as
      ready (panel polling, document loaded, liveSocket connected) before
      enqueueing the command. This bridges the gap during a host
      hot-reload, first-load, or cross-page navigation without leaking
      transient failures up to MCP callers. Tunable per-call so callers
      with a higher mis-fire cost (e.g. screenshot) can wait longer.

  Returns `{:ok, result}` from the panel, or `{:error, :timeout}` if the
  command's `:timeout_ms` elapsed before the panel responded. The
  readiness gate itself never causes a failure — if the panel isn't ready
  by `:wait_ready_ms`, the command is enqueued anyway and the regular
  command timeout takes over.

  Legacy integer timeout — `enqueue_and_await(op, args, 30_000)` — is
  still accepted and interpreted as `[timeout_ms: 30_000]`.
  """
  def enqueue_and_await(op, args, opts \\ [])

  def enqueue_and_await(op, args, timeout_ms)
      when is_binary(op) and is_map(args) and is_integer(timeout_ms) do
    enqueue_and_await(op, args, timeout_ms: timeout_ms)
  end

  def enqueue_and_await(op, args, opts) when is_binary(op) and is_map(args) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 15_000)
    wait_ready_ms = Keyword.get(opts, :wait_ready_ms, 3_000)

    LiveAgent.PanelStatus.wait_until_ready(wait_ready_ms)

    GenServer.call(
      __MODULE__,
      {:enqueue, op, args, timeout_ms},
      timeout_ms + 2_000
    )
  end

  @doc """
  Long-poll for pending commands on behalf of one panel tab.

  `panel_id` is the panel's per-page-load id (the `gen` it reports), `drive`
  is whether that tab's Drive toggle is currently ON, and `url` is the tab's
  current path (used to surface the Drive target in `list_live_views`).
  Returns immediately with pending commands targeted at this tab if any,
  otherwise parks for up to `timeout_ms`, then returns `[]`.
  """
  def poll(panel_id, drive, url \\ nil, timeout_ms \\ @poll_timeout_ms)
      when is_binary(panel_id) and is_boolean(drive) and (is_binary(url) or is_nil(url)) do
    GenServer.call(__MODULE__, {:poll, panel_id, drive, url, timeout_ms}, timeout_ms + 2_000)
  end

  @doc """
  Out-of-band drive-state update for a panel — fired by the panel's
  `/api/hello` beacon when the user toggles Drive, so the target switches
  without waiting for the current long-poll to cycle. If this makes the
  panel the new target and a command is already pending, it's flushed to
  the panel's parked poll immediately.
  """
  def note_panel(panel_id, drive, url \\ nil)
      when is_binary(panel_id) and is_boolean(drive) and (is_binary(url) or is_nil(url)) do
    GenServer.cast(__MODULE__, {:note_panel, panel_id, drive, url})
  end

  @doc """
  The current Drive target tab — the freshest still-alive panel with Drive
  ON — as `%{panel_id: id, url: url}`, or `nil` when no tab has Drive on.
  Used by `list_live_views` to point the agent at the tab it will drive.
  """
  def active_drive_target do
    GenServer.call(__MODULE__, :active_drive_target)
  end

  @doc """
  Deliver the result for a command id back to its parked MCP caller.
  Returns `:ok` if a caller was waiting, `{:error, :not_found}` otherwise.
  """
  def post_result(id, result) when is_integer(id) do
    GenServer.call(__MODULE__, {:result, id, result})
  end

  @doc """
  Whether any panel long-poll is currently parked, awaiting a command.

  A parked waiter is positive proof a panel is alive (it just opened the
  HTTP request), so `LiveAgent.PanelStatus` uses this to bridge the
  freshness gap between long-poll cycles — heartbeat data only refreshes
  at poll-start, but the poll itself can park for up to `@poll_timeout_ms`.
  """
  def has_parked_waiter? do
    GenServer.call(__MODULE__, :has_parked_waiter?)
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok,
     %{
       next_id: 1,
       pending: [],
       mcp_waiters: %{},
       panels: %{}
     }}
  end

  @impl true
  def handle_call({:enqueue, op, args, timeout_ms}, from, state) do
    id = state.next_id
    cmd = %{id: id, op: op, args: args}

    state = %{state | next_id: id + 1, mcp_waiters: Map.put(state.mcp_waiters, id, from)}

    Process.send_after(self(), {:mcp_timeout, id}, timeout_ms)

    {:noreply, dispatch_or_pend(state, cmd)}
  end

  def handle_call({:poll, panel_id, drive, url, timeout_ms}, from, state) do
    now = now_ms()

    panel =
      state.panels
      |> Map.get(panel_id, new_panel(drive, now, url))
      |> merge_report(drive, now, url)

    # A fresh poll supersedes any previous parked poll for this same tab
    # (e.g. one left dangling by an aborted request); the old `from` is dead,
    # so dropping it is safe.
    state = put_in(state.panels[panel_id], %{panel | waiter: nil})

    cond do
      state.pending != [] and panel_eligible_for_pending?(state, panel_id) ->
        # All pending commands go to this eligible poller.
        {:reply, state.pending, %{state | pending: []}}

      true ->
        ref = make_ref()
        Process.send_after(self(), {:poll_timeout, panel_id, ref}, timeout_ms)
        {:noreply, put_in(state.panels[panel_id].waiter, {from, ref})}
    end
  end

  def handle_call(:has_parked_waiter?, _from, state) do
    {:reply, Enum.any?(state.panels, fn {_id, p} -> p.waiter != nil end), state}
  end

  def handle_call(:active_drive_target, _from, state) do
    now = now_ms()
    alive = Enum.filter(state.panels, fn {_id, p} -> alive?(p, now) end)

    reply =
      case target_entry(alive) do
        {panel_id, p} -> %{panel_id: panel_id, url: p.url}
        nil -> nil
      end

    {:reply, reply, state}
  end

  def handle_call({:result, id, result}, _from, state) do
    case Map.pop(state.mcp_waiters, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {mcp_from, rest} ->
        GenServer.reply(mcp_from, {:ok, result})
        {:reply, :ok, %{state | mcp_waiters: rest}}
    end
  end

  @impl true
  def handle_cast({:note_panel, panel_id, drive, url}, state) do
    now = now_ms()

    panel =
      state.panels
      |> Map.get(panel_id, new_panel(drive, now, url))
      |> merge_report(drive, now, url)

    state = put_in(state.panels[panel_id], panel)

    # Toggling Drive ON may make this the target for a command that's been
    # waiting in `pending` — flush it to this tab's parked poll if it has one.
    state =
      if state.pending != [] do
        case flush_pending_to_target(state) do
          {:ok, new_state} -> new_state
          :noop -> state
        end
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:mcp_timeout, id}, state) do
    case Map.pop(state.mcp_waiters, id) do
      {nil, _} ->
        {:noreply, state}

      {mcp_from, rest} ->
        GenServer.reply(mcp_from, {:error, :timeout})
        pending = Enum.reject(state.pending, &(&1.id == id))
        {:noreply, %{state | mcp_waiters: rest, pending: pending}}
    end
  end

  def handle_info({:poll_timeout, panel_id, ref}, state) do
    case get_in(state.panels, [panel_id, :waiter]) do
      {from, ^ref} ->
        GenServer.reply(from, [])
        {:noreply, put_in(state.panels[panel_id].waiter, nil)}

      _ ->
        {:noreply, state}
    end
  end

  # ── Routing helpers ───────────────────────────────────────────────────────

  # Deliver `cmd` to the target panel's parked poll, or hold it in `pending`
  # until the target (or any panel, in the no-target fallback) next polls.
  defp dispatch_or_pend(state, cmd) do
    case target_waiter(state) do
      {panel_id, {from, _ref}} ->
        GenServer.reply(from, [cmd])
        put_in(state.panels[panel_id].waiter, nil)

      nil ->
        %{state | pending: state.pending ++ [cmd]}
    end
  end

  # The parked poll we should hand the next command to:
  #   1. the freshest Drive-on tab that's currently parked, else
  #   2. (no Drive-on tab at all) any parked tab — single-tab / never-toggled
  #      fallback so read-only ops keep working.
  defp target_waiter(state) do
    now = now_ms()
    alive = Enum.filter(state.panels, fn {_id, p} -> alive?(p, now) end)

    drive_on_parked =
      alive
      |> Enum.filter(fn {_id, p} -> p.drive and p.waiter != nil end)
      |> Enum.sort_by(fn {_id, p} -> p.last_seen end, :desc)

    case drive_on_parked do
      [{panel_id, p} | _] ->
        {panel_id, p.waiter}

      [] ->
        if any_drive_on?(alive) do
          # A Drive-on tab exists but isn't parked right now (mid-execution).
          # Hold the command for it rather than leaking to a non-selected tab.
          nil
        else
          alive
          |> Enum.find(fn {_id, p} -> p.waiter != nil end)
          |> case do
            {panel_id, p} -> {panel_id, p.waiter}
            nil -> nil
          end
        end
    end
  end

  # Used by note_panel: when Drive flips on, push the head of `pending` to the
  # (now) target tab if it has a parked poll.
  defp flush_pending_to_target(%{pending: [cmd | rest]} = state) do
    case target_waiter(state) do
      {panel_id, {from, _ref}} ->
        GenServer.reply(from, [cmd])

        {:ok,
         state
         |> put_in([:panels, panel_id, :waiter], nil)
         |> Map.put(:pending, rest)}

      nil ->
        :noop
    end
  end

  defp flush_pending_to_target(_state), do: :noop

  # On poll, may this tab take the pending backlog? Yes if it's the target
  # (the freshest Drive-on tab), or if no tab has Drive on at all.
  defp panel_eligible_for_pending?(state, panel_id) do
    now = now_ms()
    alive = Enum.filter(state.panels, fn {_id, p} -> alive?(p, now) end)

    case target_panel_id(alive) do
      nil -> true
      ^panel_id -> true
      _ -> false
    end
  end

  # The freshest Drive-on panel id among `alive`, or nil if none has Drive on.
  defp target_panel_id(alive) do
    case target_entry(alive) do
      {panel_id, _p} -> panel_id
      nil -> nil
    end
  end

  # The freshest Drive-on `{panel_id, panel}` among `alive`, or nil.
  defp target_entry(alive) do
    alive
    |> Enum.filter(fn {_id, p} -> p.drive end)
    |> Enum.sort_by(fn {_id, p} -> p.last_seen end, :desc)
    |> List.first()
  end

  defp any_drive_on?(alive), do: Enum.any?(alive, fn {_id, p} -> p.drive end)

  defp alive?(%{waiter: waiter, last_seen: last_seen}, now) do
    waiter != nil or now - last_seen < @panel_stale_ms
  end

  defp new_panel(drive, now, url),
    do: %{drive: drive, last_seen: now, waiter: nil, url: url}

  # Fold a fresh report into an existing panel entry. A nil url (older payload
  # or non-poll beacon) leaves the last known url intact.
  defp merge_report(panel, drive, now, url) do
    %{panel | drive: drive, last_seen: now, url: url || panel[:url]}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
