defmodule LiveAgent.CommandQueue do
  @moduledoc false
  # Bridges MCP tool callers (which want to dispatch a browser command and
  # block until they see the result) with the panel JS (which long-polls
  # for commands and POSTs results back).
  #
  # Two parking pools, both held inside the GenServer:
  #
  #   - mcp_waiters: id => from         (MCP tool call awaiting its result)
  #   - browser_waiters: [from]          (panel long-polls awaiting work)
  #
  # When the MCP side enqueues a command, if a panel is parked we hand the
  # command straight to it; otherwise the command waits in `pending`.

  use GenServer

  @poll_timeout_ms 25_000

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Enqueue a command for the browser and block until the panel posts the result
  (or until `timeout_ms` elapses, in which case `{:error, :timeout}`).
  """
  def enqueue_and_await(op, args, timeout_ms \\ 15_000) when is_binary(op) and is_map(args) do
    GenServer.call(
      __MODULE__,
      {:enqueue, op, args, timeout_ms},
      timeout_ms + 2_000
    )
  end

  @doc """
  Long-poll for pending commands. Returns immediately with all pending if any,
  otherwise parks for up to `timeout_ms`, then returns `[]`.
  """
  def poll(timeout_ms \\ @poll_timeout_ms) do
    GenServer.call(__MODULE__, {:poll, timeout_ms}, timeout_ms + 2_000)
  end

  @doc """
  Deliver the result for a command id back to its parked MCP caller.
  Returns `:ok` if a caller was waiting, `{:error, :not_found}` otherwise.
  """
  def post_result(id, result) when is_integer(id) do
    GenServer.call(__MODULE__, {:result, id, result})
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok,
     %{
       next_id: 1,
       pending: [],
       mcp_waiters: %{},
       browser_waiters: []
     }}
  end

  @impl true
  def handle_call({:enqueue, op, args, timeout_ms}, from, state) do
    id = state.next_id
    cmd = %{id: id, op: op, args: args}

    state = %{state | next_id: id + 1, mcp_waiters: Map.put(state.mcp_waiters, id, from)}

    Process.send_after(self(), {:mcp_timeout, id}, timeout_ms)

    state =
      case state.browser_waiters do
        [{waiter_from, _ref} | rest] ->
          GenServer.reply(waiter_from, [cmd])
          %{state | browser_waiters: rest}

        [] ->
          %{state | pending: state.pending ++ [cmd]}
      end

    {:noreply, state}
  end

  def handle_call({:poll, timeout_ms}, from, state) do
    case state.pending do
      [] ->
        ref = make_ref()
        Process.send_after(self(), {:poll_timeout, from, ref}, timeout_ms)
        {:noreply, %{state | browser_waiters: state.browser_waiters ++ [{from, ref}]}}

      pending ->
        {:reply, pending, %{state | pending: []}}
    end
  end

  def handle_call({:result, id, result}, _from, state) do
    case Map.pop(state.mcp_waiters, id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {mcp_from, rest} ->
        GenServer.reply(mcp_from, {:ok, result})
        {:reply, :ok, %{state | mcp_waiters: rest}}
    end
  end

  @impl true
  def handle_info({:mcp_timeout, id}, state) do
    case Map.pop(state.mcp_waiters, id) do
      {nil, _} ->
        {:noreply, state}

      {mcp_from, rest} ->
        GenServer.reply(mcp_from, {:error, :timeout})
        pending = Enum.reject(state.pending, &(&1.id == id))
        {:noreply, %{state | mcp_waiters: rest, pending: pending}}
    end
  end

  def handle_info({:poll_timeout, from, ref}, state) do
    case Enum.split_with(state.browser_waiters, fn {f, r} -> f == from and r == ref end) do
      {[_match], rest} ->
        GenServer.reply(from, [])
        {:noreply, %{state | browser_waiters: rest}}

      _ ->
        {:noreply, state}
    end
  end

end
