defmodule LiveAgent.AsyncInspector do
  @moduledoc false
  # Records completed Phoenix.LiveView async tasks per LV pid.
  #
  # Phoenix LiveView 1.1.x does not emit telemetry for handle_async (verified
  # against deps/phoenix_live_view/lib/phoenix_live_view/async.ex). We instead
  # poll `socket.private[:live_async]` on a short interval and Process.monitor
  # each new task pid we discover. On `:DOWN` we push a history entry and try
  # to relabel the matching StateTimeline entry.

  use GenServer
  require Logger

  alias LiveAgent.AssignsDiff
  alias LiveAgent.AsyncRegistry
  alias LiveAgent.SocketInspector
  alias LiveAgent.StateTimeline

  @poll_interval_ms 250
  @activity_window_ms 30_000
  @max_history 25
  @grace_ms 60_000
  @max_entry_bytes 8_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Returns the recorded history for an LV pid (or pid string), newest first."
  def history(pid_or_string, last_n \\ 10)

  def history(pid, last_n) when is_pid(pid) and is_integer(last_n),
    do: GenServer.call(__MODULE__, {:history, pid, last_n})

  def history(str, last_n) when is_binary(str) and is_integer(last_n) do
    case SocketInspector.parse_pid(str) do
      {:ok, pid} -> history(pid, last_n)
      err -> err
    end
  end

  @doc "Returns a single history entry by id, or nil."
  def entry(pid, entry_id) when is_pid(pid) and is_integer(entry_id),
    do: GenServer.call(__MODULE__, {:entry, pid, entry_id})

  def entry(str, entry_id) when is_binary(str) and is_integer(entry_id) do
    case SocketInspector.parse_pid(str) do
      {:ok, pid} -> entry(pid, entry_id)
      err -> err
    end
  end

  @doc """
  Returns the inspector's view of currently-pending tasks (with `started_at`
  and `elapsed_ms`). Note: only includes tasks the poll loop has observed —
  tasks launched within the last 250ms may not appear yet. For the
  immediate-truth view, see `LiveAgent.AsyncRegistry.list_pending/1`.
  """
  def pending(pid) when is_pid(pid), do: GenServer.call(__MODULE__, {:pending, pid})

  def pending(str) when is_binary(str) do
    case SocketInspector.parse_pid(str) do
      {:ok, pid} -> pending(pid)
      err -> err
    end
  end

  @doc "Bumps the activity timestamp so the poll loop keeps running."
  def bump_activity, do: GenServer.cast(__MODULE__, :bump_activity)

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    Process.send_after(self(), :poll, @poll_interval_ms)

    {:ok,
     %{
       by_lv: %{},
       refs: %{},
       last_activity_at: now_ms()
     }}
  end

  @impl true
  def handle_call({:history, pid, last_n}, _from, state) do
    entries =
      case Map.get(state.by_lv, pid) do
        %{history: list} -> Enum.take(list, last_n)
        _ -> []
      end

    {:reply, entries, bump(state)}
  end

  def handle_call({:entry, pid, entry_id}, _from, state) do
    found =
      with %{history: list} <- Map.get(state.by_lv, pid),
           %{} = entry <- Enum.find(list, fn e -> e.id == entry_id end) do
        entry
      else
        _ -> nil
      end

    {:reply, found, bump(state)}
  end

  def handle_call({:pending, pid}, _from, state) do
    pending =
      case Map.get(state.by_lv, pid) do
        %{tasks: tasks} ->
          now = System.monotonic_time(:microsecond)

          Enum.map(tasks, fn {name, t} ->
            %{
              name: name_to_string(name),
              kind: t.kind,
              task_pid: pid_to_string(t.task_pid),
              started_at: DateTime.to_iso8601(t.started_at),
              elapsed_ms: div(now - t.started_mono_us, 1000)
            }
          end)

        _ ->
          []
      end

    {:reply, pending, bump(state)}
  end

  @impl true
  def handle_cast(:bump_activity, state), do: {:noreply, bump(state)}

  @impl true
  def handle_info(:poll, state) do
    state =
      if now_ms() - state.last_activity_at <= @activity_window_ms do
        do_poll(state)
      else
        state
      end

    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.refs, ref) do
      {:lv, lv_pid} ->
        Process.send_after(self(), {:cleanup_lv, lv_pid}, @grace_ms)
        {:noreply, state}

      {:task, lv_pid, name} ->
        {:noreply, record_completion(state, lv_pid, name, ref, reason)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:cleanup_lv, lv_pid}, state) do
    state =
      case Map.pop(state.by_lv, lv_pid) do
        {nil, _} ->
          state

        {lv_state, rest} ->
          # Drop refs for any still-tracked tasks of this LV.
          task_refs =
            lv_state.tasks
            |> Map.values()
            |> Enum.map(& &1.monitor_ref)
            |> MapSet.new()

          refs =
            state.refs
            |> Map.delete(lv_state.lv_monitor_ref)
            |> Map.reject(fn {ref, _} -> MapSet.member?(task_refs, ref) end)

          %{state | by_lv: rest, refs: refs}
      end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ── poll cycle ──────────────────────────────────────────────────────────────

  defp do_poll(state) do
    lv_pids =
      SocketInspector.list_live_views()
      |> Enum.flat_map(fn lv ->
        case SocketInspector.parse_pid(lv.pid_string) do
          {:ok, pid} -> [pid]
          _ -> []
        end
      end)

    Enum.reduce(lv_pids, state, &poll_lv/2)
  end

  defp poll_lv(lv_pid, state) do
    case AsyncRegistry.raw_registry(lv_pid) do
      {:ok, registry} when is_map(registry) ->
        state = ensure_lv_state(state, lv_pid)
        reconcile_lv(state, lv_pid, registry)

      _ ->
        state
    end
  rescue
    e ->
      Logger.error("[LiveAgent.AsyncInspector] poll crashed for #{inspect(lv_pid)}: #{Exception.message(e)}")
      state
  end

  defp reconcile_lv(state, lv_pid, registry) do
    lv_state = Map.fetch!(state.by_lv, lv_pid)
    known_names = MapSet.new(Map.keys(lv_state.tasks))
    seen_names = MapSet.new(Map.keys(registry))
    new_names = MapSet.difference(seen_names, known_names)

    Enum.reduce(new_names, state, fn name, acc ->
      case Map.get(registry, name) do
        {_ref, task_pid, kind} when is_pid(task_pid) ->
          add_new_task(acc, lv_pid, name, task_pid, kind)

        _ ->
          acc
      end
    end)
  end

  defp add_new_task(state, lv_pid, name, task_pid, kind) do
    monitor_ref = Process.monitor(task_pid)

    task_entry = %{
      task_pid: task_pid,
      kind: kind_to_string(kind),
      started_at: DateTime.utc_now(),
      started_mono_us: System.monotonic_time(:microsecond),
      monitor_ref: monitor_ref
    }

    new_lv_state =
      update_in(state.by_lv[lv_pid].tasks, fn tasks -> Map.put(tasks, name, task_entry) end)

    new_refs = Map.put(state.refs, monitor_ref, {:task, lv_pid, name})

    %{state | by_lv: new_lv_state.by_lv, refs: new_refs}
  end

  defp ensure_lv_state(%{by_lv: by_lv} = state, lv_pid) do
    if Map.has_key?(by_lv, lv_pid) do
      state
    else
      lv_monitor_ref = Process.monitor(lv_pid)

      lv_state = %{
        tasks: %{},
        history: [],
        next_id: 1,
        lv_monitor_ref: lv_monitor_ref
      }

      %{
        state
        | by_lv: Map.put(by_lv, lv_pid, lv_state),
          refs: Map.put(state.refs, lv_monitor_ref, {:lv, lv_pid})
      }
    end
  end

  # ── completion ──────────────────────────────────────────────────────────────

  defp record_completion(state, lv_pid, name, ref, reason) do
    case get_in(state.by_lv, [lv_pid, :tasks, name]) do
      nil ->
        # Task was already cleaned up (LV died).
        %{state | refs: Map.delete(state.refs, ref)}

      task_entry ->
        duration_us = System.monotonic_time(:microsecond) - task_entry.started_mono_us
        result = if reason == :normal, do: :ok, else: :exit
        exit_reason = if result == :exit, do: format_reason(reason), else: nil

        async_result = read_async_result(lv_pid, name, task_entry.kind)
        state_timeline_id = relabel_state_timeline(lv_pid, name)

        lv_state = Map.fetch!(state.by_lv, lv_pid)

        entry =
          %{
            id: lv_state.next_id,
            at: DateTime.utc_now(),
            name: name_to_string(name),
            kind: task_entry.kind,
            duration_us: duration_us,
            result: result,
            exit_reason: exit_reason,
            async_result: bound_async_result(async_result),
            state_timeline_id: state_timeline_id
          }
          |> bound_entry_size()

        new_history = [entry | lv_state.history] |> Enum.take(@max_history)
        new_tasks = Map.delete(lv_state.tasks, name)

        new_lv_state = %{
          lv_state
          | history: new_history,
            tasks: new_tasks,
            next_id: lv_state.next_id + 1
        }

        %{
          state
          | by_lv: Map.put(state.by_lv, lv_pid, new_lv_state),
            refs: Map.delete(state.refs, ref)
        }
    end
  end

  defp read_async_result(lv_pid, name, "assign") do
    try do
      case SocketInspector.get_assigns(lv_pid) do
        {:ok, assigns} ->
          case Map.get(assigns, to_string(name)) do
            %{"__async_result__" => true} = ar -> ar
            _ -> nil
          end

        _ ->
          nil
      end
    catch
      _, _ -> nil
    end
  end

  defp read_async_result(_lv_pid, _name, _kind), do: nil

  defp relabel_state_timeline(lv_pid, name) do
    case StateTimeline.relabel_unknown_to_async(lv_pid, name) do
      {:ok, entry_id} -> entry_id
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp bump(state), do: %{state | last_activity_at: now_ms()}

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp name_to_string(n) when is_atom(n), do: Atom.to_string(n)
  defp name_to_string(n), do: inspect(n)

  defp kind_to_string(:start), do: "start"
  defp kind_to_string(:assign), do: "assign"
  defp kind_to_string(:stream), do: "stream"
  defp kind_to_string(other) when is_atom(other), do: Atom.to_string(other)
  defp kind_to_string(other), do: inspect(other)

  defp format_reason(reason) do
    reason |> inspect() |> String.slice(0, 500)
  end

  defp pid_to_string(pid) when is_pid(pid),
    do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp pid_to_string(_), do: nil

  defp bound_async_result(nil), do: nil

  defp bound_async_result(ar) when is_map(ar) do
    Map.new(ar, fn {k, v} -> {k, AssignsDiff.truncate_value(v)} end)
  end

  defp bound_entry_size(entry) do
    case Jason.encode(entry) do
      {:ok, json} when byte_size(json) <= @max_entry_bytes ->
        entry

      {:ok, json} ->
        %{
          entry
          | async_result: %{
              oversize: true,
              byte_size: byte_size(json)
            }
        }

      _ ->
        # Couldn't even encode — keep the entry but null out the value.
        %{entry | async_result: %{oversize: true, byte_size: nil}}
    end
  end
end
