defmodule LiveAgent do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      allow_remote_access: Keyword.get(opts, :allow_remote_access, false),
      drive_default: Keyword.get(opts, :drive_default, false),
      open_default: Keyword.get(opts, :open_default, false)
    }
  end

  @impl true
  def call(%Plug.Conn{path_info: ["live_agent" | rest]} = conn, config) do
    conn
    |> Plug.Conn.put_private(:live_agent_config, config)
    |> Plug.forward(rest, LiveAgent.Router, [])
    |> Plug.Conn.halt()
  end

  def call(conn, config) do
    Plug.Conn.register_before_send(conn, fn conn ->
      content_type = Plug.Conn.get_resp_header(conn, "content-type")

      if conn.status == 200 and html_response?(content_type) do
        inject_panel(conn, config)
      else
        conn
      end
    end)
  end

  defp html_response?(types),
    do: Enum.any?(types, &String.contains?(&1, "text/html"))

  defp inject_panel(conn, config) do
    drive_default = if config[:drive_default], do: "1", else: "0"
    open_default = if config[:open_default], do: "1", else: "0"

    snippet = """
    <link rel="stylesheet" href="/live_agent/css">
    <div id="la-root" data-drive-default="#{drive_default}" data-open-default="#{open_default}"></div>
    <script src="/live_agent/js"></script>
    """

    body = IO.iodata_to_binary(conn.resp_body)

    # Parse and store the component tree while we have the raw HTML
    tree = LiveAgent.ComponentTreeParser.extract(body)
    if tree.view_id, do: LiveAgent.ComponentTreeStore.put(tree.view_id, tree)

    new_body = String.replace(body, ~r|</body>|i, "#{snippet}</body>", global: false)
    %{conn | resp_body: new_body}
  end
end
