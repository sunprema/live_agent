defmodule LiveAgent.MCP.Server do
  @moduledoc false

  import Plug.Conn

  @protocol_version "2025-03-26"
  @server_info %{name: "LiveAgent MCP Server", version: "0.1.0"}

  def handle_request(conn) do
    case validate(conn.body_params) do
      {:ok, message} ->
        case process(message) do
          {:ok, nil} ->
            conn |> put_status(202) |> send_json(%{status: "ok"})

          {:ok, response} ->
            conn |> put_status(200) |> send_json(response)

          {:error, response} ->
            conn |> put_status(400) |> send_json(response)
        end

      :error ->
        conn
        |> put_status(400)
        |> send_json(%{jsonrpc: "2.0", id: nil, error: %{code: -32700, message: "Parse error"}})
    end
  end

  # --- Message routing ---

  defp process(%{"method" => "notifications/initialized"}), do: {:ok, nil}
  defp process(%{"method" => "notifications/cancelled"}), do: {:ok, nil}

  defp process(%{"method" => "ping", "id" => id}) do
    {:ok, %{jsonrpc: "2.0", id: id, result: %{}}}
  end

  defp process(%{"method" => "initialize", "id" => id, "params" => params}) do
    case params["protocolVersion"] do
      v when is_binary(v) and v >= @protocol_version ->
        {:ok,
         %{
           jsonrpc: "2.0",
           id: id,
           result: %{
             protocolVersion: @protocol_version,
             serverInfo: @server_info,
             capabilities: %{tools: %{listChanged: false}},
             tools: tool_list()
           }
         }}

      _ ->
        {:error,
         %{
           jsonrpc: "2.0",
           id: id,
           error: %{
             code: -32600,
             message:
               "Unsupported protocol version. Server requires #{@protocol_version} or later."
           }
         }}
    end
  end

  defp process(%{"method" => "tools/list", "id" => id}) do
    {:ok, %{jsonrpc: "2.0", id: id, result: %{tools: tool_list()}}}
  end

  defp process(%{"method" => "tools/call", "id" => id, "params" => params}) do
    name = params["name"]
    args = Map.get(params, "arguments", %{})
    {:ok, call_tool(id, name, args)}
  end

  defp process(%{"method" => method, "id" => id}) do
    {:error,
     %{
       jsonrpc: "2.0",
       id: id,
       error: %{code: -32601, message: "Method not found: #{method}"}
     }}
  end

  defp process(_), do: {:ok, nil}

  # --- Tool dispatch ---

  defp call_tool(id, name, args) do
    dispatch_map = build_dispatch()

    result =
      case dispatch_map do
        %{^name => callback} ->
          try do
            callback.(args)
          catch
            kind, reason ->
              {:error,
               "Tool raised an exception: #{Exception.format(kind, reason, __STACKTRACE__)}"}
          end

        _ ->
          {:error, "Unknown tool: #{name}"}
      end

    tool_response(id, result)
  end

  defp tool_response(id, {:ok, text}) when is_binary(text) do
    %{jsonrpc: "2.0", id: id, result: %{content: [%{type: "text", text: text}], isError: false}}
  end

  defp tool_response(id, {:error, :invalid_arguments}) do
    %{
      jsonrpc: "2.0",
      id: id,
      result: %{content: [%{type: "text", text: "Invalid arguments"}], isError: true}
    }
  end

  defp tool_response(id, {:error, reason}) when is_binary(reason) do
    %{jsonrpc: "2.0", id: id, result: %{content: [%{type: "text", text: reason}], isError: true}}
  end

  # --- Helpers ---

  defp tool_list do
    LiveAgent.MCP.Tools.tools()
    |> Enum.map(&Map.drop(&1, [:callback]))
  end

  defp build_dispatch do
    LiveAgent.MCP.Tools.tools()
    |> Map.new(fn tool -> {tool.name, tool.callback} end)
  end

  defp validate(%{"jsonrpc" => "2.0"} = message) do
    has_id = Map.has_key?(message, "id")
    has_method = Map.has_key?(message, "method")
    has_result = Map.has_key?(message, "result")

    cond do
      has_id and has_method -> {:ok, message}
      not has_id and has_method -> {:ok, message}
      has_id and has_result -> {:ok, message}
      true -> :error
    end
  end

  defp validate(_), do: :error

  defp send_json(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 200, Jason.encode!(data))
  end
end
