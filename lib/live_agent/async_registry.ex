defmodule LiveAgent.AsyncRegistry do
  @moduledoc false
  # Read-only inspection of in-flight async tasks on a LiveView pid.
  # Reads `socket.private[:live_async]` (per Phoenix.LiveView 1.1.26;
  # async.ex:423-430, :279) and scans assigns for %AsyncResult{} values.

  alias LiveAgent.SocketInspector

  @doc """
  Returns the list of in-flight async tasks for a LiveView pid (or pid string).
  Each entry: %{name, kind, task_pid, elapsed_ms (nil if not previously seen),
                started_at (nil if not previously seen)}.
  """
  def list_pending(pid) when is_pid(pid) do
    with {:ok, socket} <- SocketInspector.get_socket(pid) do
      live_async = socket.private |> Map.get(:live_async, %{})
      {:ok, Enum.map(live_async, &format_pending/1)}
    end
  end

  def list_pending(pid_string) when is_binary(pid_string) do
    with {:ok, pid} <- SocketInspector.parse_pid(pid_string) do
      list_pending(pid)
    end
  end

  @doc """
  Returns the list of `%AsyncResult{}` values currently in assigns for the
  given LiveView pid (or pid string).
  Each entry: %{assign_key, ok?, loading, failed, result_preview}.
  """
  def list_async_results(pid) when is_pid(pid) do
    with {:ok, socket} <- SocketInspector.get_socket(pid) do
      results =
        socket.assigns
        |> Enum.flat_map(fn {k, v} -> format_async_result(k, v) end)

      {:ok, results}
    end
  end

  def list_async_results(pid_string) when is_binary(pid_string) do
    with {:ok, pid} <- SocketInspector.parse_pid(pid_string) do
      list_async_results(pid)
    end
  end

  @doc """
  Returns the raw `socket.private[:live_async]` map for a LV pid (or `{:error, _}`).
  Used by `AsyncInspector` so it doesn't re-do the `:sys.get_state` round-trip.
  """
  def raw_registry(pid) when is_pid(pid) do
    case SocketInspector.get_socket(pid) do
      {:ok, socket} ->
        {:ok, Map.get(socket.private || %{}, :live_async, %{})}

      err ->
        err
    end
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp format_pending({name, {_ref, task_pid, kind}}) do
    %{
      name: name_to_string(name),
      kind: kind_to_string(kind),
      task_pid: pid_to_string(task_pid)
    }
  end

  defp format_pending({name, other}) do
    # Unknown shape — surface enough to debug the version mismatch.
    %{
      name: name_to_string(name),
      kind: "unknown",
      task_pid: nil,
      raw: inspect(other) |> String.slice(0, 120)
    }
  end

  defp format_async_result(key, value) when is_struct(value) do
    if is_struct(value, Phoenix.LiveView.AsyncResult) do
      [
        %{
          assign_key: name_to_string(key),
          ok?: Map.get(value, :ok?, false),
          loading: Map.get(value, :loading) |> safe_preview(),
          failed: Map.get(value, :failed) |> safe_preview(),
          result_preview: Map.get(value, :result) |> safe_preview()
        }
      ]
    else
      []
    end
  end

  defp format_async_result(_, _), do: []

  defp safe_preview(nil), do: nil
  defp safe_preview(v) when is_boolean(v) or is_number(v), do: v
  defp safe_preview(v) when is_atom(v), do: Atom.to_string(v)

  defp safe_preview(v) when is_binary(v) do
    if byte_size(v) > 256, do: %{truncated: true, byte_size: byte_size(v)}, else: v
  end

  defp safe_preview(v), do: v |> inspect() |> String.slice(0, 256)

  defp name_to_string(name) when is_atom(name), do: Atom.to_string(name)
  defp name_to_string(name), do: inspect(name)

  defp kind_to_string(:start), do: "start"
  defp kind_to_string(:assign), do: "assign"
  defp kind_to_string(:stream), do: "stream"
  defp kind_to_string(other) when is_atom(other), do: Atom.to_string(other)
  defp kind_to_string(other), do: inspect(other)

  defp pid_to_string(pid) when is_pid(pid),
    do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp pid_to_string(_), do: nil
end
