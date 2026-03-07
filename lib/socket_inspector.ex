defmodule LiveAgent.SocketInspector do
  @moduledoc false

  @doc """
  Returns metadata for all currently running LiveView processes.
  """
  def list_live_views do
    find_liveview_pids()
    |> Enum.map(&pid_to_metadata/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Returns sanitized assigns map for a LiveView PID (pid or pid string).
  """
  def get_assigns(pid) when is_pid(pid) do
    with {:ok, socket} <- get_socket(pid) do
      {:ok, extract_assigns(socket)}
    end
  end

  def get_assigns(pid_string) when is_binary(pid_string) do
    with {:ok, pid} <- parse_pid(pid_string) do
      get_assigns(pid)
    end
  end

  @doc """
  Returns full socket metadata for a LiveView PID (pid or pid string).
  """
  def get_socket_info(pid) when is_pid(pid) do
    with {:ok, socket} <- get_socket(pid) do
      {:ok, socket_to_map(socket)}
    end
  end

  def get_socket_info(pid_string) when is_binary(pid_string) do
    with {:ok, pid} <- parse_pid(pid_string) do
      get_socket_info(pid)
    end
  end

  # --- Private ---

  defp find_liveview_pids do
    Process.list()
    |> Enum.filter(&liveview_process?/1)
  end

  defp liveview_process?(pid) do
    case Process.info(pid, [:dictionary, :status]) do
      [{:dictionary, dict}, {:status, status}] when status != :exiting ->
        case Keyword.get(dict, :"$initial_call") do
          {Phoenix.LiveView.Channel, :init, _} ->
            true

          {module, :mount, 3} when is_atom(module) ->
            function_exported?(module, :__live__, 0)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp pid_to_metadata(pid) do
    case get_socket(pid) do
      {:ok, socket} ->
        %{
          pid_string: pid_to_string(pid),
          view: inspect(socket.view),
          id: socket.id,
          url: socket_url(socket),
          connected: socket.transport_pid != nil,
          assign_keys:
            socket.assigns
            |> Map.keys()
            |> Enum.reject(&internal_key?/1)
            |> Enum.map(&to_string/1)
        }

      _ ->
        nil
    end
  end

  defp get_socket(pid) do
    try do
      case :sys.get_state(pid, 2000) do
        %{socket: %Phoenix.LiveView.Socket{} = socket} ->
          {:ok, socket}

        state when is_map(state) ->
          Enum.find_value(state, {:error, :socket_not_found}, fn
            {_k, %Phoenix.LiveView.Socket{} = socket} -> {:ok, socket}
            _ -> nil
          end)

        _ ->
          {:error, :not_a_liveview}
      end
    catch
      :exit, _ -> {:error, :process_not_available}
    end
  end

  defp extract_assigns(%Phoenix.LiveView.Socket{assigns: assigns}) do
    assigns
    |> Map.reject(fn {k, _v} -> internal_key?(k) end)
    |> sanitize_map()
  end

  defp socket_to_map(%Phoenix.LiveView.Socket{} = socket) do
    %{
      id: socket.id,
      view: inspect(socket.view),
      parent_pid: pid_to_string(socket.parent_pid),
      root_pid: pid_to_string(socket.root_pid),
      transport_pid: pid_to_string(socket.transport_pid),
      connected: socket.transport_pid != nil,
      url: socket_url(socket),
      assigns: extract_assigns(socket)
    }
  end

  defp socket_url(socket) do
    case Map.get(socket, :host_uri) do
      %URI{} = uri -> URI.to_string(uri)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp internal_key?(k) when is_atom(k) do
    k |> Atom.to_string() |> String.starts_with?("__")
  end

  defp internal_key?(_), do: false

  defp sanitize_map(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: inspect(k)
      {key, sanitize(v)}
    end)
  end

  defp sanitize(v) when is_binary(v), do: v
  defp sanitize(v) when is_number(v), do: v
  defp sanitize(v) when is_boolean(v), do: v
  defp sanitize(nil), do: nil
  defp sanitize(v) when is_atom(v), do: Atom.to_string(v)
  defp sanitize(v) when is_pid(v), do: pid_to_string(v)
  defp sanitize(v) when is_list(v), do: Enum.map(v, &sanitize/1)

  defp sanitize(v) when is_map(v) do
    if Map.has_key?(v, :__struct__) do
      try do
        v |> Map.from_struct() |> sanitize_map()
      rescue
        _ -> inspect(v)
      end
    else
      sanitize_map(v)
    end
  end

  defp sanitize(v), do: inspect(v)

  defp pid_to_string(nil), do: nil
  defp pid_to_string(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  defp parse_pid(str) do
    pid = str |> String.to_charlist() |> :erlang.list_to_pid()
    {:ok, pid}
  rescue
    _ -> {:error, "Invalid PID string: #{str}"}
  end
end
