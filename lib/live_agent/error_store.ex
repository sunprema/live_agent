defmodule LiveAgent.ErrorStore do
  @moduledoc false
  use GenServer

  @max_errors 100
  @handler_id "live-agent-error-store"

  @telemetry_events [
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :live_view, :handle_params, :exception],
    [:phoenix, :live_component, :handle_event, :exception]
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def push_js_error(error), do: GenServer.cast(__MODULE__, {:push_js, error})

  def get_errors(since_id \\ 0), do: GenServer.call(__MODULE__, {:get_errors, since_id})

  def clear, do: GenServer.cast(__MODULE__, :clear)

  # ─── GenServer callbacks ───────────────────────────────────────────────────

  def init(_) do
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @telemetry_events,
      &__MODULE__.handle_telemetry/4,
      nil
    )

    {:ok, %{errors: [], next_id: 1}}
  end

  def terminate(_reason, _state), do: :telemetry.detach(@handler_id)

  def handle_call({:get_errors, since_id}, _from, state) do
    errors = Enum.filter(state.errors, &(&1.id > since_id))
    {:reply, errors, state}
  end

  def handle_cast(:clear, state) do
    {:noreply, %{state | errors: []}}
  end

  def handle_cast({:push_js, raw}, state) do
    error = %{
      id: state.next_id,
      source: "js",
      type: Map.get(raw, "type", "error"),
      message: Map.get(raw, "message", "Unknown error"),
      filename: Map.get(raw, "filename"),
      lineno: Map.get(raw, "lineno"),
      colno: Map.get(raw, "colno"),
      stack: Map.get(raw, "stack"),
      timestamp: Map.get(raw, "timestamp", DateTime.utc_now() |> DateTime.to_iso8601())
    }

    errors = [error | state.errors] |> Enum.take(@max_errors)
    {:noreply, %{state | errors: errors, next_id: state.next_id + 1}}
  end

  def handle_cast({:push_server, error}, state) do
    error = Map.put(error, :id, state.next_id)
    errors = [error | state.errors] |> Enum.take(@max_errors)
    {:noreply, %{state | errors: errors, next_id: state.next_id + 1}}
  end

  # ─── Telemetry handler ─────────────────────────────────────────────────────

  def handle_telemetry(event_name, _measurements, metadata, _config) do
    [_, scope, callback, _action] = event_name
    socket = Map.get(metadata, :socket)
    view = socket && socket.view |> inspect() |> String.replace_prefix("Elixir.", "")

    {kind, reason, stacktrace} =
      case metadata do
        %{kind: k, reason: r, stacktrace: st} -> {k, r, st}
        %{kind: k, reason: r} -> {k, r, []}
        _ -> {:error, :unknown, []}
      end

    error = %{
      source: "server",
      scope: to_string(scope),
      callback: to_string(callback),
      event: Map.get(metadata, :event),
      view: view,
      kind: to_string(kind),
      reason: Exception.format_banner(kind, reason) |> String.slice(0, 500),
      stacktrace: Exception.format_stacktrace(stacktrace) |> String.slice(0, 1000),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    GenServer.cast(__MODULE__, {:push_server, error})
  end
end
