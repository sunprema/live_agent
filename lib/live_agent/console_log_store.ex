defmodule LiveAgent.ConsoleLogStore do
  @moduledoc false
  # Ring buffer of `console.{log,info,warn,error,debug}` calls captured from the
  # host page. Mirrors LiveAgent.ErrorStore: monotonic ids, fixed-size history,
  # `since_id` for incremental pulls.
  #
  # Browser logs are intentionally a separate stream from JS errors and from the
  # Elixir Logger — they are noisy by nature and shouldn't drown out either.

  use GenServer

  @max_entries 500
  @levels ~w(log info warn error debug)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Push a batch of log entries posted by the panel. Each entry should carry
  "level", "message", "url", and "timestamp"; missing fields are filled with
  sensible defaults.
  """
  def push_batch(entries) when is_list(entries) do
    GenServer.cast(__MODULE__, {:push_batch, entries})
  end

  @doc """
  Returns entries with id > `since_id`, optionally filtered to one or more
  levels (e.g. `["warn", "error"]`).
  """
  def get_logs(opts \\ []) do
    since_id = Keyword.get(opts, :since_id, 0)
    levels = Keyword.get(opts, :levels, :all)
    limit = Keyword.get(opts, :limit, @max_entries)
    GenServer.call(__MODULE__, {:get_logs, since_id, levels, limit})
  end

  def clear, do: GenServer.cast(__MODULE__, :clear)

  # ── GenServer ─────────────────────────────────────────────────────────────

  def init(_), do: {:ok, %{entries: [], next_id: 1}}

  def handle_cast({:push_batch, raw_entries}, state) do
    {new_entries, next_id} =
      raw_entries
      |> Enum.reduce({[], state.next_id}, fn raw, {acc, id} ->
        entry = %{
          id: id,
          level: normalize_level(Map.get(raw, "level")),
          message: Map.get(raw, "message", "") |> to_string() |> String.slice(0, 4000),
          url: Map.get(raw, "url"),
          timestamp: Map.get(raw, "timestamp") || DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {[entry | acc], id + 1}
      end)

    # new_entries is newest-first within this batch; prepend to existing list
    # which is also newest-first overall.
    entries = (new_entries ++ state.entries) |> Enum.take(@max_entries)
    {:noreply, %{state | entries: entries, next_id: next_id}}
  end

  def handle_cast(:clear, state), do: {:noreply, %{state | entries: []}}

  def handle_call({:get_logs, since_id, levels, limit}, _from, state) do
    filtered =
      state.entries
      |> Enum.filter(fn e ->
        e.id > since_id and level_match?(e.level, levels)
      end)
      |> Enum.take(limit)

    {:reply, filtered, state}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp normalize_level(level) when level in @levels, do: level
  defp normalize_level(level) when is_binary(level), do: "log"
  defp normalize_level(_), do: "log"

  defp level_match?(_level, :all), do: true
  defp level_match?(level, levels) when is_list(levels), do: level in levels
  defp level_match?(level, single) when is_binary(single), do: level == single
end
