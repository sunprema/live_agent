defmodule LiveAgent.MCP.Tools do
  @moduledoc false

  alias LiveAgent.SocketInspector
  alias LiveAgent.AshInspector

  def tools do
    [
      %{
        name: "list_live_views",
        description: """
        Lists all active Phoenix LiveView processes currently running in the application.
        Returns the PID, view module, socket ID, URL, connection status, and available assign keys.
        Always call this first to discover which LiveView you want to inspect.
        """,
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &list_live_views/1
      },
      %{
        name: "get_assigns",
        description: """
        Returns the full assigns map for a specific LiveView process.
        Assigns are the data your LiveView template renders — this is the live state
        of what is currently displayed on screen.
        Use list_live_views first to obtain the pid_string.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{
              type: "string",
              description: "PID string from list_live_views, e.g. \"<0.123.0>\""
            }
          }
        },
        callback: &get_assigns/1
      },
      %{
        name: "get_assign",
        description: """
        Returns the value of a single assign key from a LiveView's socket.
        Useful when you only need one specific piece of data rather than all assigns.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid", "key"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"},
            key: %{type: "string", description: "Assign key name, e.g. \"current_user\""}
          }
        },
        callback: &get_assign/1
      },
      %{
        name: "get_socket_info",
        description: """
        Returns full socket metadata for a LiveView process: view module, socket ID,
        parent/root PIDs, transport info, URL, and all assigns.
        More detailed than get_assigns.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"}
          }
        },
        callback: &get_socket_info/1
      },
      %{
        name: "get_selected_element",
        description: """
        Returns the DOM element most recently selected via the LiveAgent panel's element picker.
        Includes tag, id, classes, text content, outerHTML (truncated), Phoenix attributes
        (phx-click, phx-hook, data-phx-component, etc.), and parent chain.
        Use this when the user says "I selected X" or "look at this element".
        """,
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &get_selected_element/1
      },
      %{
        name: "get_pinned_context",
        description: """
        Returns the element context that the user explicitly pinned for Claude using the
        LiveAgent panel's "Pin to Claude Context" button. This is the primary way users
        share a specific element or UI area they want help with.
        Returns null if nothing has been pinned yet.
        """,
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &get_pinned_context/1
      },
      %{
        name: "list_ash_resources",
        description: """
        Lists all Ash resources currently loaded in the running application.
        For each resource returns: module name, domain, primary key, attribute names,
        action names (primary actions marked with *), and relationship names with types.
        Call this first to understand the data model before writing or modifying Ash code.
        Returns an error if Ash is not available in the app.
        """,
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &list_ash_resources/1
      },
      %{
        name: "get_ash_resource_info",
        description: """
        Returns full introspection data for a single Ash resource: all attributes with types
        and constraints, all actions with their arguments and accepted attributes, relationships
        with source/destination keys, calculations, and aggregates.
        Use this before adding a field, writing a new action, or modifying a relationship.
        """,
        inputSchema: %{
          type: "object",
          required: ["resource"],
          properties: %{
            resource: %{
              type: "string",
              description: "Resource module name, e.g. \"MyApp.Accounts.User\""
            }
          }
        },
        callback: &get_ash_resource_info/1
      },
      %{
        name: "watch_assigns",
        description: """
        Snapshots assigns at this moment and returns them with a timestamp.
        Optionally filter to specific keys. Call repeatedly to track how assigns
        change as you interact with the UI.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"},
            keys: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional: only return these assign keys"
            }
          }
        },
        callback: &watch_assigns/1
      }
    ]
  end

  defp list_live_views(_args) do
    views = SocketInspector.list_live_views()

    if Enum.empty?(views) do
      {:ok,
       "No LiveView processes found. Make sure your Phoenix app is running and has active LiveView connections."}
    else
      text =
        views
        |> Enum.with_index(1)
        |> Enum.map(fn {view, i} ->
          keys_preview = Enum.take(view.assign_keys, 10) |> Enum.join(", ")

          more =
            if length(view.assign_keys) > 10,
              do: " (+#{length(view.assign_keys) - 10} more)",
              else: ""

          """
          #{i}. #{view.view}
             PID:       #{view.pid_string}
             Socket ID: #{view.id || "(none)"}
             URL:       #{view.url || "(none)"}
             Connected: #{view.connected}
             Assigns:   [#{keys_preview}#{more}]
          """
        end)
        |> Enum.join("\n")

      {:ok, "Found #{length(views)} LiveView process(es):\n\n#{text}"}
    end
  end

  defp get_assigns(%{"pid" => pid}) do
    case SocketInspector.get_assigns(pid) do
      {:ok, assigns} -> {:ok, Jason.encode!(assigns, pretty: true)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp get_assigns(_), do: {:error, :invalid_arguments}

  defp get_assign(%{"pid" => pid, "key" => key}) do
    case SocketInspector.get_assigns(pid) do
      {:ok, assigns} ->
        case Map.fetch(assigns, key) do
          {:ok, value} ->
            {:ok, Jason.encode!(value, pretty: true)}

          :error ->
            {:error, "Key '#{key}' not found. Available: #{Map.keys(assigns) |> Enum.join(", ")}"}
        end

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp get_assign(_), do: {:error, :invalid_arguments}

  defp get_socket_info(%{"pid" => pid}) do
    case SocketInspector.get_socket_info(pid) do
      {:ok, info} -> {:ok, Jason.encode!(info, pretty: true)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp get_socket_info(_), do: {:error, :invalid_arguments}

  defp watch_assigns(%{"pid" => pid} = args) do
    keys = Map.get(args, "keys")

    case SocketInspector.get_assigns(pid) do
      {:ok, assigns} ->
        filtered = if is_list(keys), do: Map.take(assigns, keys), else: assigns
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
        {:ok, "Snapshot at #{timestamp}:\n\n#{Jason.encode!(filtered, pretty: true)}"}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp watch_assigns(_), do: {:error, :invalid_arguments}

  defp get_selected_element(_args) do
    case LiveAgent.BrowserStateStore.get_selected_element() do
      nil ->
        {:ok,
         "No element selected. Ask the user to open the LiveAgent panel and use the Pick Element button."}

      element ->
        {:ok, Jason.encode!(element, pretty: true)}
    end
  end

  defp get_pinned_context(_args) do
    case LiveAgent.BrowserStateStore.get_pinned_context() do
      nil ->
        {:ok,
         "No context pinned. Ask the user to select an element in the LiveAgent panel and click 'Pin to Claude Context'."}

      context ->
        {:ok, Jason.encode!(context, pretty: true)}
    end
  end

  defp list_ash_resources(_args) do
    unless AshInspector.available?() do
      {:error, "Ash is not available in this application."}
    else
      resources = AshInspector.list_resources()

      if Enum.empty?(resources) do
        {:ok, "No Ash resources found. Make sure your app is running and resources are loaded."}
      else
        text =
          Enum.map_join(resources, "\n", fn r ->
            actions = Enum.join(r.action_names, ", ")
            rels = if r.relationship_names == [], do: "(none)", else: Enum.join(r.relationship_names, ", ")

            """
            #{r.resource}
              Domain:        #{r.domain || "(none)"}
              Primary key:   #{Enum.join(r.primary_key, ", ")}
              Attributes:    #{Enum.join(r.attribute_names, ", ")}
              Actions:       #{actions}
              Relationships: #{rels}
            """
          end)

        {:ok, "Found #{length(resources)} Ash resource(s):\n\n#{text}"}
      end
    end
  end

  defp get_ash_resource_info(%{"resource" => name}) do
    unless AshInspector.available?() do
      {:error, "Ash is not available in this application."}
    else
      case AshInspector.resource_info(name) do
        {:ok, info} -> {:ok, Jason.encode!(info, pretty: true)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp get_ash_resource_info(_), do: {:error, :invalid_arguments}
end
