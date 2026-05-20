defmodule LiveAgent.AssignsDiff do
  @moduledoc false

  @max_binary_size 256
  @max_collection_size 50

  @type diff :: %{changed: map(), added: map(), removed: map()}

  @spec diff(map(), map()) :: diff()
  def diff(before, after_) when is_map(before) and is_map(after_) do
    all_keys = MapSet.union(MapSet.new(Map.keys(before)), MapSet.new(Map.keys(after_)))

    Enum.reduce(all_keys, %{changed: %{}, added: %{}, removed: %{}}, fn key, acc ->
      cond do
        not Map.has_key?(before, key) ->
          %{acc | added: Map.put(acc.added, key, truncate(Map.get(after_, key)))}

        not Map.has_key?(after_, key) ->
          %{acc | removed: Map.put(acc.removed, key, truncate(Map.get(before, key)))}

        Map.get(before, key) != Map.get(after_, key) ->
          old = truncate(Map.get(before, key))
          new = truncate(Map.get(after_, key))
          %{acc | changed: Map.put(acc.changed, key, %{before: old, after: new})}

        true ->
          acc
      end
    end)
  end

  @spec empty?(diff()) :: boolean()
  def empty?(%{changed: c, added: a, removed: r}) do
    map_size(c) == 0 and map_size(a) == 0 and map_size(r) == 0
  end

  @doc """
  Estimates serialized byte size of the diff and, if it exceeds `max_bytes`,
  replaces it with an oversize summary preserving the changed/added/removed
  key names so Claude knows where to look.
  """
  @spec bound_size(diff(), pos_integer()) :: diff() | %{oversize: true, summary: map()}
  def bound_size(diff, max_bytes \\ 16_000) do
    case safe_encode_size(diff) do
      {:ok, size} when size <= max_bytes ->
        diff

      _ ->
        %{
          oversize: true,
          summary: %{
            changed: Map.keys(diff.changed),
            added: Map.keys(diff.added),
            removed: Map.keys(diff.removed)
          }
        }
    end
  end

  defp safe_encode_size(value) do
    {:ok, value |> Jason.encode!() |> byte_size()}
  rescue
    _ -> :error
  end

  @doc """
  Shared truncation primitive for diff values and async-result payloads.
  Binaries over 256B become `%{truncated: true, byte_size:, preview:}`;
  lists/maps over 50 elements become `%{summary: true, count:, kind:}`.
  """
  def truncate_value(v) when is_binary(v) and byte_size(v) > @max_binary_size do
    %{truncated: true, byte_size: byte_size(v), preview: binary_part(v, 0, @max_binary_size)}
  end

  def truncate_value(v) when is_list(v) do
    case length_at_most(v, @max_collection_size) do
      {:ok, _} -> v
      :too_long -> %{summary: true, count: Enum.count(v), kind: "list"}
    end
  end

  def truncate_value(v) when is_map(v) and not is_struct(v) do
    if map_size(v) > @max_collection_size do
      %{summary: true, count: map_size(v), kind: "map"}
    else
      v
    end
  end

  def truncate_value(v), do: v

  defp truncate(v), do: truncate_value(v)

  defp length_at_most(list, max) do
    case Enum.split(list, max + 1) do
      {_taken, []} -> {:ok, length(list)}
      {_, _rest} -> :too_long
    end
  end
end
