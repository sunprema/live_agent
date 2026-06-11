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

  get "/api/pin" do
    contexts = LiveAgent.BrowserStateStore.get_pinned_contexts()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(contexts))
    |> halt()
  end

  post "/api/pin" do
    case LiveAgent.BrowserStateStore.pin_context() do
      {:ok, index} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(%{ok: true, index: index}))
        |> halt()

      {:error, :no_element} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(400, "{\"ok\":false,\"error\":\"no element selected\"}")
        |> halt()
    end
  end

  put "/api/pin/:index/note" do
    opts = Plug.Parsers.init(parsers: [:json], pass: [], json_decoder: Jason)
    conn = Plug.Parsers.call(conn, opts)
    index = String.to_integer(index)
    note = Map.get(conn.body_params, "note", "")
    LiveAgent.BrowserStateStore.set_pin_note(index, note)

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

  # Browser console capture. Panel batches console.{log,info,warn,error,debug}
  # calls and POSTs them here. Kept separate from /api/errors so the noise
  # profiles don't bleed into each other.
  post "/api/console" do
    opts = Plug.Parsers.init(parsers: [:json], pass: [], json_decoder: Jason)
    conn = Plug.Parsers.call(conn, opts)
    entries = Map.get(conn.body_params, "entries", [])
    if is_list(entries), do: LiveAgent.ConsoleLogStore.push_batch(entries)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, "{\"ok\":true}")
    |> halt()
  end

  get "/api/console" do
    conn = fetch_query_params(conn)
    since_id = conn.query_params |> Map.get("since", "0") |> String.to_integer()
    logs = LiveAgent.ConsoleLogStore.get_logs(since_id: since_id)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(logs))
    |> halt()
  end

  delete "/api/console" do
    LiveAgent.ConsoleLogStore.clear()

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

  delete "/api/pin/:index" do
    index = String.to_integer(conn.path_params["index"])
    LiveAgent.BrowserStateStore.clear_pinned_context(index)

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, "{\"ok\":true}")
    |> halt()
  end

  delete "/api/pin" do
    LiveAgent.BrowserStateStore.clear_all_pinned_contexts()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, "{\"ok\":true}")
    |> halt()
  end

  get "/api/scratchpad" do
    snapshots = LiveAgent.ScratchpadStore.list_snapshots()

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(snapshots))
    |> halt()
  end

  post "/api/scratchpad" do
    opts = Plug.Parsers.init(parsers: [:json], pass: [], json_decoder: Jason)
    conn = Plug.Parsers.call(conn, opts)
    pid = Map.get(conn.body_params, "pid")
    name = Map.get(conn.body_params, "name")
    note = Map.get(conn.body_params, "note")

    case LiveAgent.ScratchpadStore.save(name, pid, note) do
      :ok ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(200, Jason.encode!(%{ok: true, name: name}))
        |> halt()

      {:error, reason} ->
        conn
        |> put_resp_header("content-type", "application/json")
        |> send_resp(400, Jason.encode!(%{ok: false, error: inspect(reason)}))
        |> halt()
    end
  end

  delete "/api/scratchpad/:name" do
    LiveAgent.ScratchpadStore.delete(conn.path_params["name"])

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

    commands =
      LiveAgent.CommandQueue.poll(
        panel_id(conn.query_params),
        drive?(conn.query_params),
        panel_url(conn.query_params)
      )

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

    LiveAgent.CommandQueue.note_panel(
      panel_id(conn.body_params),
      drive?(conn.body_params),
      panel_url(conn.body_params)
    )

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

  # Agent control: dev-only impersonation. The panel POSTs {identifier} here;
  # live-agent sets up the session from :session_options (because `plug LiveAgent`
  # mounts before Plug.Session, so this forward skipped it), then calls the
  # app-supplied :act_as closure to write the session, and sends the closure's
  # conn so the cookie is written back. The panel then reloads to reconnect as
  # the new actor. Three locks: env gate + required closure + Drive toggle
  # (enforced browser-side, like other drive ops).
  post "/act_as" do
    if LiveAgent.Config.act_as_enabled?() do
      opts = Plug.Parsers.init(parsers: [:json], pass: [], json_decoder: Jason)
      conn = Plug.Parsers.call(conn, opts)
      handle_act_as(conn, Map.get(conn.body_params, "identifier"))
    else
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(403, Jason.encode!(%{ok: false, error: "act_as is available only in :dev/:test builds."}))
      |> halt()
    end
  end

  match "/*_ignored" do
    conn
    |> send_resp(404, "Not Found")
    |> halt()
  end

  defp handle_act_as(conn, identifier) when is_binary(identifier) and identifier != "" do
    with {:ok, fun} <- LiveAgent.Config.act_as_fun(),
         {:ok, session_opts} <- LiveAgent.Config.session_options() do
      do_act_as(conn, identifier, fun, session_opts)
    else
      {:error, reason} -> act_as_config_error(conn, reason)
    end
  end

  defp handle_act_as(conn, _identifier) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(400, Jason.encode!(%{ok: false, error: "act_as requires a non-empty 'identifier'."}))
    |> halt()
  end

  defp do_act_as(conn, identifier, fun, session_opts) do
    # Establish the session before the closure so it can call put_session /
    # store_in_session verbatim, and so the cookie is re-encoded on send. Skip
    # if the host happened to mount us after Plug.Session (already fetched).
    conn =
      if match?(%{plug_session_fetch: _}, conn.private) do
        conn
      else
        conn
        |> Plug.Session.call(Plug.Session.init(session_opts))
        |> fetch_session()
      end

    signed_conn = fun.(conn, identifier)

    unless match?(%Plug.Conn{}, signed_conn) do
      raise "the :act_as closure must return a %Plug.Conn{}, got: #{inspect(signed_conn)}"
    end

    LiveAgent.EventStore.push_custom(%{
      type: "act_as",
      action: "impersonate",
      event: identifier,
      params: %{"identifier" => identifier}
    })

    signed_conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(200, Jason.encode!(%{ok: true, who: identifier}))
    |> halt()
  rescue
    e ->
      # A raising closure (e.g. user not found) must surface as a clean error,
      # never a half-written session.
      conn
      |> put_resp_header("content-type", "application/json")
      |> send_resp(422, Jason.encode!(%{ok: false, error: "act_as closure failed: #{Exception.message(e)}"}))
      |> halt()
  end

  defp act_as_config_error(conn, reason) do
    msg =
      case reason do
        :not_configured ->
          "act_as is not configured. Set both in config/dev.exs: " <>
            "`config :live_agent, act_as: &MyAppWeb.DevActAs.sign_in/2, " <>
            "session_options: [...]` — copy :session_options VERBATIM from your endpoint's @session_options."

        :bad_arity ->
          "config :live_agent, act_as must be a 2-arity function `fn conn, identifier -> ... end`."
      end

    conn
    |> put_resp_header("content-type", "application/json")
    |> send_resp(400, Jason.encode!(%{ok: false, error: msg}))
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

  # Per-tab identity for command routing: the panel's per-page-load `gen`.
  # Falls back to "unknown" for older/partial payloads so the queue still
  # gets a stable binary key.
  defp panel_id(%{"gen" => gen}) when is_binary(gen) and gen != "", do: gen
  defp panel_id(_), do: "unknown"

  # Whether this tab's Drive toggle is ON, from the readiness payload.
  defp drive?(%{"drive" => v}), do: v in [true, 1, "1", "true", "yes"]
  defp drive?(_), do: false

  # The tab's current path+query, for surfacing the Drive target in
  # list_live_views. Nil when absent.
  defp panel_url(%{"url" => url}) when is_binary(url) and url != "", do: url
  defp panel_url(_), do: nil

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
