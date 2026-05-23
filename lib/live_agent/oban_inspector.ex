defmodule LiveAgent.ObanInspector do
  @moduledoc false
  # Oban introspection for hosts that opt in via `plug LiveAgent, oban_tools: true`.
  #
  # live_agent has no compile-time dependency on Oban or Ecto — all references
  # go through `apply/3` so live_agent still compiles in apps that don't use
  # Oban. Queries use raw SQL against the `oban_jobs` table via
  # `Ecto.Adapters.SQL.query!/3` (loaded transitively by Oban at runtime).

  @valid_states ~w(available scheduled executing retryable completed discarded cancelled)

  def available? do
    Code.ensure_loaded?(Oban) and function_exported?(Oban, :config, 0)
  end

  @doc """
  List jobs from `oban_jobs` matching the given filters.
  Opts: :state, :queue, :worker, :limit (default 50, max 200).
  """
  def list_jobs(opts) do
    with :ok <- ensure_available(),
         {:ok, state} <- normalize_state(opts[:state]),
         {:ok, repo} <- fetch_repo() do
      limit = (opts[:limit] || 50) |> min(200) |> max(1)

      {where_sql, params} = build_where(state, opts[:queue], opts[:worker])

      sql = """
      SELECT id, state, queue, worker, args, attempt, max_attempts, priority,
             scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at,
             inserted_at, tags, errors
      FROM oban_jobs
      #{where_sql}
      ORDER BY id DESC
      LIMIT $#{length(params) + 1}
      """

      case run_sql(repo, sql, params ++ [limit]) do
        {:ok, %{rows: rows, columns: cols}} ->
          {:ok, Enum.map(rows, &row_to_job(&1, cols))}

        {:error, %{message: msg}} ->
          {:error, "oban query failed: #{msg}"}

        {:error, err} ->
          {:error, "oban query failed: #{inspect(err)}"}
      end
    end
  end

  @doc """
  Fetch one job by id with full error history.
  """
  def get_job(id) when is_integer(id) do
    with :ok <- ensure_available(),
         {:ok, repo} <- fetch_repo() do
      sql = """
      SELECT id, state, queue, worker, args, attempt, max_attempts, priority,
             scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at,
             inserted_at, tags, errors, meta, attempted_by
      FROM oban_jobs
      WHERE id = $1
      """

      case run_sql(repo, sql, [id]) do
        {:ok, %{rows: [row], columns: cols}} -> {:ok, row_to_job(row, cols)}
        {:ok, %{rows: []}} -> {:error, "no oban job with id #{id}"}
        {:error, err} -> {:error, "oban query failed: #{inspect(err)}"}
      end
    end
  end

  @doc """
  Move a job back to `available` state so it's picked up on the next queue
  poll. Wraps `Oban.retry_job/1`.
  """
  def retry_job(id) when is_integer(id) do
    with :ok <- ensure_available() do
      case apply(Oban, :retry_job, [id]) do
        :ok -> :ok
        other -> {:error, "retry_job returned #{inspect(other)}"}
      end
    end
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp ensure_available do
    if available?(), do: :ok, else: {:error, "Oban is not loaded in this app."}
  end

  defp normalize_state(nil), do: {:ok, nil}
  defp normalize_state(s) when s in @valid_states, do: {:ok, s}
  defp normalize_state(s) when is_atom(s), do: normalize_state(Atom.to_string(s))

  defp normalize_state(s),
    do: {:error, "invalid state #{inspect(s)} — must be one of #{inspect(@valid_states)}"}

  defp fetch_repo do
    case apply(Oban, :config, []) do
      %{repo: repo} -> {:ok, repo}
      _ -> {:error, "Oban.config() did not return a configured repo"}
    end
  rescue
    e -> {:error, "Oban.config/0 raised: #{Exception.message(e)}"}
  end

  defp build_where(state, queue, worker) do
    {clauses, params, _} =
      [{state, "state"}, {queue, "queue"}, {worker, "worker"}]
      |> Enum.reduce({[], [], 1}, fn
        {nil, _col}, acc ->
          acc

        {val, col}, {clauses, params, idx} ->
          {["#{col} = $#{idx}" | clauses], [val | params], idx + 1}
      end)

    case clauses do
      [] -> {"", []}
      cs -> {"WHERE " <> Enum.join(Enum.reverse(cs), " AND "), Enum.reverse(params)}
    end
  end

  defp run_sql(repo, sql, params) do
    try do
      {:ok, apply(Ecto.Adapters.SQL, :query!, [repo, sql, params])}
    rescue
      e -> {:error, e}
    end
  end

  defp row_to_job(row, cols) do
    cols
    |> Enum.zip(row)
    |> Enum.into(%{}, fn {col, val} -> {col, normalize_value(val)} end)
  end

  defp normalize_value(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp normalize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp normalize_value(v), do: v
end
