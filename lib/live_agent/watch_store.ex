defmodule LiveAgent.WatchStore do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_), do: {:ok, %{}}

  def get_snapshot(key), do: GenServer.call(__MODULE__, {:get, key})
  def put_snapshot(key, snapshot), do: GenServer.call(__MODULE__, {:put, key, snapshot})
  def clear(key), do: GenServer.call(__MODULE__, {:clear, key})

  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}
  def handle_call({:put, key, snapshot}, _from, state), do: {:reply, :ok, Map.put(state, key, snapshot)}
  def handle_call({:clear, key}, _from, state), do: {:reply, :ok, Map.delete(state, key)}
end
