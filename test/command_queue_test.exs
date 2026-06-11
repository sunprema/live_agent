defmodule LiveAgent.CommandQueueTest do
  use ExUnit.Case, async: false

  alias LiveAgent.CommandQueue

  setup do
    # CommandQueue and PanelStatus are singletons started by the application;
    # reset the queue to a clean slate so panel ids don't leak between tests.
    :sys.replace_state(CommandQueue, fn _ ->
      %{next_id: 1, pending: [], mcp_waiters: %{}, panels: %{}}
    end)

    :ok
  end

  # Park `poll/4` in a task and return the task. The caller drives the rest.
  defp park(panel_id, drive, timeout \\ 1_000) do
    Task.async(fn -> CommandQueue.poll(panel_id, drive, "/#{panel_id}", timeout) end)
  end

  defp enqueue(op, args \\ %{}) do
    Task.async(fn ->
      CommandQueue.enqueue_and_await(op, args, timeout_ms: 1_000, wait_ready_ms: 0)
    end)
  end

  defp panels, do: :sys.get_state(CommandQueue).panels

  defp wait_parked(n) do
    wait_until(fn ->
      Enum.count(panels(), fn {_id, p} -> p.waiter != nil end) >= n
    end)
  end

  defp wait_until(fun, tries \\ 200) do
    Enum.reduce_while(1..tries, :timeout, fn _, _ ->
      if fun.(), do: {:halt, :ok}, else: (Process.sleep(5); {:cont, :timeout})
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("condition not met in time")
    end
  end

  test "single tab with Drive off still receives commands (fallback)" do
    a = park("A", false)
    wait_parked(1)

    enq = enqueue("screenshot")
    assert [%{op: "screenshot", id: id}] = Task.await(a)

    CommandQueue.post_result(id, %{"ok" => true})
    assert {:ok, %{"ok" => true}} = Task.await(enq)
  end

  test "command routes to the Drive-on tab when several are open" do
    a = park("A", false, 300)
    b = park("B", true)
    wait_parked(2)

    enq = enqueue("click")

    # B (Drive on) gets it; A keeps parking and times out empty.
    assert [%{op: "click", id: id}] = Task.await(b)
    assert [] = Task.await(a)

    CommandQueue.post_result(id, %{"ok" => true})
    assert {:ok, _} = Task.await(enq)
  end

  test "command is held (not leaked) while the Drive-on tab is mid-execution" do
    # A is parked but Drive-off; B is the Drive target but not currently parked
    # (it reported its drive state out-of-band, e.g. just finished a command).
    a = park("A", false, 300)
    wait_parked(1)
    CommandQueue.note_panel("B", true)
    wait_until(fn -> match?(%{drive: true}, panels()["B"]) end)

    enq = enqueue("click")

    # A must NOT receive it — it isn't the selected tab. A times out empty.
    assert [] = Task.await(a)

    # When B finally polls, it picks up the held command.
    assert [%{op: "click", id: id}] = CommandQueue.poll("B", true, "/cart", 500)

    CommandQueue.post_result(id, %{"ok" => true})
    assert {:ok, _} = Task.await(enq)
  end

  test "toggling Drive on flushes a pending command to that tab immediately" do
    # A parked Drive-off; a phantom Drive-on tab B exists but never parks, so the
    # command is held in pending.
    a = park("A", true)
    wait_parked(1)
    # A starts as the only tab and is Drive-on, so make it off first via re-note.
    CommandQueue.note_panel("A", false)
    CommandQueue.note_panel("B", true)
    wait_until(fn -> panels()["A"].drive == false and panels()["B"].drive == true end)

    enq = enqueue("click")
    # Nothing delivered yet (target B isn't parked, A is not the target).
    Process.sleep(30)
    refute Task.yield(a, 0)

    # A becomes the target and, being parked, receives the held command at once.
    CommandQueue.note_panel("A", true)

    assert [%{op: "click", id: id}] = Task.await(a)
    CommandQueue.post_result(id, %{"ok" => true})
    assert {:ok, _} = Task.await(enq)
  end

  describe "active_drive_target/0" do
    test "is nil when no tab has Drive on" do
      CommandQueue.note_panel("A", false, "/a")
      wait_until(fn -> Map.has_key?(panels(), "A") end)
      assert CommandQueue.active_drive_target() == nil
    end

    test "reports the freshest Drive-on tab's url" do
      CommandQueue.note_panel("A", false, "/dashboard")
      CommandQueue.note_panel("B", true, "/cart")
      wait_until(fn -> match?(%{drive: true}, panels()["B"]) end)

      assert %{panel_id: "B", url: "/cart"} = CommandQueue.active_drive_target()
    end
  end
end
