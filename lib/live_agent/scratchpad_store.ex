defmodule LiveAgent.ScratchpadStore do
  @moduledoc false
  use GenServer

  @max_snapshots 50

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{snapshots: %{}}, name: __MODULE__)

  def init(state), do: {:ok, state}

  def save(name, pid_string, note \\ nil),
    do: GenServer.call(__MODULE__, {:save, name, pid_string, note})

  def list_snapshots, do: GenServer.call(__MODULE__, :list_snapshots)

  def get(name), do: GenServer.call(__MODULE__, {:get, name})

  def delete(name), do: GenServer.call(__MODULE__, {:delete, name})

  def clear_all, do: GenServer.call(__MODULE__, :clear_all)

  def handle_call({:save, name, pid_string, note}, _from, state) do
    case LiveAgent.SocketInspector.get_assigns(pid_string) do
      {:ok, assigns} ->
        {view, url} = resolve_view_metadata(pid_string)

        snapshot = %{
          name: name,
          view: view,
          url: url,
          pid_string: pid_string,
          assigns: assigns,
          note: note,
          saved_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        new_snapshots =
          state.snapshots
          |> Map.put(name, snapshot)
          |> maybe_trim()

        {:reply, :ok, %{state | snapshots: new_snapshots}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_snapshots, _from, state) do
    summaries =
      state.snapshots
      |> Map.values()
      |> Enum.sort_by(& &1.saved_at, :desc)
      |> Enum.map(fn s ->
        s
        |> Map.delete(:assigns)
        |> Map.put(:assign_keys, s.assigns |> Map.keys() |> Enum.sort())
      end)

    {:reply, summaries, state}
  end

  def handle_call({:get, name}, _from, state) do
    case Map.fetch(state.snapshots, name) do
      {:ok, snapshot} -> {:reply, {:ok, snapshot}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, name}, _from, state) do
    {:reply, :ok, %{state | snapshots: Map.delete(state.snapshots, name)}}
  end

  def handle_call(:clear_all, _from, state) do
    {:reply, :ok, %{state | snapshots: %{}}}
  end

  defp resolve_view_metadata(pid_string) do
    LiveAgent.SocketInspector.list_live_views()
    |> Enum.find(fn lv -> lv.pid_string == pid_string end)
    |> case do
      nil -> {"(unknown)", nil}
      lv -> {lv.view, lv.url}
    end
  end

  defp maybe_trim(snapshots) when map_size(snapshots) > @max_snapshots do
    snapshots
    |> Map.values()
    |> Enum.sort_by(& &1.saved_at, :asc)
    |> Enum.take(map_size(snapshots) - @max_snapshots)
    |> Enum.reduce(snapshots, fn s, acc -> Map.delete(acc, s.name) end)
  end

  defp maybe_trim(snapshots), do: snapshots
end
