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
              events: comp.events,
              forms: Map.get(comp, :forms, []),
              inputs: Map.get(comp, :inputs, []),
              buttons: Map.get(comp, :buttons, [])
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

  post "/api/errors" do
    opts = Plug.Parsers.init(parsers: [:json], pass: [], json_decoder: Jason)
    conn = Plug.Parsers.call(conn, opts)
    LiveAgent.ErrorStore.push_js_error(conn.body_params)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, "{\"ok\":true}")
    |> halt()
  end

  get "/api/errors" do
    conn = fetch_query_params(conn)
    since_id = conn.query_params |> Map.get("since", "0") |> String.to_integer()
    errors = LiveAgent.ErrorStore.get_errors(since_id)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(errors))
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

  get "/api/state_timeline" do
    conn = fetch_query_params(conn)
    last_n = conn.query_params |> Map.get("last_n", "20") |> parse_int(20)

    result =
      LiveAgent.SocketInspector.list_live_views()
      |> Enum.map(fn lv ->
        entries =
          case LiveAgent.StateTimeline.history(lv.pid_string, last_n) do
            list when is_list(list) -> Enum.map(list, &serialize_timeline_entry/1)
            _ -> []
          end

        %{pid: lv.pid_string, view: lv.view, entries: entries}
      end)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(result))
    |> halt()
  end

  get "/api/async" do
    LiveAgent.AsyncInspector.bump_activity()

    result =
      LiveAgent.SocketInspector.list_live_views()
      |> Enum.map(fn lv ->
        pending =
          case LiveAgent.AsyncInspector.pending(lv.pid_string) do
            list when is_list(list) -> list
            _ -> []
          end

        history =
          case LiveAgent.AsyncInspector.history(lv.pid_string, 25) do
            list when is_list(list) -> Enum.map(list, &serialize_async_entry/1)
            _ -> []
          end

        async_results =
          case LiveAgent.AsyncRegistry.list_async_results(lv.pid_string) do
            {:ok, r} -> r
            _ -> []
          end

        %{
          pid: lv.pid_string,
          view: lv.view,
          pending: pending,
          history: history,
          async_results: async_results
        }
      end)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(result))
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

  # Agent control: long-poll for commands the MCP side has enqueued.
  # Panel piggybacks its readiness signal via query params (gen, doc, lv,
  # main, url) so the server always knows whether a panel is parked and
  # whether the host page is hydrated. See LiveAgent.PanelStatus.
  get "/api/commands" do
    conn = fetch_query_params(conn)
    LiveAgent.PanelStatus.report(conn.query_params)
    commands = LiveAgent.CommandQueue.poll()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(commands))
    |> halt()
  end

  # Panel posts this once on init so the server learns the panel is back
  # before the first long-poll completes. Carries the same readiness fields
  # as the poll piggyback. Body is permissive — keys we don't recognize are
  # ignored by PanelStatus.
  post "/api/hello" do
    opts = Plug.Parsers.init(parsers: [:json], pass: [], json_decoder: Jason)
    conn = Plug.Parsers.call(conn, opts)
    LiveAgent.PanelStatus.report(conn.body_params)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, "{\"ok\":true}")
    |> halt()
  end

  # Agent control: panel reports the result of an executed command.
  # length: 50MB — screenshot results carry base64 PNGs that exceed the 8MB
  # default for a full 4K capture, which would truncate the JSON body and
  # surface as "Invalid Base64" at the MCP layer.
  post "/api/commands/result" do
    opts =
      Plug.Parsers.init(
        parsers: [:json],
        pass: [],
        json_decoder: Jason,
        length: 50_000_000
      )

    conn = Plug.Parsers.call(conn, opts)

    with {:ok, id} <- fetch_command_id(conn.body_params),
         result <- Map.drop(conn.body_params, ["id"]),
         :ok <- LiveAgent.CommandQueue.post_result(id, result) do
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(200, "{\"ok\":true}")
      |> halt()
    else
      {:error, :not_found} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(404, Jason.encode!(%{error: "no waiter for that id"}))
        |> halt()

      {:error, reason} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(400, Jason.encode!(%{error: to_string(reason)}))
        |> halt()
    end
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

  defp fetch_command_id(%{"id" => id}) when is_integer(id), do: {:ok, id}

  defp fetch_command_id(%{"id" => id}) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_id}
    end
  end

  defp fetch_command_id(_), do: {:error, :missing_id}

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_int(_, default), do: default

  defp serialize_timeline_entry(entry) do
    entry
    |> Map.put(:duration_ms, entry.duration_us && div(entry.duration_us, 1000))
    |> Map.update!(:at, &DateTime.to_iso8601/1)
  end

  defp serialize_async_entry(entry) do
    entry
    |> Map.put(:duration_ms, entry.duration_us && div(entry.duration_us, 1000))
    |> Map.update!(:at, &DateTime.to_iso8601/1)
  end

  defp is_local?({127, 0, 0, _}), do: true
  defp is_local?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp is_local?({0, 0, 0, 0, 0, 65535, 32512, 1}), do: true
  defp is_local?(_), do: false
end
