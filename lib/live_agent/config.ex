defmodule LiveAgent.Config do
  @moduledoc false
  # Bridges the host app's `plug LiveAgent, ...` options into a process-global
  # sink that the MCP tool layer can read. Plug config is per-conn, but MCP
  # tool listing has no conn — so on every request we sync the merged opts
  # into `:persistent_term`. Writes only happen when the value actually
  # changes, so the steady-state cost is one `:persistent_term.get/2`.

  @key {__MODULE__, :tools}


  def capture(%{} = config) do
    current = :persistent_term.get(@key, nil)
    new = Map.take(config, [:oban_tools, :pubsub_tools, :scope_assign_keys])
    if current != new, do: :persistent_term.put(@key, new)
    :ok
  end

  def oban_tools_enabled? do
    case :persistent_term.get(@key, %{}) |> Map.get(:oban_tools, false) do
      true -> true
      _ -> false
    end
  end

  @doc """
  Returns `{:ok, name}` if pubsub tools are enabled, or `:disabled`. The
  caller resolves `:auto` into a real pubsub name via PubSubInspector at
  query time (so we don't bake in a name that's racing with app startup).
  """
  def pubsub_tools do
    case :persistent_term.get(@key, %{}) |> Map.get(:pubsub_tools, false) do
      false -> :disabled
      nil -> :disabled
      true -> {:ok, :auto}
      name when is_atom(name) -> {:ok, name}
      _ -> :disabled
    end
  end

  def pubsub_tools_enabled? do
    pubsub_tools() != :disabled
  end

  @doc """
  Host-supplied list of assign keys (atoms) that carry the security scope,
  tried before the built-in heuristics by `LiveAgent.ScopeInspector`. Set via
  `plug LiveAgent, scope_assign_keys: [:my_scope]`. Returns `[]` when unset.
  """
  def scope_assign_keys do
    case :persistent_term.get(@key, %{}) |> Map.get(:scope_assign_keys, []) do
      keys when is_list(keys) -> keys
      _ -> []
    end
  end

  # ── act_as (impersonation) ──────────────────────────────────────────────────
  # These read Application env (not plug opts): the `:act_as` value is a closure,
  # which doesn't belong in a per-conn plug option or persistent_term.

  @doc "True only in `:dev`/`:test` — impersonation never runs in a prod build."
  # Checked at RUNTIME, not via a module attribute: live_agent is a dependency,
  # so a compile-time `Mix.env()` freezes to the env the *dep* was built in
  # (:prod), never the host's — the gate would always be false. `Mix` is loaded
  # under `mix phx.server` in dev/test but absent from prod releases, so the
  # function_exported? guard is what keeps impersonation out of prod. Hosts that
  # depend on live_agent `only: :dev` get a second, build-level lock for free.
  def act_as_enabled?, do: function_exported?(Mix, :env, 0) and Mix.env() in [:dev, :test]

  @doc """
  Returns `{:ok, fun}` for the app-supplied 2-arity sign-in closure
  (`config :live_agent, act_as: &MyApp.DevActAs.sign_in/2`), or an error:
  `:not_configured` when unset, `:bad_arity` when it isn't a 2-arity function.
  """
  def act_as_fun do
    case Application.get_env(:live_agent, :act_as) do
      fun when is_function(fun, 2) -> {:ok, fun}
      nil -> {:error, :not_configured}
      _ -> {:error, :bad_arity}
    end
  end

  @doc """
  Returns `{:ok, opts}` with the session options the act_as route uses to set up
  the session before calling the closure (copy verbatim from the endpoint's
  `@session_options`), or `{:error, :not_configured}` when unset.
  """
  def session_options do
    case Application.get_env(:live_agent, :session_options) do
      opts when is_list(opts) and opts != [] -> {:ok, opts}
      _ -> {:error, :not_configured}
    end
  end
end
