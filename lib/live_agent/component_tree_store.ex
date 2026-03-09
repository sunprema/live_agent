defmodule LiveAgent.ComponentTreeStore do
  @moduledoc false
  use GenServer

  # Keep trees for the last N view IDs (prevents unbounded growth across navigations).
  @max_trees 20

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Store a parsed component tree for the given view_id."
  def put(view_id, tree), do: GenServer.cast(__MODULE__, {:put, view_id, tree})

  @doc "Return the component tree for a specific view_id, or nil."
  def get(view_id), do: GenServer.call(__MODULE__, {:get, view_id})

  @doc "Return all stored trees as a map of view_id => tree."
  def all, do: GenServer.call(__MODULE__, :all)

  # ── GenServer ─────────────────────────────────────────────────────────────────

  # State: {map of view_id => tree, insertion-order list of view_ids}
  @impl true
  def init(_), do: {:ok, {%{}, []}}

  @impl true
  def handle_cast({:put, view_id, tree}, {trees, order}) do
    new_order = [view_id | List.delete(order, view_id)]
    {kept_order, evicted} = Enum.split(new_order, @max_trees)
    new_trees = trees |> Map.put(view_id, tree) |> Map.drop(evicted)
    {:noreply, {new_trees, kept_order}}
  end

  @impl true
  def handle_call({:get, view_id}, _from, {trees, _} = state) do
    {:reply, Map.get(trees, view_id), state}
  end

  def handle_call(:all, _from, {trees, _} = state) do
    {:reply, trees, state}
  end
end
