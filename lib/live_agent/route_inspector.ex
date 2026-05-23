defmodule LiveAgent.RouteInspector do
  @moduledoc false
  # Discovers Phoenix LiveView routes across all routers loaded in the running
  # VM. live_agent has no compile-time knowledge of the host app, so we scan
  # `:code.all_loaded/0` for modules that export `__routes__/0` (the Phoenix
  # router convention) and pull out entries whose metadata carries
  # `:phoenix_live_view`.

  @doc """
  Returns a list of maps describing every live route in every loaded router.

  Each entry: %{path, module, live_action, live_session, router}. Sorted by
  router then path so the output is stable across calls.
  """
  def list_live_routes do
    :code.all_loaded()
    |> Enum.map(fn {mod, _file} -> mod end)
    |> Enum.filter(&phoenix_router?/1)
    |> Enum.flat_map(&extract_live_routes/1)
    |> Enum.sort_by(&{&1.router, &1.path})
  end

  defp phoenix_router?(mod) do
    function_exported?(mod, :__routes__, 0)
  rescue
    _ -> false
  end

  defp extract_live_routes(router) do
    router.__routes__()
    |> Enum.filter(fn route ->
      Map.get(route.metadata, :phoenix_live_view) != nil
    end)
    |> Enum.map(fn route ->
      {module, action, _opts, lv_meta} = route.metadata.phoenix_live_view

      %{
        router: short_name(router),
        path: route.path,
        module: short_name(module),
        live_action: action,
        live_session: Map.get(lv_meta || %{}, :name)
      }
    end)
  rescue
    # A module exporting __routes__/0 that isn't actually a Phoenix router, or
    # one whose route shape differs from what we expect. Skip silently rather
    # than crash the whole inspection.
    _ -> []
  end

  defp short_name(mod), do: mod |> inspect() |> String.replace_prefix("Elixir.", "")
end
