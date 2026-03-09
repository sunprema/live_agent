defmodule LiveAgent.Router do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  plug(:match)
  plug(:check_remote_ip)
  plug(:dispatch)

  get "/mcp" do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> tap(fn conn ->
      receive do
        :close -> :ok
      after
        # Keep connection open for 30 minutes max
        1_800_000 -> :ok
      end

      conn
    end)
    |> halt()
  end

  post "/mcp" do
    opts =
      Plug.Parsers.init(
        parsers: [:json],
        pass: [],
        json_decoder: Jason
      )

    conn
    |> Plug.Parsers.call(opts)
    |> LiveAgent.MCP.Server.handle_request()
    |> halt()
  end

  # Standalone panel page

  get "/panel" do
    html = LiveAgent.Panel.standalone_html()

    conn
    |> put_resp_header("content-type", "text/html; charset=utf-8")
    |> send_resp(200, html)
    |> halt()
  end

  # Static assets

  get "/js" do
    path = :code.priv_dir(:live_agent) |> Path.join("static/live_agent.js")

    conn
    |> put_resp_header("content-type", "application/javascript")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, File.read!(path))
    |> halt()
  end

  get "/css" do
    path = :code.priv_dir(:live_agent) |> Path.join("static/live_agent.css")

    conn
    |> put_resp_header("content-type", "text/css")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, File.read!(path))
    |> halt()
  end

  # Browser state API

  get "/api/ash_resources" do
    if LiveAgent.AshInspector.available?() do
      resources = LiveAgent.AshInspector.list_resources()

      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, Jason.encode!(resources))
      |> halt()
    else
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, Jason.encode!(%{error: "ash_not_available"}))
      |> halt()
    end
  end

  get "/api/ash_resource" do
    conn = fetch_query_params(conn)
    name = conn.query_params["name"]

    if LiveAgent.AshInspector.available?() do
      case LiveAgent.AshInspector.resource_info(name) do
        {:ok, info} ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(200, Jason.encode!(info))
          |> halt()

        {:error, reason} ->
          conn
          |> put_resp_header("content-type", "application/json")
          |> send_resp(404, Jason.encode!(%{error: reason}))
          |> halt()
      end
    else
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, Jason.encode!(%{error: "ash_not_available"}))
      |> halt()
    end
  end

  get "/api/component_tree" do
    trees = LiveAgent.ComponentTreeStore.all()
    live_views = LiveAgent.SocketInspector.list_live_views()

    result =
      Enum.map(trees, fn {view_id, tree} ->
        view_name =
          Enum.find_value(live_views, fn lv ->
            if lv.id == view_id, do: lv.view
          end)

        components =
          Enum.map(tree.components, fn comp ->
            resolved = LiveAgent.SocketInspector.resolve_component_id(comp.cid)

            %{
              cid: comp.cid,
              dom_id: comp.dom_id,
              module: resolved && resolved.module,
              id: resolved && resolved.id,
              assign_keys: (resolved && resolved.assign_keys) || [],
              events: comp.events
            }
          end)

        %{view: view_name, view_id: view_id, components: components}
      end)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(result))
    |> halt()
  end

  get "/api/live_views" do
    views = LiveAgent.SocketInspector.list_live_views()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(views))
    |> halt()
  end

  get "/api/assigns" do
    conn = fetch_query_params(conn)
    pid = conn.query_params["pid"]

    case LiveAgent.SocketInspector.get_assigns(pid) do
      {:ok, assigns} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(assigns))
        |> halt()

      {:error, reason} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(404, Jason.encode!(%{error: to_string(reason)}))
        |> halt()
    end
  end

  post "/api/element" do
    opts = Plug.Parsers.init(parsers: [:json], pass: [], json_decoder: Jason)
    conn = Plug.Parsers.call(conn, opts)

    component =
      case get_in(conn.body_params, ["phx", "data-phx-component"]) do
        nil ->
          nil

        cid_str ->
          case Integer.parse(cid_str) do
            {cid, _} -> LiveAgent.SocketInspector.resolve_component_id(cid)
            _ -> nil
          end
      end

    element = Map.put(conn.body_params, "component", component)
    LiveAgent.BrowserStateStore.put_selected_element(element)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(%{ok: true, component: component}))
    |> halt()
  end

  post "/api/pin" do
    LiveAgent.BrowserStateStore.pin_context()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, "{\"ok\":true}")
    |> halt()
  end

  get "/api/events" do
    conn = fetch_query_params(conn)
    since_id = conn.query_params |> Map.get("since", "0") |> String.to_integer()
    events = LiveAgent.EventStore.get_events(since_id)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(events))
    |> halt()
  end

  delete "/api/events" do
    LiveAgent.EventStore.clear()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, "{\"ok\":true}")
    |> halt()
  end

  delete "/api/pin" do
    LiveAgent.BrowserStateStore.clear_pinned_context()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, "{\"ok\":true}")
    |> halt()
  end

  match "/*_ignored" do
    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end

  defp check_remote_ip(conn, _opts) do
    config = conn.private.live_agent_config

    if is_local?(conn.remote_ip) or config.allow_remote_access do
      conn
    else
      conn
      |> send_resp(
        403,
        "LiveAgent: remote connections are not allowed. Set allow_remote_access: true to enable."
      )
      |> halt()
    end
  end

  defp is_local?({127, 0, 0, _}), do: true
  defp is_local?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp is_local?({0, 0, 0, 0, 0, 65535, 32512, 1}), do: true
  defp is_local?(_), do: false
end
