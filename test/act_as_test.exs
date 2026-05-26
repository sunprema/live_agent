defmodule LiveAgent.ActAsTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias LiveAgent.Config

  @router_opts LiveAgent.Router.init([])
  @session_opts [store: :cookie, key: "_la_test_key", signing_salt: "saltyyyy"]
  # Plug.Session's cookie store signs with the conn's secret_key_base.
  @secret String.duplicate("a", 64)

  setup do
    on_exit(fn ->
      Application.delete_env(:live_agent, :act_as)
      Application.delete_env(:live_agent, :session_options)
    end)

    :ok
  end

  describe "Config readers" do
    test "act_as_fun resolves a 2-arity closure, else a tagged error" do
      assert {:error, :not_configured} = Config.act_as_fun()

      Application.put_env(:live_agent, :act_as, fn _c, _i -> :ok end)
      assert {:ok, fun} = Config.act_as_fun()
      assert is_function(fun, 2)

      Application.put_env(:live_agent, :act_as, fn _c -> :ok end)
      assert {:error, :bad_arity} = Config.act_as_fun()
    end

    test "session_options resolves a non-empty keyword list, else not_configured" do
      assert {:error, :not_configured} = Config.session_options()

      Application.put_env(:live_agent, :session_options, @session_opts)
      assert {:ok, @session_opts} = Config.session_options()
    end

    test "act_as_enabled? is true under the test build" do
      assert Config.act_as_enabled?()
    end
  end

  describe "POST /act_as gating" do
    test "400 with a precise error when :act_as is unconfigured" do
      conn = post_act_as(%{identifier: "someone@example.com"})
      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["ok"] == false
      assert body["error"] =~ "not configured"
    end

    test "400 when :act_as is set but :session_options is missing" do
      Application.put_env(:live_agent, :act_as, fn conn, _id -> conn end)

      conn = post_act_as(%{identifier: "someone@example.com"})
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "session_options"
    end

    test "400 when identifier is missing/empty" do
      Application.put_env(:live_agent, :act_as, fn conn, _id -> conn end)
      Application.put_env(:live_agent, :session_options, @session_opts)

      conn = post_act_as(%{identifier: ""})
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"] =~ "identifier"
    end
  end

  describe "POST /act_as happy + failure paths" do
    setup do
      Application.put_env(:live_agent, :session_options, @session_opts)
      :ok
    end

    test "invokes the closure, writes a session cookie, returns who" do
      # The closure receives a session-fetched conn and writes to it verbatim.
      Application.put_env(:live_agent, :act_as, fn conn, identifier ->
        put_session(conn, :current_user_email, identifier)
      end)

      conn = post_act_as(%{identifier: "orgb-admin@example.com"})

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body == %{"ok" => true, "who" => "orgb-admin@example.com"}

      # The session plug's before_send re-encoded the cookie into the response.
      set_cookie = get_resp_header(conn, "set-cookie")
      assert Enum.any?(set_cookie, &String.starts_with?(&1, "_la_test_key="))
    end

    test "a raising closure surfaces a structured 422, not a half-written session" do
      Application.put_env(:live_agent, :act_as, fn _conn, _id ->
        raise "user not found"
      end)

      conn = post_act_as(%{identifier: "ghost@example.com"})

      assert conn.status == 422
      body = Jason.decode!(conn.resp_body)
      assert body["ok"] == false
      assert body["error"] =~ "user not found"
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "a closure returning a non-conn is rejected" do
      Application.put_env(:live_agent, :act_as, fn _conn, _id -> :not_a_conn end)

      conn = post_act_as(%{identifier: "x@example.com"})
      assert conn.status == 422
      assert Jason.decode!(conn.resp_body)["error"] =~ "%Plug.Conn{}"
    end
  end

  defp post_act_as(payload) do
    conn(:post, "/act_as", Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> Map.put(:secret_key_base, @secret)
    |> put_private(:live_agent_config, %{allow_remote_access: false})
    |> LiveAgent.Router.call(@router_opts)
  end
end
