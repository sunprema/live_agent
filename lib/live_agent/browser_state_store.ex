defmodule LiveAgent.BrowserStateStore do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def init(_), do: {:ok, %{selected_element: nil, pinned_context: nil}}

  # Public API

  def put_selected_element(data),
    do: GenServer.call(__MODULE__, {:put_element, data})

  def get_selected_element,
    do: GenServer.call(__MODULE__, :get_element)

  def pin_context,
    do: GenServer.call(__MODULE__, :pin)

  def get_pinned_context,
    do: GenServer.call(__MODULE__, :get_pin)

  def clear_pinned_context,
    do: GenServer.call(__MODULE__, :clear_pin)

  # Callbacks

  def handle_call({:put_element, data}, _from, state),
    do: {:reply, :ok, %{state | selected_element: data}}

  def handle_call(:get_element, _from, state),
    do: {:reply, state.selected_element, state}

  def handle_call(:pin, _from, state),
    do: {:reply, :ok, %{state | pinned_context: state.selected_element}}

  def handle_call(:get_pin, _from, state),
    do: {:reply, state.pinned_context, state}

  def handle_call(:clear_pin, _from, state),
    do: {:reply, :ok, %{state | pinned_context: nil}}
end
