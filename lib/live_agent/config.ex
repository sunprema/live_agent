defmodule LiveAgent.Config do
  @moduledoc false
  # Bridges the host app's `plug LiveAgent, ...` options into a process-global
  # sink that the MCP tool layer can read. Plug config is per-conn, but MCP
  # tool listing has no conn — so on every request we sync the merged opts
  # into `:persistent_term`. Writes only happen when the value actually
  # changes, so the steady-state cost is one `:persistent_term.get/2`.

  @key {__MODULE__, :tools}

  def capture(%{} = config) do
    current = :persistent_term.get(@key, nil)
    new = Map.take(config, [:oban_tools, :pubsub_tools])
    if current != new, do: :persistent_term.put(@key, new)
    :ok
  end

  def oban_tools_enabled? do
    case :persistent_term.get(@key, %{}) |> Map.get(:oban_tools, false) do
      true -> true
      _ -> false
    end
  end

  @doc """
  Returns `{:ok, name}` if pubsub tools are enabled, or `:disabled`. The
  caller resolves `:auto` into a real pubsub name via PubSubInspector at
  query time (so we don't bake in a name that's racing with app startup).
  """
  def pubsub_tools do
    case :persistent_term.get(@key, %{}) |> Map.get(:pubsub_tools, false) do
      false -> :disabled
      nil -> :disabled
      true -> {:ok, :auto}
      name when is_atom(name) -> {:ok, name}
      _ -> :disabled
    end
  end

  def pubsub_tools_enabled? do
    pubsub_tools() != :disabled
  end
end
