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
        Returns the assigns map for a specific LiveView process.
        Assigns are the data your LiveView template renders — this is the live state
        of what is currently displayed on screen.
        Use list_live_views first to obtain the pid_string.

        Optionally pass `keys` as a list of dot-path strings to retrieve only specific
        nested values instead of the full (potentially huge) assigns map.
        Examples: "current_user.email", "current_user.total_bounties", "count"
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{
              type: "string",
              description: "PID string from list_live_views, e.g. \"<0.123.0>\""
            },
            keys: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional dot-path keys to extract, e.g. [\"current_user.email\", \"count\"]"
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
        name: "get_state_history",
        description: """
        Returns the recent assigns transitions (timeline) for a LiveView process.
        Each entry records what triggered the change, the diff between previous
        and current assigns, duration, and any exception.

        Trigger kinds:
          - "mount", "handle_params", "handle_event"  — captured from LiveView telemetry
          - "live_component_event"                    — from a LiveComponent handle_event
          - "unknown" (note: "likely_handle_info")    — a render happened but no
            callback telemetry preceded it; almost always means a handle_info
            (PubSub message, send_after timer, etc.) changed assigns

        Use this BEFORE re-running the user's flow when they ask "why did X
        change?" or "what happened after I clicked Y" — the answer is already
        recorded.

        Entries are returned newest-first. Default last_n is 20, max 50.
        Pair with get_state_event(pid, entry_id) to drill into a specific transition.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"},
            last_n: %{
              type: "integer",
              description: "Max entries to return (default 20, max 50)"
            }
          }
        },
        callback: &get_state_history/1
      },
      %{
        name: "get_state_event",
        description: """
        Returns a single timeline entry by id, with the full diff (changed /
        added / removed assigns), trigger details, duration, and exception
        if the callback crashed.

        Call get_state_history first to find the entry_id you care about.
        Diffs larger than ~16KB are stored as an `oversize: true` summary
        listing the changed keys; use get_assigns to read the current values.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid", "entry_id"],
          properties: %{
            pid: %{type: "string"},
            entry_id: %{type: "integer", description: "Entry id from get_state_history"}
          }
        },
        callback: &get_state_event/1
      },
      %{
        name: "list_async_tasks",
        description: """
        Returns the "what's loading right now" view for a LiveView:
          - pending: tasks currently in flight (name, kind, task_pid, elapsed_ms)
          - async_results: %AsyncResult{} values in assigns, with loading/ok?/failed flags

        `kind` is one of "start", "assign", "stream" — straight from LiveView's
        internal `:live_async` registry. Empty `pending` + an `async_result`
        with `loading: nil, ok?: true` means the task already finished —
        check get_async_history for the completion entry.

        Use this before re-running the user's flow when they say "the spinner
        is still up" or "is anything still loading?".
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"}
          }
        },
        callback: &list_async_tasks/1
      },
      %{
        name: "get_async_history",
        description: """
        Returns completed async tasks for a LiveView, newest first. Each entry
        records the name, kind, duration, result (:ok or :exit), and (for
        :assign kind) the post-completion %AsyncResult{} from assigns.

        Best-effort note: capture is driven by a 250ms poll loop, so tasks
        that complete in <~250ms may be missed entirely (the inspector
        couldn't observe them between launch and exit). Tasks that took
        longer than a single tick are reliably captured.

        Each entry also carries `state_timeline_id` linking to the
        get_state_event that recorded the assigns diff produced by the
        async callback (if one was recorded within ~150ms).
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{type: "string"},
            last_n: %{type: "integer", description: "Max entries (default 10, max 25)"}
          }
        },
        callback: &get_async_history/1
      },
      %{
        name: "get_async_event",
        description: """
        Returns a single async history entry by id. Use after
        get_async_history to drill into a specific completion.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid", "entry_id"],
          properties: %{
            pid: %{type: "string"},
            entry_id: %{type: "integer", description: "Entry id from get_async_history"}
          }
        },
        callback: &get_async_event/1
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
        name: "get_component_tree",
        description: """
        Returns the LiveComponent tree for the current page, parsed directly from the last
        rendered HTML response. For each component shows:
          - cid: the integer from data-phx-component (component ID within the socket)
          - module: the LiveComponent module name (e.g. "MyApp.FormComponent")
          - id: the component's id as passed in the template
          - dom_id: the id attribute on the component's root DOM element
          - assign_keys: the component's current assign keys (from BEAM state)
          - events: phx-click/change/submit/etc. bindings wired within the component
          - forms: any <form> tags found, with id + phx-submit + phx-change handlers
          - inputs: named inputs/textareas/selects with type and id
          - buttons: <button> elements with id, type, phx-click, and visible text

        Use this BEFORE calling click/fill/submit so you know which targeting strategy
        will work. Targeting rubric (most specific first):
          1. cid     — best for hitting a LiveComponent root (always unambiguous)
          2. selector — e.g. "#save-btn", "[phx-click='save']", "button[type='submit']"
          3. text    — e.g. "Save changes"; prefers buttons/links, falls back to any element

        The tree is a snapshot from the last page load — navigate to the page you care
        about first.
        """,
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &get_component_tree/1
      },
      %{
        name: "watch_assigns",
        description: """
        Snapshots assigns at this moment and returns them with a timestamp.
        Optionally filter to specific top-level keys.

        Set `mode` to "diff" to track what changed between two calls:
          - First call with mode "diff": captures a baseline snapshot and confirms it.
          - Subsequent calls: returns only keys whose values changed (before/after),
            then updates the baseline to the current state.
        Call reset_watch to clear the baseline and start fresh.

        Tip: combine `keys` + `mode: "diff"` to narrowly watch specific assigns
        for changes (e.g. watch "current_user" before and after a button click).
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"},
            keys: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional: only snapshot/diff these top-level assign keys"
            },
            mode: %{
              type: "string",
              enum: ["snapshot", "diff"],
              description: "\"snapshot\" (default) returns the current state; \"diff\" returns what changed since the last call"
            }
          }
        },
        callback: &watch_assigns/1
      },
      %{
        name: "highlight_element",
        description: """
        Draws a Chrome DevTools-style highlight overlay on an element in the user's
        browser. Requires the LiveAgent panel to be open in a tab.

        Pass exactly ONE of the following targets:
          - cid:      LiveComponent CID (integer from get_component_tree)
          - selector: CSS selector, e.g. "#submit", "form[phx-submit='save'] button"
          - text:     visible text to match; prefers clickable elements

        Optional:
          - duration_ms: how long to show the highlight (default 3000; 0 = until cleared)
          - label:       custom tooltip text (defaults to the element's tag/id/class)

        Returns the resolved element (tag, id, classes, text, phx-* attrs) and its rect.
        Use this to confirm with the user what you are referring to.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            cid: %{type: "integer", description: "LiveComponent CID from get_component_tree"},
            selector: %{type: "string", description: "CSS selector"},
            text: %{type: "string", description: "Visible text to match (prefers buttons/links)"},
            duration_ms: %{type: "integer", description: "Auto-clear after N ms (0 = until cleared)"},
            label: %{type: "string", description: "Tooltip text override"}
          }
        },
        callback: &highlight_element/1
      },
      %{
        name: "clear_highlight",
        description: """
        Removes any highlight overlay drawn by highlight_element.
        Requires the LiveAgent panel to be open in a tab.
        """,
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &clear_highlight/1
      },
      %{
        name: "take_screenshot",
        description: """
        Captures a screenshot of the user's browser and saves it as a PNG to /tmp.
        Returns the file path (e.g. "Screenshot saved to /tmp/live_agent_screenshot_20260522T143055Z.png (1920×1080)").
        Use the Read tool on that path to view the image.

        Optionally pass a CSS selector to capture only that element (e.g. a specific
        component, section, or panel). Without a selector, the full viewport is captured.
        The LiveAgent panel UI is automatically excluded from the capture.

        Use this to inspect layout, spacing, colours, and visual styling so you can
        suggest or apply targeted CSS fixes.

        Requires the LiveAgent panel to be open in a browser tab.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            selector: %{
              type: "string",
              description: "CSS selector for the element to capture (optional; omit for full viewport)"
            }
          },
          required: []
        },
        callback: &take_screenshot/1
      },
      %{
        name: "click",
        description: """
        Clicks an element in the user's browser by dispatching a real `click` event
        (so phx-click bindings, JS hooks, and form-trigger-action all fire normally).

        Requires the LiveAgent panel to be open AND the "Drive" toggle in the panel
        to be ON. If Drive is off, the tool returns an error — ask the user to enable it.

        Targeting rubric — pass exactly ONE, prefer in this order:
          1. cid       — only works for the root element of a LiveComponent
          2. selector  — e.g. "#save", "[phx-click='save']", "button.primary"
          3. text      — e.g. "Save changes"; matches buttons/links first, then text nodes

        Call get_component_tree first to see the available phx-click events, button
        texts, and ids on the current page.

        Returns the resolved element, URL before/after, main view info, flash messages,
        and a server-side diff of any assigns that changed during the action.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            cid: %{type: "integer"},
            selector: %{type: "string"},
            text: %{type: "string"}
          }
        },
        callback: &click/1
      },
      %{
        name: "navigate",
        description: """
        Navigates the user's browser to a path.

        Modes:
          - patch    (default): in-LV partial update (data-phx-link="patch")
          - navigate: cross-LV live_redirect (data-phx-link="redirect")
          - href:     full page navigation (browser reload)

        Requires the LiveAgent panel to be open AND "Drive" toggle ON.
        Returns URL before/after, main view info, flash, and assigns diff.
        """,
        inputSchema: %{
          type: "object",
          required: ["path"],
          properties: %{
            path: %{type: "string", description: "Path to navigate to, e.g. \"/cart\""},
            mode: %{
              type: "string",
              enum: ["patch", "navigate", "href"],
              description: "Navigation strategy (default: patch)"
            }
          }
        },
        callback: &navigate/1
      },
      %{
        name: "fill",
        description: """
        Sets the value of a form input in the user's browser and dispatches the
        `input` + `change` events (which triggers phx-change handlers).

        Handles:
          - text/email/number/password/textarea/select  -> sets `value`
          - checkbox/radio                              -> sets `checked` (truthy string)
          - contenteditable                             -> sets textContent

        Requires the panel open AND "Drive" toggle ON.

        Targeting rubric — pass exactly ONE, prefer in this order:
          1. selector  — e.g. "#user_email", "input[name='user[email]']" (most reliable for inputs)
          2. cid       — only when the input *is* the LiveComponent root (rare)
          3. text      — typically only works for labels with `for`

        Use get_component_tree to find input names/ids before calling. Then pass `value`.
        Returns the resolved element, new value, flash messages, and a
        server-side assigns diff.
        """,
        inputSchema: %{
          type: "object",
          required: ["value"],
          properties: %{
            cid: %{type: "integer"},
            selector: %{type: "string"},
            text: %{type: "string"},
            value: %{
              type: "string",
              description: "Value to set. For checkboxes: \"true\"/\"false\"."
            }
          }
        },
        callback: &fill/1
      },
      %{
        name: "submit",
        description: """
        Submits a form in the user's browser via `form.requestSubmit()`, which
        fires `phx-submit` handlers and runs HTML5 validation first.

        The target can be the form itself or any element within it — the nearest
        `<form>` ancestor is submitted.

        Requires the panel open AND "Drive" toggle ON.

        Targeting rubric — pass exactly ONE, prefer in this order:
          1. selector  — e.g. "form#user-form", "[phx-submit='save']" (best when forms have ids)
          2. cid       — works if the form is the LiveComponent root
          3. text      — match the submit button's text; the form ancestor is found automatically

        Returns URL before/after, flash, and assigns diff.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            cid: %{type: "integer"},
            selector: %{type: "string"},
            text: %{type: "string"}
          }
        },
        callback: &submit/1
      },
      %{
        name: "wait_for",
        description: """
        Blocks until a condition is met or `timeout_ms` elapses. Three modes —
        pass exactly ONE:

          - assign: {pid, key, equals?}
              Server-side poll of a LiveView assign. Omit `equals` to wait for
              any non-nil value. Does NOT require the panel to be open.

          - selector: "<css>"
              Browser-side wait until any element matching the selector appears.
              Requires the panel open.

          - text: "<substring>"
              Browser-side wait until the substring appears in document text.
              Requires the panel open.

        Default `timeout_ms` is 5000.
        Use this after click/navigate/fill/submit to be sure the UI has caught
        up before reading further state.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            assign: %{
              type: "object",
              properties: %{
                pid: %{type: "string", description: "LiveView PID"},
                key: %{type: "string", description: "Top-level assign key"},
                equals: %{description: "Optional exact value to match (any JSON)"}
              }
            },
            selector: %{type: "string"},
            text: %{type: "string"},
            timeout_ms: %{type: "integer", description: "Default 5000"}
          }
        },
        callback: &wait_for/1
      },
      %{
        name: "reset_watch",
        description: """
        Clears the stored baseline snapshot for a LiveView PID so the next
        watch_assigns call with mode "diff" starts fresh.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"},
            keys: %{
              type: "array",
              items: %{type: "string"},
              description: "Optional: must match the keys used in the watch_assigns call you want to reset"
            }
          }
        },
        callback: &reset_watch/1
      },
      %{
        name: "inject_css",
        description: """
        Injects a CSS rule block directly into the user's browser page without touching
        any source files. Use this to prototype style fixes visually: inject the CSS,
        call take_screenshot to confirm it looks right, then write the fix to the actual
        stylesheet.

        Optionally pass an `id` to label the injection so you can revert it by name later.
        Calling inject_css with the same id overwrites the previous CSS for that id.

        Requires the LiveAgent panel to be open in a browser tab.
        """,
        inputSchema: %{
          type: "object",
          required: ["css"],
          properties: %{
            css: %{type: "string", description: "CSS text to inject, e.g. \".hero { padding: 2rem; }\""},
            id: %{type: "string", description: "Label for this injection (default: \"default\"). Use distinct ids to manage multiple injections independently."}
          }
        },
        callback: &inject_css/1
      },
      %{
        name: "revert_css",
        description: """
        Removes previously injected CSS from the browser page.

        Pass `id` to remove a specific injection (must match the id used in inject_css).
        Omit `id` to remove ALL injections at once.

        Requires the LiveAgent panel to be open in a browser tab.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            id: %{type: "string", description: "Label of the injection to remove (omit to remove all)"}
          },
          required: []
        },
        callback: &revert_css/1
      },
      %{
        name: "scroll_to",
        description: """
        Scrolls the browser page to bring an element into view.

        Use this before take_screenshot to capture content that is below the fold,
        or to navigate to a specific section of a long page.

        Requires the LiveAgent panel to be open in a browser tab.
        """,
        inputSchema: %{
          type: "object",
          required: ["selector"],
          properties: %{
            selector: %{type: "string", description: "CSS selector of the element to scroll to"},
            behavior: %{type: "string", enum: ["smooth", "instant"], description: "Scroll animation (default: smooth)"}
          }
        },
        callback: &scroll_to/1
      },
      %{
        name: "send_event",
        description: """
        Directly fires a Phoenix LiveView `handle_event` callback on a running LiveView
        process — no browser click needed. The LiveView re-renders and pushes the diff to
        the connected client exactly as if the event came from the browser.

        Use this to:
          - Test event handlers in isolation
          - Trigger state transitions without a UI interaction
          - Verify how assigns change in response to a specific event

        Returns the before/after assigns diff.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid", "event"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"},
            event: %{type: "string", description: "The event name passed to handle_event/3"},
            params: %{type: "object", description: "Params map passed to handle_event/3 (default: {})"}
          }
        },
        callback: &send_event/1
      },
      %{
        name: "get_computed_styles",
        description: """
        Returns the browser's computed CSS for an element — the final resolved values
        after all stylesheets, inheritance, and cascade have been applied.

        Pass a CSS `selector` to target an element. Optionally pass a `properties` list
        to fetch only specific CSS properties (e.g. ["display", "padding", "color"]).
        Without `properties`, all computed styles are returned (~300 properties).

        Also returns the element's bounding rect (top, left, width, height) so you can
        spot sizing and position issues in one call.

        Use this instead of take_screenshot when you need exact values rather than a
        visual — faster and precise for diagnosing spacing, font, colour, and layout bugs.

        Requires the LiveAgent panel to be open in a browser tab.
        """,
        inputSchema: %{
          type: "object",
          required: ["selector"],
          properties: %{
            selector: %{type: "string", description: "CSS selector of the element to inspect"},
            properties: %{
              type: "array",
              items: %{type: "string"},
              description: "Specific CSS property names to return (e.g. [\"margin\", \"font-size\"]). Omit to return all."
            }
          }
        },
        callback: &get_computed_styles/1
      },
      %{
        name: "get_errors",
        description: """
        Returns errors collected since the LiveAgent server started — both browser-side
        JavaScript errors and server-side LiveView exceptions.

        JS errors include: uncaught exceptions (`window.onerror`) and unhandled Promise
        rejections. Server errors include: exceptions raised inside mount, handle_event,
        handle_params, and LiveComponent handle_event.

        Each error has a `source` field ("js" or "server"), a message or reason, a
        stacktrace where available, the view/callback where it occurred, and a timestamp.

        Call this after making a change to check whether anything broke silently.
        Pass `since_id` to fetch only errors newer than a known id (use the `id` field
        from the last response). Call `clear_errors` to reset the log.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            since_id: %{type: "integer", description: "Return only errors with id greater than this (default: 0 = all)"}
          },
          required: []
        },
        callback: &get_errors/1
      },
      %{
        name: "clear_errors",
        description: "Clears the error log. Useful before making a change so subsequent get_errors calls only show new errors.",
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &clear_errors/1
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

  defp get_assigns(%{"pid" => pid} = args) do
    case SocketInspector.get_assigns(pid) do
      {:ok, assigns} ->
        result =
          case Map.get(args, "keys") do
            paths when is_list(paths) and paths != [] ->
              SocketInspector.extract_paths(assigns, paths)

            _ ->
              assigns
          end

        {:ok, Jason.encode!(result, pretty: true) <> last_change_footer(pid)}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp get_assigns(_), do: {:error, :invalid_arguments}

  defp last_change_footer(pid) do
    case LiveAgent.StateTimeline.last_change(pid) do
      nil ->
        ""

      entry ->
        kind = Map.get(entry.trigger, :kind, "?")
        event = Map.get(entry.trigger, :event)
        label = if event, do: "#{kind} \"#{event}\"", else: kind

        "\n\nLast change: #{label} at #{DateTime.to_iso8601(entry.at)} " <>
          "(entry_id: #{entry.id}; call get_state_event for the full diff)"
    end
  end

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

  defp get_state_history(%{"pid" => pid} = args) do
    last_n = args |> Map.get("last_n", 20) |> normalize_last_n()

    case LiveAgent.StateTimeline.history(pid, last_n) do
      {:error, msg} ->
        {:error, to_string(msg)}

      [] ->
        {:ok,
         "No timeline entries for #{pid}. Either no callbacks have run since the panel started, or the pid is wrong — call list_live_views to confirm."}

      entries when is_list(entries) ->
        payload = Enum.map(entries, &serialize_timeline_entry/1)
        {:ok, Jason.encode!(payload, pretty: true)}
    end
  end

  defp get_state_history(_), do: {:error, :invalid_arguments}

  defp get_state_event(%{"pid" => pid, "entry_id" => id}) when is_integer(id) do
    case LiveAgent.StateTimeline.entry(pid, id) do
      nil ->
        {:error, "No entry with id #{id} for pid #{pid}."}

      {:error, msg} ->
        {:error, to_string(msg)}

      entry ->
        {:ok, Jason.encode!(serialize_timeline_entry(entry), pretty: true)}
    end
  end

  defp get_state_event(_), do: {:error, :invalid_arguments}

  defp normalize_last_n(n) when is_integer(n) and n > 0 and n <= 50, do: n
  defp normalize_last_n(n) when is_integer(n) and n > 50, do: 50
  defp normalize_last_n(_), do: 20

  defp serialize_timeline_entry(entry) do
    entry
    |> Map.put(:duration_ms, entry.duration_us && div(entry.duration_us, 1000))
    |> Map.update!(:at, &DateTime.to_iso8601/1)
  end

  defp list_async_tasks(%{"pid" => pid}) do
    LiveAgent.AsyncInspector.bump_activity()

    with {:ok, _} <- LiveAgent.SocketInspector.get_assigns(pid),
         {:ok, results} <- LiveAgent.AsyncRegistry.list_async_results(pid) do
      pending =
        case LiveAgent.AsyncInspector.pending(pid) do
          list when is_list(list) -> list
          _ -> []
        end

      payload = %{
        pending: pending,
        async_results: results
      }

      {:ok, Jason.encode!(payload, pretty: true)}
    else
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp list_async_tasks(_), do: {:error, :invalid_arguments}

  defp get_async_history(%{"pid" => pid} = args) do
    LiveAgent.AsyncInspector.bump_activity()

    last_n = args |> Map.get("last_n", 10) |> normalize_async_last_n()

    case LiveAgent.AsyncInspector.history(pid, last_n) do
      {:error, msg} ->
        {:error, to_string(msg)}

      [] ->
        {:ok,
         "No async history for #{pid}. Either no start_async/assign_async tasks have completed since the panel started, the tasks completed faster than the 250ms poll could observe, or the pid is wrong."}

      entries when is_list(entries) ->
        payload = Enum.map(entries, &serialize_async_entry/1)
        {:ok, Jason.encode!(payload, pretty: true)}
    end
  end

  defp get_async_history(_), do: {:error, :invalid_arguments}

  defp get_async_event(%{"pid" => pid, "entry_id" => id}) when is_integer(id) do
    LiveAgent.AsyncInspector.bump_activity()

    case LiveAgent.AsyncInspector.entry(pid, id) do
      nil -> {:error, "No async entry with id #{id} for pid #{pid}."}
      {:error, msg} -> {:error, to_string(msg)}
      entry -> {:ok, Jason.encode!(serialize_async_entry(entry), pretty: true)}
    end
  end

  defp get_async_event(_), do: {:error, :invalid_arguments}

  defp normalize_async_last_n(n) when is_integer(n) and n > 0 and n <= 25, do: n
  defp normalize_async_last_n(n) when is_integer(n) and n > 25, do: 25
  defp normalize_async_last_n(_), do: 10

  defp serialize_async_entry(entry) do
    entry
    |> Map.put(:duration_ms, entry.duration_us && div(entry.duration_us, 1000))
    |> Map.update!(:at, &DateTime.to_iso8601/1)
  end

  defp watch_assigns(%{"pid" => pid} = args) do
    keys = Map.get(args, "keys")
    mode = Map.get(args, "mode", "snapshot")

    case SocketInspector.get_assigns(pid) do
      {:ok, assigns} ->
        filtered = if is_list(keys) and keys != [], do: Map.take(assigns, keys), else: assigns
        timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

        case mode do
          "diff" ->
            store_key = {pid, keys}

            case LiveAgent.WatchStore.get_snapshot(store_key) do
              nil ->
                LiveAgent.WatchStore.put_snapshot(store_key, filtered)
                {:ok, "Baseline captured at #{timestamp}. Interact with the UI then call watch_assigns again to see what changed."}

              baseline ->
                diff = compute_diff(baseline, filtered)
                LiveAgent.WatchStore.put_snapshot(store_key, filtered)

                if map_size(diff) == 0 do
                  {:ok, "No changes detected (as of #{timestamp})."}
                else
                  {:ok, "Changes at #{timestamp}:\n\n#{Jason.encode!(diff, pretty: true)}"}
                end
            end

          _ ->
            {:ok, "Snapshot at #{timestamp}:\n\n#{Jason.encode!(filtered, pretty: true)}"}
        end

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp watch_assigns(_), do: {:error, :invalid_arguments}

  defp compute_diff(before_map, after_map) do
    all_keys =
      MapSet.union(MapSet.new(Map.keys(before_map)), MapSet.new(Map.keys(after_map)))

    Enum.reduce(all_keys, %{}, fn key, acc ->
      before_val = Map.get(before_map, key)
      after_val = Map.get(after_map, key)

      if before_val == after_val,
        do: acc,
        else: Map.put(acc, key, %{"before" => before_val, "after" => after_val})
    end)
  end

  defp reset_watch(%{"pid" => pid} = args) do
    keys = Map.get(args, "keys")
    store_key = {pid, keys}
    LiveAgent.WatchStore.clear(store_key)
    {:ok, "Watch baseline cleared for #{pid}. Next watch_assigns diff call will capture a fresh baseline."}
  end

  defp reset_watch(_), do: {:error, :invalid_arguments}

  # ── CSS injection ──────────────────────────────────────────────────────────

  defp inject_css(%{"css" => css} = args) when is_binary(css) do
    id = Map.get(args, "id", "default")
    dispatch_browser_command("inject_css", %{css: css, id: id}, fn result ->
      style_id = Map.get(result, "style_id", "la-css-#{id}")
      len = Map.get(result, "length", 0)
      "CSS injected (#{len} chars) as <style id=\"#{style_id}\">. Call revert_css to undo."
    end)
  end

  defp inject_css(_), do: {:error, "inject_css requires 'css' (string)"}

  defp revert_css(args) when is_map(args) do
    id = Map.get(args, "id")
    payload = if id, do: %{id: id}, else: %{}

    dispatch_browser_command("revert_css", payload, fn result ->
      removed = Map.get(result, "removed", 0)

      if id do
        "Removed injected CSS with id '#{id}' (#{removed} style element removed)."
      else
        "Removed all injected CSS (#{removed} style element(s) removed)."
      end
    end)
  end

  # ── Scroll ─────────────────────────────────────────────────────────────────

  defp scroll_to(%{"selector" => selector} = args) when is_binary(selector) do
    behavior = Map.get(args, "behavior", "smooth")
    payload = %{selector: selector, behavior: behavior}

    dispatch_browser_command("scroll_to", payload, fn result ->
      rect = Map.get(result, "rect", %{})
      "Scrolled to '#{selector}'. Element rect: #{inspect(rect)}."
    end)
  end

  defp scroll_to(_), do: {:error, "scroll_to requires 'selector' (string)"}

  # ── Computed styles ────────────────────────────────────────────────────────

  defp get_computed_styles(%{"selector" => selector} = args) when is_binary(selector) do
    properties = Map.get(args, "properties")
    payload = %{selector: selector}
    payload = if properties, do: Map.put(payload, :properties, properties), else: payload

    dispatch_browser_command("get_computed_styles", payload, fn result ->
      rect = Map.get(result, "rect", %{})
      styles = Map.get(result, "styles", %{})

      header = "Computed styles for '#{selector}' (#{map_size(styles)} properties)\n" <>
               "Rect: #{Jason.encode!(rect)}\n\n"

      body =
        styles
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map(fn {k, v} -> "  #{k}: #{v}" end)
        |> Enum.join("\n")

      header <> body
    end)
  end

  defp get_computed_styles(_), do: {:error, "get_computed_styles requires 'selector' (string)"}

  # ── Error watcher ──────────────────────────────────────────────────────────

  defp get_errors(args) when is_map(args) do
    since_id = Map.get(args, "since_id", 0)
    errors = LiveAgent.ErrorStore.get_errors(since_id)

    if Enum.empty?(errors) do
      {:ok, "No errors recorded#{if since_id > 0, do: " since id #{since_id}", else: ""}."}
    else
      js_errors = Enum.filter(errors, &(&1.source == "js"))
      server_errors = Enum.filter(errors, &(&1.source == "server"))

      sections =
        []
        |> maybe_append_errors("JavaScript errors (#{length(js_errors)})", js_errors, &format_js_error/1)
        |> maybe_append_errors("Server errors (#{length(server_errors)})", server_errors, &format_server_error/1)

      header = "#{length(errors)} error(s) collected. Latest id: #{hd(errors).id}\n"
      {:ok, header <> Enum.join(sections, "\n\n")}
    end
  end

  defp clear_errors(_args) do
    LiveAgent.ErrorStore.clear()
    {:ok, "Error log cleared."}
  end

  defp maybe_append_errors(sections, _title, [], _formatter), do: sections

  defp maybe_append_errors(sections, title, errors, formatter) do
    body =
      errors
      |> Enum.map(formatter)
      |> Enum.join("\n\n")

    sections ++ ["── #{title} ──\n#{body}"]
  end

  defp format_js_error(e) do
    loc =
      [e.filename, e.lineno && "line #{e.lineno}", e.colno && "col #{e.colno}"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    lines = ["[id:#{e.id}] [#{e.type}] #{e.message}", "  at #{loc}", "  #{e.timestamp}"]
    lines = if e.stack, do: lines ++ ["  #{String.slice(e.stack, 0, 400)}"], else: lines
    Enum.join(lines, "\n")
  end

  defp format_server_error(e) do
    lines = [
      "[id:#{e.id}] [#{e.scope}.#{e.callback}] #{e.view}#{if e.event, do: " event=#{e.event}", else: ""}",
      "  #{e.reason}",
      "  #{e.timestamp}"
    ]

    lines = if e.stacktrace && e.stacktrace != "", do: lines ++ [e.stacktrace], else: lines
    Enum.join(lines, "\n")
  end

  # ── Send event ─────────────────────────────────────────────────────────────

  defp send_event(%{"pid" => pid_string, "event" => event} = args) when is_binary(event) do
    params = Map.get(args, "params", %{})

    with {:ok, pid} <- SocketInspector.parse_pid(pid_string),
         {:ok, before_socket} <- SocketInspector.get_socket(pid) do
      try do
        view = before_socket.view

        result =
          GenServer.call(
            pid,
            {:run, fn socket -> view.handle_event(event, params, socket) end},
            5_000
          )

        case result do
          :ok ->
            {:ok, after_socket} = SocketInspector.get_socket(pid)
            diff = assigns_diff(before_socket, after_socket)
            format_send_event_result(event, diff)

          {:ok, reply} ->
            {:ok, after_socket} = SocketInspector.get_socket(pid)
            diff = assigns_diff(before_socket, after_socket)
            format_send_event_result(event, diff, reply)

          other ->
            {:error, "Unexpected result from LiveView: #{inspect(other)}"}
        end
      catch
        :exit, {:noproc, _} ->
          {:error, "LiveView process no longer alive."}

        :exit, {:timeout, _} ->
          {:error, "LiveView did not respond within 5 seconds."}

        kind, reason ->
          {:error, "handle_event raised: #{Exception.format(kind, reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_event(_), do: {:error, "send_event requires 'pid' and 'event'"}

  defp assigns_diff(before_socket, after_socket) do
    before_assigns = SocketInspector.extract_assigns(before_socket)
    after_assigns = SocketInspector.extract_assigns(after_socket)

    changed =
      after_assigns
      |> Enum.filter(fn {k, v} -> Map.get(before_assigns, k) != v end)
      |> Map.new()

    removed =
      before_assigns
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(after_assigns, &1))

    %{changed: changed, removed: removed}
  end

  defp format_send_event_result(event, diff, reply \\ nil) do
    changed = Map.get(diff, :changed, %{})
    removed = Map.get(diff, :removed, [])

    lines = ["Event '#{event}' handled successfully."]

    lines =
      if reply, do: lines ++ ["Reply: #{Jason.encode!(reply)}"], else: lines

    lines =
      if map_size(changed) > 0 do
        lines ++
          ["", "Changed assigns:"] ++
          Enum.map(changed, fn {k, v} -> "  #{k}: #{Jason.encode!(v)}" end)
      else
        lines
      end

    lines =
      if length(removed) > 0 do
        lines ++ ["", "Removed assigns: #{Enum.join(removed, ", ")}"]
      else
        lines
      end

    lines =
      if map_size(changed) == 0 and length(removed) == 0 do
        lines ++ ["No assign changes."]
      else
        lines
      end

    {:ok, Enum.join(lines, "\n")}
  end

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

  defp get_component_tree(_args) do
    trees = LiveAgent.ComponentTreeStore.all()

    if map_size(trees) == 0 do
      {:ok, "No component trees found. Navigate to a LiveView page first so LiveAgent can parse it."}
    else
      live_views = SocketInspector.list_live_views()

      text =
        Enum.map_join(trees, "\n\n", fn {view_id, tree} ->
          view_name =
            Enum.find_value(live_views, fn lv ->
              if lv.id == view_id, do: lv.view
            end) || "(unknown view)"

          header = "View: #{view_name}  (#{view_id})"

          if tree.components == [] do
            header <> "\n  No LiveComponents found on this page."
          else
            component_lines =
              Enum.map_join(tree.components, "\n", fn comp ->
                resolved = SocketInspector.resolve_component_id(comp.cid)
                module = (resolved && resolved.module) || "(unresolved)"
                comp_id = (resolved && resolved.id) || comp.dom_id || "?"
                assign_keys = (resolved && resolved.assign_keys) || []

                events_str =
                  if comp.events == [] do
                    "(none)"
                  else
                    comp.events
                    |> Enum.map(fn e -> "#{e.type}:#{e.name}" end)
                    |> Enum.join(", ")
                  end

                keys_str = if assign_keys == [], do: "(none)", else: Enum.join(assign_keys, ", ")
                dom_id_str = if comp.dom_id, do: "  dom_id:     #{comp.dom_id}\n", else: ""
                forms = Map.get(comp, :forms, [])
                inputs = Map.get(comp, :inputs, [])
                buttons = Map.get(comp, :buttons, [])

                forms_str =
                  if forms == [] do
                    ""
                  else
                    body =
                      Enum.map_join(forms, "\n", fn f ->
                        bits =
                          [
                            f.id && "id=#{f.id}",
                            f.phx_submit && "phx-submit=#{f.phx_submit}",
                            f.phx_change && "phx-change=#{f.phx_change}"
                          ]
                          |> Enum.reject(&is_nil/1)
                          |> Enum.join(", ")

                        "    - " <> bits
                      end)

                    "  forms:\n" <> body <> "\n"
                  end

                inputs_str =
                  if inputs == [] do
                    ""
                  else
                    body =
                      Enum.map_join(inputs, "\n", fn i ->
                        bits =
                          [
                            i.name && "name=#{i.name}",
                            "type=#{i.type}",
                            i.id && "id=#{i.id}"
                          ]
                          |> Enum.reject(&is_nil/1)
                          |> Enum.join(", ")

                        "    - " <> bits
                      end)

                    "  inputs:\n" <> body <> "\n"
                  end

                buttons_str =
                  if buttons == [] do
                    ""
                  else
                    body =
                      Enum.map_join(buttons, "\n", fn b ->
                        bits =
                          [
                            b.text != "" && "text=#{inspect(b.text)}",
                            b.phx_click && "phx-click=#{b.phx_click}",
                            b.id && "id=#{b.id}",
                            "type=#{b.type}"
                          ]
                          |> Enum.reject(&(&1 == nil or &1 == false))
                          |> Enum.join(", ")

                        "    - " <> bits
                      end)

                    "  buttons:\n" <> body <> "\n"
                  end

                "  [cid=#{comp.cid}] #{module}\n" <>
                  "  id:         #{comp_id}\n" <>
                  dom_id_str <>
                  "  assigns:    [#{keys_str}]\n" <>
                  "  events:     #{events_str}\n" <>
                  forms_str <>
                  inputs_str <>
                  buttons_str
              end)

            header <> "\n" <> component_lines
          end
        end)

      {:ok, text}
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

  # ── Agent control: browser-side commands ──────────────────────────────────

  defp highlight_element(args) when is_map(args) do
    payload = Map.take(args, ["cid", "selector", "text", "duration_ms", "label"])

    cond do
      not Enum.any?(["cid", "selector", "text"], &Map.has_key?(payload, &1)) ->
        {:error, "highlight_element requires one of: cid, selector, text"}

      true ->
        dispatch_browser_command("highlight", payload, &format_highlight_result/1)
    end
  end

  defp clear_highlight(_args) do
    dispatch_browser_command("clear_highlight", %{}, fn _ -> "Highlight cleared." end)
  end

  defp take_screenshot(args) when is_map(args) do
    payload =
      case Map.get(args, "selector") do
        nil -> %{}
        sel -> %{selector: sel}
      end

    case LiveAgent.CommandQueue.enqueue_and_await("screenshot", payload, 30_000) do
      {:ok, %{"ok" => true, "base64" => base64} = result} ->
        case save_screenshot_to_tmp(base64) do
          {:ok, path} ->
            {:ok, format_screenshot_text(path, result)}

          {:error, reason} ->
            {:error, "failed to save screenshot: #{inspect(reason)}"}
        end

      {:ok, %{"ok" => false, "error" => err}} ->
        {:error, "browser: " <> to_string(err)}

      {:error, :timeout} ->
        {:error, "No LiveAgent panel responded. Open the panel in a browser tab and try again."}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp format_screenshot_text(path, result) do
    w = Map.get(result, "width")
    h = Map.get(result, "height")
    dims = if w && h, do: " (#{w}×#{h})", else: ""
    "Screenshot saved to #{path}#{dims}"
  end

  # /tmp is hardcoded on purpose — System.tmp_dir!() returns the user-scoped
  # /var/folders/.../T/ on macOS, which is confusing when you're told the file
  # is "in /tmp". On Linux this is identical to System.tmp_dir!() anyway.
  @screenshot_dir "/tmp"

  defp save_screenshot_to_tmp(base64) do
    require Logger

    case Base.decode64(base64) do
      {:ok, bytes} ->
        ts =
          DateTime.utc_now()
          |> DateTime.to_iso8601(:basic)
          |> String.replace(~r/[^0-9TZ]/, "")

        path = Path.join(@screenshot_dir, "live_agent_screenshot_#{ts}.png")

        case File.write(path, bytes) do
          :ok ->
            Logger.info("[LiveAgent] screenshot saved: #{path}")
            {:ok, path}

          {:error, reason} ->
            Logger.warning(
              "[LiveAgent] failed to save screenshot to #{path}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      :error ->
        Logger.warning(
          "[LiveAgent] screenshot base64 decode failed (length=#{byte_size(base64)})"
        )

        {:error, :invalid_base64}
    end
  end

  defp click(args) when is_map(args) do
    payload = Map.take(args, ["cid", "selector", "text"])

    if not Enum.any?(["cid", "selector", "text"], &Map.has_key?(payload, &1)) do
      {:error, "click requires one of: cid, selector, text"}
    else
      dispatch_drive_command("click", payload, &format_drive_result(&1, "Clicked"))
    end
  end

  defp navigate(%{"path" => path} = args) when is_binary(path) do
    payload = args |> Map.take(["path", "mode"])
    dispatch_drive_command("navigate", payload, &format_drive_result(&1, "Navigated"))
  end

  defp navigate(_), do: {:error, "navigate requires 'path' (string)"}

  defp fill(%{"value" => value} = args) do
    payload = args |> Map.take(["cid", "selector", "text"]) |> Map.put("value", value)

    if not Enum.any?(["cid", "selector", "text"], &Map.has_key?(payload, &1)) do
      {:error, "fill requires one of: cid, selector, text"}
    else
      dispatch_drive_command("fill", payload, &format_drive_result(&1, "Filled"))
    end
  end

  defp fill(_), do: {:error, "fill requires 'value' (string)"}

  defp submit(args) when is_map(args) do
    payload = Map.take(args, ["cid", "selector", "text"])

    if not Enum.any?(["cid", "selector", "text"], &Map.has_key?(payload, &1)) do
      {:error, "submit requires one of: cid, selector, text (form or any element inside it)"}
    else
      dispatch_drive_command("submit", payload, &format_drive_result(&1, "Submitted"))
    end
  end

  defp wait_for(%{"assign" => %{"pid" => pid, "key" => key} = a} = args)
       when is_binary(pid) and is_binary(key) do
    timeout = Map.get(args, "timeout_ms", 5_000)
    equals = Map.get(a, "equals", :__any__)
    poll_assign(pid, key, equals, timeout, System.monotonic_time(:millisecond))
  end

  defp wait_for(%{"selector" => sel} = args) when is_binary(sel) do
    timeout = Map.get(args, "timeout_ms", 5_000)
    payload = %{"selector" => sel, "timeout_ms" => timeout}

    dispatch_browser_command("wait_for", payload, &format_wait_result/1,
      timeout: timeout + 3_000
    )
  end

  defp wait_for(%{"text" => txt} = args) when is_binary(txt) do
    timeout = Map.get(args, "timeout_ms", 5_000)
    payload = %{"text" => txt, "timeout_ms" => timeout}

    dispatch_browser_command("wait_for", payload, &format_wait_result/1,
      timeout: timeout + 3_000
    )
  end

  defp wait_for(_), do: {:error, "wait_for requires one of: assign, selector, text"}

  defp poll_assign(pid, key, equals, timeout, t_start) do
    case LiveAgent.SocketInspector.get_assigns(pid) do
      {:ok, assigns} ->
        current = Map.get(assigns, key)

        cond do
          equals == :__any__ and not is_nil(current) ->
            {:ok,
             "Assign #{inspect(key)} is non-nil:\n#{Jason.encode!(current, pretty: true)}"}

          equals != :__any__ and current == equals ->
            {:ok, "Assign #{inspect(key)} matched expected value."}

          System.monotonic_time(:millisecond) - t_start >= timeout ->
            target_desc =
              if equals == :__any__,
                do: "any non-nil value",
                else: "value " <> Jason.encode!(equals)

            {:error,
             "Timeout waiting for assign #{inspect(key)} to become #{target_desc}. " <>
               "Current value: #{Jason.encode!(current)}"}

          true ->
            Process.sleep(100)
            poll_assign(pid, key, equals, timeout, t_start)
        end

      {:error, reason} ->
        {:error, "Failed to read assigns for #{pid}: #{inspect(reason)}"}
    end
  end

  defp format_wait_result(%{"found" => true, "mode" => "selector"} = r) do
    "Found selector #{inspect(r["selector"])} after #{r["waited_ms"]}ms.\n" <>
      "Element: #{Jason.encode!(r["summary"], pretty: true)}"
  end

  defp format_wait_result(%{"found" => true, "mode" => "text"} = r) do
    "Found text #{inspect(r["text"])} after #{r["waited_ms"]}ms."
  end

  defp format_wait_result(r), do: Jason.encode!(r, pretty: true)

  # Runs a drive command with a before/after assigns snapshot bracket so the
  # caller sees what changed on the server side as a result.
  defp dispatch_drive_command(op, args, formatter) do
    before_snap = snapshot_all_live_views()

    case LiveAgent.CommandQueue.enqueue_and_await(op, args) do
      {:ok, %{"ok" => true} = result} ->
        after_snap = snapshot_all_live_views()
        diff = diff_live_view_snapshots(before_snap, after_snap)
        {:ok, formatter.(Map.put(result, "server_diff", diff))}

      {:ok, %{"ok" => false, "error" => err}} ->
        {:error, "browser: " <> to_string(err)}

      {:error, :timeout} ->
        {:error,
         "No LiveAgent panel responded. Open the panel in a browser tab and try again."}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp format_drive_result(result, verb) do
    url_before = Map.get(result, "url_before")
    url_after = Map.get(result, "url_after")
    resolved = Map.get(result, "resolved")
    flash = Map.get(result, "flash", [])
    diff = Map.get(result, "server_diff", %{})

    parts = [
      "#{verb} successfully.",
      "",
      "URL:    #{url_before} -> #{url_after}"
    ]

    parts =
      if resolved,
        do: parts ++ ["Target: #{Jason.encode!(resolved)}"],
        else: parts

    parts =
      if flash != [],
        do: parts ++ ["Flash:  #{Jason.encode!(flash)}"],
        else: parts

    parts =
      if map_size(diff) > 0,
        do: parts ++ ["", "Server-side diff:", Jason.encode!(diff, pretty: true)],
        else: parts ++ ["", "Server-side diff: (no changes detected within 2s)"]

    Enum.join(parts, "\n")
  end

  defp snapshot_all_live_views do
    LiveAgent.SocketInspector.list_live_views()
    |> Enum.map(fn lv ->
      case LiveAgent.SocketInspector.get_assigns(lv.pid_string) do
        {:ok, assigns} -> {lv.pid_string, %{view: lv.view, assigns: assigns}}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp diff_live_view_snapshots(before_map, after_map) do
    all = MapSet.union(MapSet.new(Map.keys(before_map)), MapSet.new(Map.keys(after_map)))

    Enum.reduce(all, %{}, fn pid, acc ->
      b = Map.get(before_map, pid)
      a = Map.get(after_map, pid)

      cond do
        is_nil(b) ->
          Map.put(acc, pid, %{"status" => "appeared", "view" => a.view})

        is_nil(a) ->
          Map.put(acc, pid, %{"status" => "gone", "view" => b.view})

        true ->
          changed = compute_diff_truncated(b.assigns, a.assigns)

          if map_size(changed) == 0,
            do: acc,
            else: Map.put(acc, pid, %{"view" => a.view, "changed" => changed})
      end
    end)
  end

  defp compute_diff_truncated(before_map, after_map) do
    all_keys =
      MapSet.union(MapSet.new(Map.keys(before_map)), MapSet.new(Map.keys(after_map)))

    Enum.reduce(all_keys, %{}, fn key, acc ->
      b = Map.get(before_map, key)
      a = Map.get(after_map, key)

      if b == a,
        do: acc,
        else: Map.put(acc, key, %{"before" => truncate(b), "after" => truncate(a)})
    end)
  end

  defp truncate(value) do
    encoded = Jason.encode!(value)

    if byte_size(encoded) > 400 do
      "<truncated #{byte_size(encoded)} bytes — call get_assigns for full value>"
    else
      value
    end
  end

  defp dispatch_browser_command(op, args, formatter, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    case LiveAgent.CommandQueue.enqueue_and_await(op, args, timeout) do
      {:ok, %{"ok" => true} = result} ->
        {:ok, formatter.(result)}

      {:ok, %{"ok" => false, "error" => err}} ->
        {:error, "browser: " <> to_string(err)}

      {:error, :timeout} ->
        {:error,
         "No LiveAgent panel responded. Open the panel in a browser tab and try again."}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp format_highlight_result(%{"matched_count" => 0}) do
    "No matching elements found."
  end

  defp format_highlight_result(result) do
    count = Map.get(result, "matched_count", 0)
    rect = Map.get(result, "rect")
    resolved = Map.get(result, "resolved")

    """
    Highlighted #{count} element#{if count == 1, do: "", else: "s"}.

    Rect:     #{Jason.encode!(rect)}
    Resolved: #{Jason.encode!(resolved, pretty: true)}
    """
  end
end
