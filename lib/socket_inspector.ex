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
  Resolves a component CID (the integer from data-phx-component) to its module,
  id, and assign keys by scanning all running LiveView channel processes.
  Returns a map or nil if not found.
  """
  def resolve_component_id(cid) when is_integer(cid) do
    find_liveview_pids()
    |> Enum.find_value(nil, fn pid ->
      try do
        case :sys.get_state(pid, 2000) do
          %{components: {cid_to_component, _id_to_cid, _uuids}} when is_map(cid_to_component) ->
            case Map.get(cid_to_component, cid) do
              {module, id, assigns, _private, _fingerprints} ->
                %{
                  module: inspect(module),
                  id: to_string(id),
                  assign_keys:
                    assigns
                    |> Map.keys()
                    |> Enum.reject(&internal_key?/1)
                    |> Enum.map(&to_string/1)
                    |> Enum.sort()
                }

              _ ->
                nil
            end

          _ ->
            nil
        end
      catch
        :exit, _ -> nil
      end
    end)
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

  @doc """
  Fetches the `%Phoenix.LiveView.Socket{}` for a LiveView channel pid.
  Returns `{:ok, socket}` or `{:error, reason}`.
  """
  def get_socket(pid) when is_pid(pid) do
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

  @doc """
  Extracts a sanitized, JSON-serializable assigns map from a Socket struct.
  Drops internal `__`-prefixed keys and converts atoms/structs to plain values.
  """
  def extract_assigns(%Phoenix.LiveView.Socket{assigns: assigns}) do
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
    case Map.get(v, :__struct__) do
      nil ->
        sanitize_map(v)

      mod ->
        sanitize_struct(mod, v)
    end
  end

  defp sanitize(v), do: inspect(v)

  defp sanitize_struct(DateTime, v) do
    try do
      DateTime.to_iso8601(v)
    rescue
      _ -> inspect(v)
    end
  end

  defp sanitize_struct(NaiveDateTime, v) do
    try do
      NaiveDateTime.to_iso8601(v)
    rescue
      _ -> inspect(v)
    end
  end

  defp sanitize_struct(Date, v) do
    try do
      Date.to_iso8601(v)
    rescue
      _ -> inspect(v)
    end
  end

  defp sanitize_struct(Time, v) do
    try do
      Time.to_iso8601(v)
    rescue
      _ -> inspect(v)
    end
  end

  defp sanitize_struct(mod, v) do
    mod_str = Atom.to_string(mod)

    cond do
      mod_str == "Elixir.Ash.NotLoaded" ->
        "<not loaded>"

      mod_str == "Elixir.Decimal" ->
        try do
          apply(Decimal, :to_string, [v])
        rescue
          _ -> inspect(v)
        end

      mod_str == "Elixir.Phoenix.LiveView.AsyncResult" ->
        %{
          "__async_result__" => true,
          "ok?" => Map.get(v, :ok?, false),
          "loading" => sanitize(Map.get(v, :loading)),
          "failed" => sanitize(Map.get(v, :failed)),
          "result" => sanitize(Map.get(v, :result))
        }

      true ->
        try do
          v |> Map.from_struct() |> sanitize_map()
        rescue
          _ -> inspect(v)
        end
    end
  end

  @doc """
  Extracts specific dot-path values from a sanitized assigns map.
  E.g. ["current_user.email", "count"] → %{"current_user.email" => "...", "count" => 5}
  """
  def extract_paths(assigns, paths) when is_map(assigns) and is_list(paths) do
    Map.new(paths, fn path ->
      segments = String.split(path, ".")
      {path, get_in_map(assigns, segments)}
    end)
  end

  defp get_in_map(map, [key]) when is_map(map), do: Map.get(map, key, "<key not found>")

  defp get_in_map(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nested when is_map(nested) -> get_in_map(nested, rest)
      nil -> nil
      _ -> "<not a map>"
    end
  end

  defp get_in_map(_, _), do: "<not a map>"

  defp pid_to_string(nil), do: nil
  defp pid_to_string(pid) when is_pid(pid), do: pid |> :erlang.pid_to_list() |> List.to_string()

  @doc """
  Parses a PID string like `"<0.123.0>"` back into a pid.
  """
  def parse_pid(str) when is_binary(str) do
    pid = str |> String.to_charlist() |> :erlang.list_to_pid()
    {:ok, pid}
  rescue
    _ -> {:error, "Invalid PID string: #{str}"}
  end
end
