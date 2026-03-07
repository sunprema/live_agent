defmodule LiveAgent do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      allow_remote_access: Keyword.get(opts, :allow_remote_access, false)
    }
  end

  @impl true
  def call(%Plug.Conn{path_info: ["live_agent" | rest]} = conn, config) do
    conn
    |> Plug.Conn.put_private(:live_agent_config, config)
    |> Plug.forward(rest, LiveAgent.Router, [])
    |> Plug.Conn.halt()
  end

  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, fn conn ->
      content_type = Plug.Conn.get_resp_header(conn, "content-type")

      if conn.status == 200 and html_response?(content_type) do
        inject_panel(conn)
      else
        conn
      end
    end)
  end

  defp html_response?(types),
    do: Enum.any?(types, &String.contains?(&1, "text/html"))

  defp inject_panel(conn) do
    snippet = """
    <link rel="stylesheet" href="/live_agent/css">
    <div id="la-root"></div>
    <script src="/live_agent/js"></script>
    """

    body =
      conn.resp_body
      |> IO.iodata_to_binary()
      |> String.replace(~r|</body>|i, "#{snippet}</body>", global: false)

    %{conn | resp_body: body}
  end
end
