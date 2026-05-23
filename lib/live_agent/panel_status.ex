defmodule LiveAgent.PanelStatus do
  @moduledoc false
  # Tracks the latest readiness signal posted by the browser panel.
  #
  # The panel reports on every command poll (and once on init via /api/hello),
  # so we always know whether there's a panel parked to service a command and
  # whether the host page has finished hydrating. Used by CommandQueue to gate
  # browser-bound MCP tools — anything routed through `enqueue_and_await/2`
  # waits briefly for a "ready" panel before being enqueued, so the host agent
  # doesn't see transient failures during a hot-reload or first-load window.
  #
  # Single-panel state by design: multiple browser tabs racing across a reload
  # is rare and the last writer wins, which is what callers want anyway (the
  # most recently-active panel is the one likely to service the next command).

  use GenServer

  @ready_stale_after_ms 3_000
  @poll_interval_ms 50

  defstruct generation: nil,
            first_seen_at: nil,
            last_seen_at: nil,
            document_ready: false,
            live_socket_connected: false,
            root_lv_present: false,
            url: nil

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %__MODULE__{}, name: __MODULE__)

  @doc """
  Panel-side readiness signal. `payload` may include:
    * "gen" — opaque per-page-load id (string)
    * "doc" — document.readyState === "complete" (truthy)
    * "lv"  — liveSocket.isConnected() (truthy)
    * "main"— [data-phx-main] element exists (truthy)
    * "url" — current location.pathname + search
  Missing keys are treated as falsy.
  """
  def report(payload) when is_map(payload) do
    GenServer.cast(__MODULE__, {:report, payload, now_ms()})
  end

  @doc """
  Returns the current snapshot as a plain map, with `:ready` and
  `:last_seen_age_ms` computed against `now`.
  """
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc """
  Blocks the calling process until the panel is reported ready, or until
  `timeout_ms` elapses. Always returns the latest snapshot.

  This is a best-effort gate — callers should still handle the case where the
  panel never becomes ready (e.g., no browser tab open).
  """
  def wait_until_ready(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = now_ms() + timeout_ms
    do_wait(deadline)
  end

  defp do_wait(deadline) do
    snap = snapshot()

    cond do
      snap.ready ->
        {:ok, snap}

      now_ms() >= deadline ->
        {:timeout, snap}

      true ->
        Process.sleep(@poll_interval_ms)
        do_wait(deadline)
    end
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:report, payload, ts}, %__MODULE__{} = state) do
    gen = stringify(Map.get(payload, "gen"))
    new_load? = gen != nil and gen != state.generation

    first_seen_at =
      cond do
        new_load? -> ts
        is_nil(state.first_seen_at) -> ts
        true -> state.first_seen_at
      end

    state = %{
      state
      | generation: gen || state.generation,
        first_seen_at: first_seen_at,
        last_seen_at: ts,
        document_ready: truthy?(Map.get(payload, "doc")),
        live_socket_connected: truthy?(Map.get(payload, "lv")),
        root_lv_present: truthy?(Map.get(payload, "main")),
        url: stringify(Map.get(payload, "url")) || state.url
    }

    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, to_snapshot(state, now_ms()), state}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp to_snapshot(%__MODULE__{last_seen_at: nil} = state, _now) do
    %{
      ready: false,
      generation: state.generation,
      last_seen_age_ms: nil,
      document_ready: false,
      live_socket_connected: false,
      root_lv_present: false,
      url: state.url,
      reason: "no panel has reported yet"
    }
  end

  defp to_snapshot(%__MODULE__{} = s, now) do
    age = now - s.last_seen_at
    # Heartbeat refreshes only at /api/commands poll-start, but the poll itself
    # can park for up to CommandQueue's @poll_timeout_ms (25s). A parked waiter
    # is positive proof the panel is alive, so treat that as fresh too —
    # otherwise we report `panel last seen too long ago` for ~22s of every 25s
    # window even when the panel is healthy.
    fresh = age < @ready_stale_after_ms or LiveAgent.CommandQueue.has_parked_waiter?()
    page_ready = s.document_ready and (s.live_socket_connected or not s.root_lv_present)
    ready = fresh and page_ready

    %{
      ready: ready,
      generation: s.generation,
      last_seen_age_ms: age,
      document_ready: s.document_ready,
      live_socket_connected: s.live_socket_connected,
      root_lv_present: s.root_lv_present,
      url: s.url,
      reason: not_ready_reason(fresh, s)
    }
  end

  defp not_ready_reason(false, _s), do: "panel last seen too long ago"
  defp not_ready_reason(_, %{document_ready: false}), do: "document not fully loaded"

  defp not_ready_reason(_, %{root_lv_present: true, live_socket_connected: false}),
    do: "liveSocket not connected"

  defp not_ready_reason(_, _), do: nil

  defp truthy?(v) when v in [true, 1, "1", "true", "yes"], do: true
  defp truthy?(_), do: false

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
