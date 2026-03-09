defmodule LiveAgent.AshInspector do
  @moduledoc false

  @doc "Returns true if Ash is available in the running app."
  def available? do
    Code.ensure_loaded?(Ash.Resource.Info)
  end

  @doc """
  Returns a summary of every Ash resource registered under any Ash domain.
  Finds domains first (fast), then reads their resource lists directly —
  much faster than scanning every loaded module.
  """
  def list_resources do
    project_apps()
    |> Enum.flat_map(fn app ->
      safe(fn -> apply(Ash.Info, :domains_and_resources, [app]) end, [])
    end)
    |> Enum.flat_map(fn {_domain, resources} -> resources end)
    |> Enum.uniq()
    |> Enum.map(&resource_summary/1)
    |> Enum.sort_by(& &1.resource)
  end

  @doc """
  Returns full introspection data for a named resource.
  Accepts the module name with or without the `Elixir.` prefix,
  e.g. `"MyApp.Accounts.User"`.
  """
  def resource_info(name) do
    case find_resource(name) do
      {:ok, mod} -> {:ok, build_resource_info(mod)}
      {:error, _} = err -> err
    end
  end

  # ── Resource discovery ─────────────────────────────────────────────────────

  # Returns only the current project's apps (umbrella-aware), not deps.
  defp project_apps do
    if apps_paths = Mix.Project.apps_paths() do
      Enum.filter(Mix.Project.deps_apps(), &is_map_key(apps_paths, &1))
    else
      [Mix.Project.config()[:app]]
    end
  end

  defp find_resource(name) do
    candidates = [name, "Elixir.#{name}"]

    Enum.find_value(candidates, {:error, "Resource '#{name}' not found. Call list_ash_resources to see available resources."}, fn candidate ->
      try do
        mod = String.to_existing_atom(candidate)
        if Ash.Resource.Info.resource?(mod), do: {:ok, mod}
      rescue
        _ -> nil
      end
    end)
  end

  # ── Summary (used by list_resources) ──────────────────────────────────────

  defp resource_summary(mod) do
    attrs   = safe(fn -> Ash.Resource.Info.attributes(mod) end, [])
    actions = safe(fn -> Ash.Resource.Info.actions(mod) end, [])
    rels    = safe(fn -> Ash.Resource.Info.relationships(mod) end, [])
    domain  = safe(fn -> Ash.Resource.Info.domain(mod) end, nil)
    pk      = safe(fn -> Ash.Resource.Info.primary_key(mod) end, [])

    %{
      resource:           short(mod),
      domain:             short(domain),
      primary_key:        Enum.map(pk, &to_string/1),
      attribute_names:    Enum.map(attrs, &to_string(&1.name)),
      action_names:       format_action_names(actions),
      relationship_names: Enum.map(rels, &"#{&1.name} (#{&1.type})")
    }
  end

  defp format_action_names(actions) do
    Enum.map(actions, fn a ->
      if Map.get(a, :primary?, false), do: "#{a.name}*", else: to_string(a.name)
    end)
  end

  # ── Full resource info ─────────────────────────────────────────────────────

  defp build_resource_info(mod) do
    %{
      resource:      short(mod),
      domain:        safe(fn -> short(Ash.Resource.Info.domain(mod)) end, nil),
      primary_key:   safe(fn -> Ash.Resource.Info.primary_key(mod) |> Enum.map(&to_string/1) end, []),
      attributes:    safe(fn -> format_attributes(mod) end, []),
      actions:       safe(fn -> format_actions(mod) end, []),
      relationships: safe(fn -> format_relationships(mod) end, []),
      calculations:  safe(fn -> format_calculations(mod) end, []),
      aggregates:    safe(fn -> format_aggregates(mod) end, [])
    }
  end

  defp format_attributes(mod) do
    mod
    |> Ash.Resource.Info.attributes()
    |> Enum.map(fn attr ->
      %{
        name:        to_string(attr.name),
        type:        format_type(attr.type),
        allow_nil:   attr.allow_nil?,
        primary_key: attr.primary_key?,
        writable:    attr.writable?,
        public:      Map.get(attr, :public?, true)
      }
    end)
  end

  defp format_actions(mod) do
    mod
    |> Ash.Resource.Info.actions()
    |> Enum.map(fn action ->
      base = %{
        name:      to_string(action.name),
        type:      to_string(action.type),
        primary:   Map.get(action, :primary?, false),
        arguments: format_arguments(Map.get(action, :arguments, []))
      }

      case action.type do
        t when t in [:create, :update] ->
          accept = action |> Map.get(:accept, []) |> Enum.map(&to_string/1)
          Map.put(base, :accept, accept)

        _ ->
          base
      end
    end)
  end

  defp format_arguments(args) do
    Enum.map(args, fn arg ->
      %{
        name:      to_string(arg.name),
        type:      format_type(arg.type),
        allow_nil: arg.allow_nil?,
        default:   format_default(Map.get(arg, :default))
      }
    end)
  end

  defp format_relationships(mod) do
    mod
    |> Ash.Resource.Info.relationships()
    |> Enum.map(fn rel ->
      %{
        name:                  to_string(rel.name),
        type:                  to_string(rel.type),
        destination:           short(rel.destination),
        source_attribute:      to_string(rel.source_attribute),
        destination_attribute: to_string(rel.destination_attribute)
      }
    end)
  end

  defp format_calculations(mod) do
    mod
    |> Ash.Resource.Info.calculations()
    |> Enum.map(fn calc ->
      %{
        name:   to_string(calc.name),
        type:   format_type(Map.get(calc, :type)),
        public: Map.get(calc, :public?, true)
      }
    end)
  end

  defp format_aggregates(mod) do
    mod
    |> Ash.Resource.Info.aggregates()
    |> Enum.map(fn agg ->
      %{
        name:              to_string(agg.name),
        kind:              to_string(agg.kind),
        relationship_path: Enum.map(agg.relationship_path, &to_string/1),
        type:              format_type(Map.get(agg, :type))
      }
    end)
  end

  # ── Type formatting ────────────────────────────────────────────────────────

  defp format_type(nil), do: nil

  defp format_type({:array, inner}), do: "array(#{format_type(inner)})"

  defp format_type(type) when is_atom(type) do
    str = Atom.to_string(type)

    if String.contains?(str, ".") do
      str
      |> String.replace_prefix("Elixir.Ash.Type.", "")
      |> String.replace_prefix("Elixir.", "")
    else
      # Short atom: :string, :integer, :uuid, etc.
      str
    end
  end

  defp format_type(type), do: inspect(type)

  defp format_default(nil), do: nil
  defp format_default(f) when is_function(f), do: "<computed>"
  defp format_default(v), do: inspect(v)

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp short(nil), do: nil
  defp short(mod) when is_atom(mod),
    do: mod |> inspect() |> String.replace_prefix("Elixir.", "")

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  end
end
