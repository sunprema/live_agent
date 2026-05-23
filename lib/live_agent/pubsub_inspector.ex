defmodule LiveAgent.PubSubInspector do
  @moduledoc false
  # PubSub introspection for hosts that opt in via
  # `plug LiveAgent, pubsub_tools: true` (auto-discover) or
  # `plug LiveAgent, pubsub_tools: MyApp.PubSub` (explicit name).
  #
  # Phoenix.PubSub v2 uses an Elixir `Registry` for local subscriber tracking,
  # so topic listing is `Registry.select/2` and subscriber count is
  # `Registry.lookup/2`. Tailing spawns a transient Task that subscribes via
  # `Phoenix.PubSub.subscribe/2`, collects messages until max_n or wait_ms,
  # and returns. No persistent state in live_agent itself.

  def available?, do: Code.ensure_loaded?(Phoenix.PubSub)

  @doc """
  Returns the configured PubSub name, or auto-discovers the first
  Phoenix.PubSub-shaped Registry currently registered. Returns
  `{:error, msg}` if none found.
  """
  def discover_pubsub do
    candidates =
      Process.registered()
      |> Enum.filter(fn name ->
        case Atom.to_string(name) do
          "Elixir." <> rest -> String.ends_with?(rest, "PubSub")
          _ -> false
        end
      end)

    case Enum.find(candidates, &phoenix_pubsub?/1) do
      nil -> {:error, "No Phoenix.PubSub registered. Pass `pubsub_tools: MyApp.PubSub` explicitly."}
      name -> {:ok, name}
    end
  end

  defp phoenix_pubsub?(name) do
    _ = Registry.select(name, [{{:"$1", :_, :_}, [], [:"$1"]}])
    true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  Returns `[{topic, subscriber_count}]` for every topic with at least one
  local subscriber on the given pubsub, sorted by descending subscriber count.
  """
  def list_topics(pubsub) do
    pubsub
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_t, n} -> -n end)
  end

  @doc """
  Subscribes to `topic` from a transient Task, collects up to `max_n` messages
  (or until `wait_ms` elapses), and returns them in arrival order. Each entry:
  `%{at: iso8601, payload: inspected_term}`.

  Returns `{:ok, list}` or `{:error, reason}`.
  """
  def tail_topic(pubsub, topic, opts) do
    wait_ms = (opts[:wait_ms] || 5_000) |> min(30_000) |> max(100)
    max_n = (opts[:max_n] || 50) |> min(500) |> max(1)

    task =
      Task.async(fn ->
        :ok = Phoenix.PubSub.subscribe(pubsub, topic)
        deadline = System.monotonic_time(:millisecond) + wait_ms
        collect(max_n, deadline, [])
      end)

    try do
      {:ok, Task.await(task, wait_ms + 2_000)}
    catch
      :exit, reason -> {:error, "tail task exited: #{inspect(reason)}"}
    end
  end

  defp collect(0, _deadline, acc), do: Enum.reverse(acc)

  defp collect(n, deadline, acc) do
    now = System.monotonic_time(:millisecond)
    remaining = max(0, deadline - now)

    if remaining == 0 do
      Enum.reverse(acc)
    else
      receive do
        msg ->
          entry = %{
            at: DateTime.utc_now() |> DateTime.to_iso8601(),
            payload: msg |> inspect(limit: 50, printable_limit: 2000)
          }

          collect(n - 1, deadline, [entry | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end
end
