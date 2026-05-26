defmodule LiveAgent.KeyPath do
  @moduledoc false
  # Resolves a dot-path like "alert.level" into a nested map/struct, returning
  # `{:ok, value}` or `:not_found`. Each segment matches a string key first,
  # then an existing-atom key — so it works on both the sanitized assigns
  # (string keys) read by `expect_assign`/`get_assigns` and raw atom-keyed
  # maps. The single shared path resolver for the assertion + key-path tools.

  @doc """
  Fetches the value at `path` (a dot-string or a list of segments) within
  `data`. Returns `{:ok, value}` or `:not_found`.
  """
  def get(data, path) when is_binary(path) do
    get(data, String.split(path, "."))
  end

  def get(value, []), do: {:ok, value}

  def get(data, [segment | rest]) when is_map(data) do
    case fetch(data, segment) do
      {:ok, value} -> get(value, rest)
      :error -> :not_found
    end
  end

  def get(_data, _segments), do: :not_found

  defp fetch(map, segment) do
    cond do
      Map.has_key?(map, segment) ->
        {:ok, Map.get(map, segment)}

      true ->
        case existing_atom(segment) do
          {:ok, atom} ->
            if Map.has_key?(map, atom), do: {:ok, Map.get(map, atom)}, else: :error

          :error ->
            :error
        end
    end
  end

  defp existing_atom(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end
end
