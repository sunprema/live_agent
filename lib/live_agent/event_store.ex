defmodule LiveAgent.EventStore do
  @moduledoc false
  use GenServer

  @max_events 200
  @handler_id "live-agent-telemetry"

  @telemetry_events [
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_params, :exception],
    [:phoenix, :live_view, :handle_info, :stop],
    [:phoenix, :live_component, :handle_event, :stop],
    [:phoenix, :live_component, :handle_event, :exception]
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def get_events(since_id \\ 0), do: GenServer.call(__MODULE__, {:get_events, since_id})

  def clear, do: GenServer.cast(__MODULE__, :clear)

  # ─── GenServer callbacks ───────────────────────────────────────────────────

  def init(_) do
    # Detach first in case of hot reload / restart
    :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      @telemetry_events,
      &__MODULE__.handle_telemetry/4,
      nil
    )

    {:ok, %{events: [], next_id: 1}}
  end

  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
  end

  def handle_call({:get_events, since_id}, _from, state) do
    events = Enum.filter(state.events, &(&1.id > since_id))
    {:reply, events, state}
  end

  def handle_cast(:clear, state) do
    {:noreply, %{state | events: []}}
  end

  def handle_cast({:push, event}, state) do
    event = Map.put(event, :id, state.next_id)
    events = [event | state.events] |> Enum.take(@max_events)
    {:noreply, %{state | events: events, next_id: state.next_id + 1}}
  end

  # ─── Telemetry handler ─────────────────────────────────────────────────────

  def handle_telemetry(event_name, measurements, metadata, _config) do
    [_, scope, type, action] = event_name

    duration_ms =
      case measurements do
        %{duration: d} -> d |> System.convert_time_unit(:native, :microsecond) |> div(1000)
        _ -> nil
      end

    socket = Map.get(metadata, :socket)
    view = socket && socket.view |> inspect() |> String.replace_prefix("Elixir.", "")

    event = %{
      scope: to_string(scope),
      type: to_string(type),
      action: to_string(action),
      event: Map.get(metadata, :event),
      view: view,
      component: format_component(metadata),
      duration_ms: duration_ms,
      params: safe_params(Map.get(metadata, :params)),
      uri: Map.get(metadata, :uri),
      error: format_error(metadata),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    GenServer.cast(__MODULE__, {:push, event})
  end

  # ─── Helpers ───────────────────────────────────────────────────────────────

  defp format_component(%{component: c}) when is_atom(c),
    do: c |> inspect() |> String.replace_prefix("Elixir.", "")

  defp format_component(_), do: nil

  defp safe_params(nil), do: nil

  defp safe_params(params) when is_map(params) do
    Map.new(params, fn {k, v} -> {to_string(k), safe_value(v)} end)
  rescue
    _ -> nil
  end

  defp safe_params(_), do: nil

  defp safe_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp safe_value(v) when is_atom(v), do: Atom.to_string(v)
  defp safe_value(v) when is_map(v), do: safe_params(v)
  defp safe_value(v) when is_list(v), do: Enum.map(v, &safe_value/1)
  defp safe_value(v), do: inspect(v) |> String.slice(0, 100)

  defp format_error(%{kind: kind, reason: reason}),
    do: "#{kind}: #{inspect(reason)}" |> String.slice(0, 300)

  defp format_error(_), do: nil
end
