defmodule LiveAgent.BrowserStateStore do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_), do: {:ok, %{selected_element: nil, pinned_contexts: []}}

  # Public API

  def put_selected_element(data),
    do: GenServer.call(__MODULE__, {:put_element, data})

  def get_selected_element,
    do: GenServer.call(__MODULE__, :get_element)

  def pin_context,
    do: GenServer.call(__MODULE__, :pin)

  def get_pinned_contexts,
    do: GenServer.call(__MODULE__, :get_pins)

  def set_pin_note(index, note),
    do: GenServer.call(__MODULE__, {:set_pin_note, index, note})

  def clear_pinned_context(index),
    do: GenServer.call(__MODULE__, {:clear_pin, index})

  def clear_all_pinned_contexts,
    do: GenServer.call(__MODULE__, :clear_all_pins)

  # Callbacks

  def handle_call({:put_element, data}, _from, state),
    do: {:reply, :ok, %{state | selected_element: data}}

  def handle_call(:get_element, _from, state),
    do: {:reply, state.selected_element, state}

  def handle_call(:pin, _from, %{selected_element: nil} = state),
    do: {:reply, {:error, :no_element}, state}

  def handle_call(:pin, _from, state) do
    next_index = length(state.pinned_contexts) + 1
    entry = Map.put(state.selected_element, :pin_index, next_index)
    new_contexts = state.pinned_contexts ++ [entry]
    {:reply, {:ok, next_index}, %{state | pinned_contexts: new_contexts}}
  end

  def handle_call(:get_pins, _from, state),
    do: {:reply, state.pinned_contexts, state}

  def handle_call({:set_pin_note, index, note}, _from, state) do
    new_contexts =
      Enum.map(state.pinned_contexts, fn entry ->
        cond do
          entry.pin_index != index -> entry
          note in [nil, ""] -> Map.delete(entry, :note)
          true -> Map.put(entry, :note, note)
        end
      end)

    {:reply, :ok, %{state | pinned_contexts: new_contexts}}
  end

  def handle_call({:clear_pin, index}, _from, state) do
    new_contexts =
      state.pinned_contexts
      |> Enum.reject(&(&1.pin_index == index))
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, i} -> %{entry | pin_index: i} end)

    {:reply, :ok, %{state | pinned_contexts: new_contexts}}
  end

  def handle_call(:clear_all_pins, _from, state),
    do: {:reply, :ok, %{state | pinned_contexts: []}}
end
