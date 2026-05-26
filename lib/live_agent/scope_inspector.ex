defmodule LiveAgent.ScopeInspector do
  @moduledoc false
  # Surfaces the multi-tenant security context bound to a running LiveView —
  # the actor / tenant / scope the user on screen is authorized against — so
  # Claude can reason about it (and reproduce it in an eval) without grepping a
  # huge assigns dump or hand-reconstructing the scope.
  #
  # This is a specialization of SocketInspector's socket read, not a new
  # capture path: we read the same `:sys.get_state` socket and reuse its
  # sanitizer. The shape of "scope" varies across Ash apps, so resolution is
  # heuristic + config-overridable (`:scope_assign_keys`), never hard-coded.

  alias LiveAgent.SocketInspector

  # Assigns that *carry* a scope (a struct/map nesting actor + tenant + context).
  @default_scope_keys [:current_scope, :scope]
  # Assigns that *are* the actor directly.
  @actor_keys [:current_user, :current_actor, :actor, :current_member]
  # Assigns that *are* the tenant directly.
  @tenant_keys [:__tenant__, :current_tenant, :current_organization, :current_org, :tenant, :organization]

  # Fields read off a scope struct/map to find its actor/tenant/context.
  @scope_actor_fields [:actor, :user, :current_user, :current_actor]
  @scope_tenant_fields [:tenant, :__tenant__, :organization, :org, :org_id]
  @scope_context_fields [:context]

  # Fields tried, in order, to build a human-readable one-liner for an actor.
  @summary_fields [:email, :username, :name, :full_name, :display_name, :mrn, :slug, :title, :handle]

  @context_byte_cap 4_000

  @doc """
  Returns `{:ok, scope_map}` for a LiveView pid (pid or pid-string), or
  `{:error, reason}` if the socket can't be read. `scope_map` always has the
  full shape; `raw_present: false` means no scope-like assign was found (an
  unscoped LV) rather than a lookup failure.
  """
  def get_scope(pid) when is_binary(pid) do
    with {:ok, pid} <- SocketInspector.parse_pid(pid), do: get_scope(pid)
  end

  def get_scope(pid) when is_pid(pid) do
    with {:ok, %Phoenix.LiveView.Socket{assigns: assigns}} <- SocketInspector.get_socket(pid) do
      {:ok, extract_scope(assigns)}
    end
  end

  @doc """
  Pure extraction from a raw assigns map. Exposed for testing without a live
  socket.
  """
  def extract_scope(assigns) when is_map(assigns) do
    cond do
      scope = find_present(assigns, scope_keys()) ->
        {key, value} = scope
        from_scope_carrier(value, key, assigns)

      actor = find_present(assigns, @actor_keys) ->
        {key, value} = actor

        %{
          actor: summarize_actor(value),
          tenant: resolve_tenant(assigns),
          context: %{},
          source_keys: [to_string(key)] ++ tenant_source_keys(assigns),
          raw_present: true
        }

      tenant = find_present(assigns, @tenant_keys) ->
        {key, value} = tenant

        %{
          actor: nil,
          tenant: summarize_tenant(value),
          context: %{},
          source_keys: [to_string(key)],
          raw_present: true
        }

      true ->
        %{actor: nil, tenant: nil, context: %{}, source_keys: [], raw_present: false}
    end
  end

  # --- scope-carrying assign (current_scope / scope) ---

  defp from_scope_carrier(scope, key, assigns) when is_map(scope) do
    actor = field_value(scope, @scope_actor_fields)
    tenant = field_value(scope, @scope_tenant_fields)
    context = field_value(scope, @scope_context_fields)

    %{
      actor: actor && summarize_actor(actor),
      # A scope without an inner tenant can still sit beside a tenant assign.
      tenant: (tenant && summarize_tenant(tenant)) || resolve_tenant(assigns),
      context: sanitize_context(context),
      source_keys: [to_string(key)],
      raw_present: true
    }
  end

  # Non-map scope (unexpected) — surface it sanitized rather than dropping it.
  defp from_scope_carrier(scope, key, _assigns) do
    %{
      actor: nil,
      tenant: nil,
      context: %{"scope" => SocketInspector.sanitize_value(scope)},
      source_keys: [to_string(key)],
      raw_present: true
    }
  end

  # --- actor / tenant summaries ---

  defp summarize_actor(actor) when is_map(actor) do
    %{
      module: struct_module(actor),
      id: stringify_id(Map.get(actor, :id)),
      summary: actor_label(actor)
    }
  end

  defp summarize_actor(actor), do: %{module: nil, id: nil, summary: stringify_id(actor)}

  defp actor_label(actor) do
    case Enum.find_value(@summary_fields, fn f -> present_value(Map.get(actor, f)) end) do
      nil ->
        case stringify_id(Map.get(actor, :id)) do
          nil -> nil
          id -> "id=#{id}"
        end

      label ->
        to_string(label)
    end
  end

  # Tenant may be a scalar (org id / slug) or a struct (an organization record).
  defp summarize_tenant(tenant) when is_map(tenant) do
    case struct_module(tenant) do
      nil ->
        SocketInspector.sanitize_value(tenant)

      module ->
        %{module: module, id: stringify_id(Map.get(tenant, :id)), summary: actor_label(tenant)}
    end
  end

  defp summarize_tenant(tenant) when is_atom(tenant) and not is_nil(tenant), do: Atom.to_string(tenant)
  defp summarize_tenant(tenant), do: tenant

  defp resolve_tenant(assigns) do
    case find_present(assigns, @tenant_keys) do
      {_key, tenant} -> summarize_tenant(tenant)
      nil -> nil
    end
  end

  defp tenant_source_keys(assigns) do
    case find_present(assigns, @tenant_keys) do
      {key, _} -> [to_string(key)]
      nil -> []
    end
  end

  # --- context (sanitized + size-capped) ---

  defp sanitize_context(nil), do: %{}

  defp sanitize_context(context) when is_map(context) do
    sanitized = SocketInspector.sanitize_value(strip_struct(context))

    case Jason.encode(sanitized) do
      {:ok, json} when byte_size(json) > @context_byte_cap ->
        %{
          "__truncated__" => true,
          "byte_size" => byte_size(json),
          "keys" => sanitized |> map_keys() |> Enum.sort()
        }

      _ ->
        sanitized
    end
  end

  defp sanitize_context(other), do: SocketInspector.sanitize_value(other)

  # --- helpers ---

  defp scope_keys, do: configured_scope_keys() ++ @default_scope_keys

  defp configured_scope_keys do
    case LiveAgent.Config.scope_assign_keys() do
      keys when is_list(keys) -> Enum.filter(keys, &is_atom/1)
      _ -> []
    end
  end

  # Returns `{key, value}` for the first present key, or nil.
  defp find_present(assigns, keys) do
    Enum.find_value(keys, fn key ->
      case present_value(Map.get(assigns, key)) do
        nil -> nil
        value -> {key, value}
      end
    end)
  end

  # Reads the first present field off a scope struct/map.
  defp field_value(scope, fields) do
    Enum.find_value(fields, fn f -> present_value(Map.get(scope, f)) end)
  end

  # nil and Ash.NotLoaded count as "absent".
  defp present_value(nil), do: nil
  defp present_value(%{__struct__: Ash.NotLoaded}), do: nil
  defp present_value(value), do: value

  defp struct_module(%{__struct__: mod}), do: inspect(mod)
  defp struct_module(_), do: nil

  defp strip_struct(%{__struct__: _} = s), do: Map.from_struct(s)
  defp strip_struct(other), do: other

  defp map_keys(map) when is_map(map), do: Map.keys(map)
  defp map_keys(_), do: []

  defp stringify_id(nil), do: nil
  defp stringify_id(id) when is_binary(id), do: id
  defp stringify_id(id) when is_integer(id), do: Integer.to_string(id)
  defp stringify_id(id) when is_atom(id), do: Atom.to_string(id)
  defp stringify_id(id), do: inspect(id)
end
