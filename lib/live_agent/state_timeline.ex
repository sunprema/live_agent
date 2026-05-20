defmodule LiveAgent.StateTimeline do
  @moduledoc false
  use GenServer

  alias LiveAgent.AssignsDiff
  alias LiveAgent.SocketInspector

  @max_entries 50
  @handler_id "live-agent-state-timeline"
  @grace_ms 60_000
  @guard_window_ms 200

  @telemetry_events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_params, :exception],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :live_component, :handle_event, :stop],
    [:phoenix, :live_component, :handle_event, :exception],
    [:phoenix, :live_view, :render, :stop]
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Returns the most recent N timeline entries for a pid (or pid string), newest first."
  def history(pid_or_string, last_n \\ 20)

  def history(pid, last_n) when is_pid(pid) and is_integer(last_n),
    do: GenServer.call(__MODULE__, {:history, pid, last_n})

  def history(str, last_n) when is_binary(str) and is_integer(last_n) do
    case SocketInspector.parse_pid(str) do
      {:ok, pid} -> history(pid, last_n)
      err -> err
    end
  end

  @doc "Returns a single timeline entry by id, or nil."
  def entry(pid, entry_id) when is_pid(pid) and is_integer(entry_id),
    do: GenServer.call(__MODULE__, {:entry, pid, entry_id})

  def entry(str, entry_id) when is_binary(str) and is_integer(entry_id) do
    case SocketInspector.parse_pid(str) do
      {:ok, pid} -> entry(pid, entry_id)
      err -> err
    end
  end

  @doc "Returns the most recent entry for a pid, or nil."
  def last_change(pid) when is_pid(pid),
    do: GenServer.call(__MODULE__, {:last_change, pid})

  def last_change(str) when is_binary(str) do
    case SocketInspector.parse_pid(str) do
      {:ok, pid} -> last_change(pid)
      _ -> nil
    end
  end

  @doc """
  If the most recent entry for `pid` has `trigger.kind == "unknown"` AND was
  recorded within `within_ms`, relabels it to `%{kind: "handle_async", name: name}`
  and returns `{:ok, entry_id}`. Otherwise returns `:no_match`.

  Used by `LiveAgent.AsyncInspector` to attribute "unknown" timeline entries
  to their async callback after the fact (Phoenix LiveView doesn't emit
  telemetry for `handle_async`, so we can only label retroactively).
  """
  def relabel_unknown_to_async(pid, name, within_ms \\ 150) when is_pid(pid),
    do: GenServer.call(__MODULE__, {:relabel_unknown_to_async, pid, name, within_ms})

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @telemetry_events,
      &__MODULE__.handle_telemetry/4,
      nil
    )

    {:ok, %{by_pid: %{}}}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler_id)

  @impl true
  def handle_call({:history, pid, last_n}, _from, state) do
    entries =
      case Map.get(state.by_pid, pid) do
        nil -> []
        %{entries: list} -> Enum.take(list, last_n)
      end

    {:reply, entries, state}
  end

  def handle_call({:entry, pid, entry_id}, _from, state) do
    result =
      with %{entries: list} <- Map.get(state.by_pid, pid),
           %{} = found <- Enum.find(list, fn e -> e.id == entry_id end) do
        found
      else
        _ -> nil
      end

    {:reply, result, state}
  end

  def handle_call({:last_change, pid}, _from, state) do
    result =
      case Map.get(state.by_pid, pid) do
        %{entries: [head | _]} -> head
        _ -> nil
      end

    {:reply, result, state}
  end

  def handle_call({:relabel_unknown_to_async, pid, name, within_ms}, _from, state) do
    case Map.get(state.by_pid, pid) do
      %{entries: [%{trigger: %{kind: "unknown"}} = head | tail]} = pid_state ->
        age_ms = DateTime.diff(DateTime.utc_now(), head.at, :millisecond)

        if age_ms <= within_ms do
          new_trigger = %{kind: "handle_async", name: to_string(name)}
          updated = %{head | trigger: new_trigger}
          new_pid_state = %{pid_state | entries: [updated | tail]}
          {:reply, {:ok, head.id}, %{state | by_pid: Map.put(state.by_pid, pid, new_pid_state)}}
        else
          {:reply, :no_match, state}
        end

      _ ->
        {:reply, :no_match, state}
    end
  end

  @impl true
  def handle_cast({:set_pending, pid, trigger, duration_us}, state) do
    state = ensure_pid_state(state, pid)

    {:noreply,
     update_pid(state, pid, fn s ->
       %{s | pending_trigger: trigger, pending_duration_us: duration_us, pending_at: now_ms()}
     end)}
  end

  def handle_cast({:commit_render, pid, post_assigns}, state) do
    state = ensure_pid_state(state, pid)
    pid_state = Map.fetch!(state.by_pid, pid)

    {trigger, duration_us} =
      if pid_state.pending_trigger != nil and
           now_ms() - pid_state.pending_at <= @guard_window_ms do
        {pid_state.pending_trigger, pid_state.pending_duration_us}
      else
        {%{kind: "unknown", note: "likely_handle_info"}, nil}
      end

    diff = AssignsDiff.diff(pid_state.prev_assigns, post_assigns)

    new_pid_state =
      if AssignsDiff.empty?(diff) and pid_state.entries != [] do
        %{
          pid_state
          | prev_assigns: post_assigns,
            pending_trigger: nil,
            pending_duration_us: nil,
            pending_at: 0
        }
      else
        entry = %{
          id: pid_state.next_id,
          at: DateTime.utc_now(),
          trigger: trigger,
          duration_us: duration_us,
          result: :ok,
          diff: AssignsDiff.bound_size(diff),
          exception: nil
        }

        entries = [entry | pid_state.entries] |> Enum.take(@max_entries)

        %{
          pid_state
          | entries: entries,
            next_id: pid_state.next_id + 1,
            prev_assigns: post_assigns,
            pending_trigger: nil,
            pending_duration_us: nil,
            pending_at: 0
        }
      end

    {:noreply, %{state | by_pid: Map.put(state.by_pid, pid, new_pid_state)}}
  end

  def handle_cast({:push_exception, pid, trigger, duration_us, exception}, state) do
    state = ensure_pid_state(state, pid)
    pid_state = Map.fetch!(state.by_pid, pid)

    entry = %{
      id: pid_state.next_id,
      at: DateTime.utc_now(),
      trigger: trigger,
      duration_us: duration_us,
      result: :exception,
      diff: %{changed: %{}, added: %{}, removed: %{}},
      exception: exception
    }

    entries = [entry | pid_state.entries] |> Enum.take(@max_entries)

    new_pid_state = %{
      pid_state
      | entries: entries,
        next_id: pid_state.next_id + 1,
        pending_trigger: nil,
        pending_duration_us: nil,
        pending_at: 0
    }

    {:noreply, %{state | by_pid: Map.put(state.by_pid, pid, new_pid_state)}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    Process.send_after(self(), {:cleanup, pid}, @grace_ms)
    {:noreply, state}
  end

  def handle_info({:cleanup, pid}, state) do
    {:noreply, %{state | by_pid: Map.delete(state.by_pid, pid)}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ── Telemetry handler (runs in the LV channel process) ─────────────────────

  def handle_telemetry(event_name, measurements, metadata, _config) do
    do_handle_telemetry(event_name, measurements, metadata)
  catch
    kind, reason ->
      require Logger

      Logger.error(
        "[LiveAgent.StateTimeline] telemetry handler crashed: " <>
          inspect({kind, reason, event_name})
      )
  end

  defp do_handle_telemetry([:phoenix, :live_view, :render, :stop], _measurements, %{socket: socket}) do
    if connected?(socket) do
      assigns = SocketInspector.extract_assigns(socket)
      GenServer.cast(__MODULE__, {:commit_render, self(), assigns})
    end
  end

  defp do_handle_telemetry(
         [:phoenix, :live_view, callback, :stop],
         measurements,
         %{socket: socket} = metadata
       )
       when callback in [:mount, :handle_params, :handle_event] do
    if connected?(socket) do
      trigger = build_trigger(:live_view, callback, metadata)
      GenServer.cast(__MODULE__, {:set_pending, self(), trigger, duration_us(measurements)})
    end
  end

  defp do_handle_telemetry(
         [:phoenix, :live_component, :handle_event, :stop],
         measurements,
         metadata
       ) do
    trigger = build_trigger(:live_component, :handle_event, metadata)
    GenServer.cast(__MODULE__, {:set_pending, self(), trigger, duration_us(measurements)})
  end

  defp do_handle_telemetry(
         [:phoenix, :live_view, callback, :exception],
         measurements,
         %{socket: socket} = metadata
       )
       when callback in [:mount, :handle_params, :handle_event] do
    if connected?(socket) do
      trigger = build_trigger(:live_view, callback, metadata)
      exception = format_exception(metadata)

      GenServer.cast(
        __MODULE__,
        {:push_exception, self(), trigger, duration_us(measurements), exception}
      )
    end
  end

  defp do_handle_telemetry(
         [:phoenix, :live_component, :handle_event, :exception],
         measurements,
         metadata
       ) do
    trigger = build_trigger(:live_component, :handle_event, metadata)
    exception = format_exception(metadata)

    GenServer.cast(
      __MODULE__,
      {:push_exception, self(), trigger, duration_us(measurements), exception}
    )
  end

  defp do_handle_telemetry(_, _, _), do: :ok

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp build_trigger(:live_view, :mount, metadata) do
    %{
      kind: "mount",
      params: safe_value(Map.get(metadata, :params)),
      uri: Map.get(metadata, :uri)
    }
  end

  defp build_trigger(:live_view, :handle_params, metadata) do
    %{
      kind: "handle_params",
      params: safe_value(Map.get(metadata, :params)),
      uri: Map.get(metadata, :uri)
    }
  end

  defp build_trigger(:live_view, :handle_event, metadata) do
    %{
      kind: "handle_event",
      event: Map.get(metadata, :event),
      params: safe_value(Map.get(metadata, :params))
    }
  end

  defp build_trigger(:live_component, :handle_event, metadata) do
    %{
      kind: "live_component_event",
      event: Map.get(metadata, :event),
      params: safe_value(Map.get(metadata, :params)),
      component: format_component(metadata)
    }
  end

  defp connected?(%Phoenix.LiveView.Socket{transport_pid: tpid}), do: not is_nil(tpid)
  defp connected?(_), do: false

  defp duration_us(%{duration: d}), do: System.convert_time_unit(d, :native, :microsecond)
  defp duration_us(_), do: nil

  defp format_component(%{component: c}) when is_atom(c),
    do: c |> inspect() |> String.replace_prefix("Elixir.", "")

  defp format_component(_), do: nil

  defp format_exception(meta) do
    kind = Map.get(meta, :kind, :error)
    reason = Map.get(meta, :reason)
    stack = Map.get(meta, :stacktrace, [])

    formatted_stack =
      stack
      |> Enum.take(5)
      |> Enum.map(fn frame ->
        try do
          Exception.format_stacktrace_entry(frame)
        rescue
          _ -> inspect(frame)
        end
      end)

    %{
      kind: to_string(kind),
      reason: reason |> inspect() |> String.slice(0, 500),
      stacktrace: formatted_stack
    }
  end

  defp safe_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp safe_value(v) when is_atom(v), do: Atom.to_string(v)
  defp safe_value(v) when is_list(v), do: Enum.map(v, &safe_value/1)

  defp safe_value(v) when is_map(v) do
    Map.new(v, fn {k, val} ->
      key = if is_atom(k), do: Atom.to_string(k), else: inspect(k)
      {key, safe_value(val)}
    end)
  rescue
    _ -> nil
  end

  defp safe_value(v), do: v |> inspect() |> String.slice(0, 200)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp ensure_pid_state(%{by_pid: by_pid} = state, pid) do
    if Map.has_key?(by_pid, pid) do
      state
    else
      ref = Process.monitor(pid)

      pid_state = %{
        prev_assigns: %{},
        entries: [],
        next_id: 1,
        monitor_ref: ref,
        pending_trigger: nil,
        pending_duration_us: nil,
        pending_at: 0
      }

      %{state | by_pid: Map.put(by_pid, pid, pid_state)}
    end
  end

  defp update_pid(state, pid, fun) do
    %{state | by_pid: Map.update!(state.by_pid, pid, fun)}
  end
end
