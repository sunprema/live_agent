defmodule LiveAgent.MCP.Tools do
  @moduledoc false

  alias LiveAgent.SocketInspector
  alias LiveAgent.ScopeInspector
  alias LiveAgent.AshInspector

  def tools do
    base_tools() ++ optional_tools()
  end

  defp base_tools do
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
        name: "get_scope",
        description: """
        Returns the security scope bound to a LiveView — the actor (current
        user), tenant/organization, and Ash scope context the user on screen is
        authorized against. This is the sanitized, compact answer to "who is
        this, and what are they scoped to?" without grepping the full assigns.

        RUBRIC: call this before any `project_eval` / SQL that touches
        tenant-scoped data, then bind the returned actor/tenant into your eval
        so the query reproduces the user's exact authorization boundary —
        instead of passing `authorize?: false` or a hand-built scope that does
        not match what the user actually sees.

        Resolution is heuristic across Ash apps (current_scope, current_user +
        __tenant__, current_organization, …) and can be overridden with
        `plug LiveAgent, scope_assign_keys: [:my_scope]`. A result with
        `raw_present: false` means the LiveView has no scope-like assign (an
        unscoped LV) — distinct from a lookup failure, which is an error.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"}
          }
        },
        callback: &get_scope/1
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
        Returns all elements the user has pinned for Claude using the LiveAgent panel's
        "Pin to Claude Context" button. Returns a numbered list (📌1, 📌2, ...) so you can
        reference each one by number. This is the primary way users share specific elements
        or UI areas they want help with. Each pin may include a "note" field — a message
        the user typed specifically for you (e.g. what's wrong with the element or what
        they want changed); treat it as direct instructions for that pin. Returns an
        empty list if nothing is pinned yet.
        """,
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &get_pinned_context/1
      },
      %{
        name: "get_panel_status",
        description: """
        Returns the current readiness of the LiveAgent panel.

        Browser-bound tools (click/navigate/fill/submit/take_screenshot/
        highlight_element/inject_css/...) all route through a readiness gate
        that waits briefly for the panel before dispatching. Call this tool
        directly when a previous command timed out or returned an empty
        result and you want to know *why* — typical answers:

          - ready: true                 — panel parked, page hydrated, safe to retry
          - "no panel has ever reported in" — no browser tab open on the host app
          - "panel last seen too long ago"  — host page is mid hot-reload or navigation
          - "document not fully loaded"     — page is still loading assets
          - "liveSocket not connected"      — LV channel hasn't reconnected yet

        Fields returned: ready, last_seen_age_ms, document_ready,
        live_socket_connected, root_lv_present, generation, url, reason.
        """,
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &get_panel_status/1
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

        Optionally clip the capture to a single element by `selector`, `cid`, or visible
        `text` (e.g. a specific component, section, or panel) — this keeps the relevant
        region from being buried in a full-page shot. Without any target, the full page
        is captured. The result reports the captured rect when clipped. The LiveAgent
        panel UI is automatically excluded from the capture.

        Use this to inspect layout, spacing, colours, and visual styling so you can
        suggest or apply targeted CSS fixes. To check whether a change moved only what
        you intended, use screenshot_baseline + screenshot_diff instead of eyeballing
        two full-page shots.

        Requires the LiveAgent panel to be open in a browser tab.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            selector: %{
              type: "string",
              description: "CSS selector for the element to capture (optional; omit for full page)"
            },
            cid: %{
              type: "integer",
              description: "LiveComponent cid to capture (from data-phx-component)"
            },
            text: %{
              type: "string",
              description: "Visible text of the element to capture"
            }
          },
          required: []
        },
        callback: &take_screenshot/1
      },
      %{
        name: "screenshot_baseline",
        description: """
        Captures a screenshot now and saves it as a named baseline under
        screenshots/baselines/<name>.png. Use this to mark a "before" state, then
        apply a CSS/markup change, then call screenshot_diff with the same name to
        see exactly what moved — instead of eyeballing two full-page images.

        Optionally clip to one element by selector / cid / text (same targeting as
        take_screenshot); a clipped baseline must be diffed with the same clip so the
        dimensions line up. Re-using a name overwrites the existing baseline.

        Requires the LiveAgent panel to be open in a browser tab.
        """,
        inputSchema: %{
          type: "object",
          required: ["name"],
          properties: %{
            name: %{type: "string", description: "Baseline name (letters, digits, '.', '_', '-')"},
            selector: %{type: "string", description: "CSS selector to clip to (optional)"},
            cid: %{type: "integer", description: "LiveComponent cid to clip to (optional)"},
            text: %{type: "string", description: "Visible text of the element to clip to (optional)"}
          }
        },
        callback: &screenshot_baseline/1
      },
      %{
        name: "screenshot_diff",
        description: """
        Captures the current screen and compares it against the named baseline (from
        screenshot_baseline), returning what changed instead of a second full image:

          * changed_ratio  — fraction of pixels that differ (0.0–1.0)
          * changed_boxes  — merged bounding boxes of the dirty regions
          * dims_match     — false when the page reflowed (sizes differ); ratio/boxes
                             are omitted in that case, both sizes are reported instead
          * overlay_path   — screenshots/diffs/<name>.png, the baseline with changed
                             pixels tinted red (read it to see the change)
          * baseline_path  — the baseline that was compared against

        Pass the SAME clip (selector / cid / text) you used for the baseline. Diffing
        is anti-aliasing-aware: sub-pixel rendering noise is ignored by default. Tune
        with `threshold` (0–1 colour distance, default 0.1) and `include_aa` (default
        false). A missing baseline is an error pointing back at screenshot_baseline.

        Requires the LiveAgent panel to be open in a browser tab.
        """,
        inputSchema: %{
          type: "object",
          required: ["name"],
          properties: %{
            name: %{type: "string", description: "Baseline name to compare against"},
            selector: %{type: "string", description: "CSS selector to clip to (match the baseline)"},
            cid: %{type: "integer", description: "LiveComponent cid to clip to (match the baseline)"},
            text: %{type: "string", description: "Visible text to clip to (match the baseline)"},
            threshold: %{type: "number", description: "Colour-distance threshold 0–1 (default 0.1)"},
            include_aa: %{type: "boolean", description: "Count anti-aliased pixels as changed (default false)"}
          }
        },
        callback: &screenshot_diff/1
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
          - auto     (default): picks patch/navigate/href by inspecting the host
                                router. Patch when the target resolves to the
                                same LV module as the current root LV *and* that
                                module defines handle_params/3; navigate for
                                cross-LV or LVs without handle_params/3; href
                                when the target isn't a LiveView route.
          - patch:    in-LV partial update (data-phx-link="patch")
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
              enum: ["auto", "patch", "navigate", "href"],
              description: "Navigation strategy (default: auto)"
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
        name: "act_as",
        description: """
        Logs the panel's browser session in as a chosen user/persona in one call, so the
        driving tools (click/fill/navigate) then exercise the app AS that actor — without
        the manual login dance. The flagship use case is testing multi-tenant org
        isolation: act_as(orgB_admin) → navigate to org A's record → expect forbidden/404.

        `identifier` is passed through verbatim to the host app's `:act_as` closure (email,
        id, persona name — the app decides). On success the page reloads, the LiveSocket
        reconnects authenticated, and this tool returns the new scope (actor/tenant) so you
        immediately see who you became — no second get_scope call needed.

        Requires (each returns a precise error, never a silent no-op):
          * a dev/test build (impersonation never compiles into prod),
          * `config :live_agent, act_as: &MyAppWeb.DevActAs.sign_in/2` plus a verbatim
            `session_options:` copy of the endpoint's @session_options,
          * the panel open AND the "Drive" toggle ON (impersonation is a privileged drive
            action).
        """,
        inputSchema: %{
          type: "object",
          required: ["identifier"],
          properties: %{
            identifier: %{
              type: "string",
              description: "Persona to become; passed verbatim to the app's :act_as closure (e.g. an email)"
            }
          }
        },
        callback: &act_as/1
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

        Works on plain LiveViews — it injects the same `"event"` message the JS
        client sends, so it runs the full handle_event lifecycle without needing
        any `handle_call/3` shim on the module.

        Returns the before/after assigns diff.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid", "event"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"},
            event: %{type: "string", description: "The event name passed to handle_event/3"},
            params: %{type: "object", description: "Params map passed to handle_event/3 (default: {})"},
            type: %{
              type: "string",
              description:
                "Event type, as the JS client tags it (e.g. \"click\", \"keyup\"). Use \"form\" only if params is a URL-encoded string. Default: \"click\"."
            }
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
      },
      %{
        name: "expect_assign",
        description: """
        Assertion sibling of get_assign: states pass/fail for a LiveView assign instead
        of dumping it for you to eyeball. Reads the assign at `key` (a dot-path like
        "alert.level" for nested maps/structs) and compares it.

        Provide exactly one matcher:
          * `equals`  — typed compare for scalars, with a stringified-compare fallback
                        (so equals: "5" also matches the integer 5)
          * `matches` — regex (or plain substring) tested against the stringified value

        By default (`timeout_ms` 0) it checks immediately. Set `timeout_ms` > 0 to poll
        until it passes or the time elapses — use this to wait out an async settle, the
        same bound as wait_for. A failing/timed-out assertion is NOT an error: it returns
        `{pass: false, ...}` with the last observed `actual`. Feeds the `verify` skill.

        Returns: { pass, path, expected, actual, waited_ms }.
        """,
        inputSchema: %{
          type: "object",
          required: ["pid", "key"],
          properties: %{
            pid: %{type: "string", description: "PID string from list_live_views"},
            key: %{type: "string", description: "Assign key or dot-path, e.g. \"alert.level\""},
            equals: %{description: "Expected value (any JSON scalar/structure)"},
            matches: %{type: "string", description: "Regex or substring tested against the stringified value"},
            timeout_ms: %{type: "integer", description: "0 = check now (default); >0 = poll until pass or timeout"}
          }
        },
        callback: &expect_assign/1
      },
      %{
        name: "expect_no_errors",
        description: """
        Assertion gate over the error log: passes only if no errors were recorded.
        Reuses the same store as get_errors (browser JS errors + server LiveView
        exceptions).

        Intended pattern — wrap an action so you get a clean pass/fail:
          1. clear_errors
          2. perform the action (click / fill / submit / navigate)
          3. expect_no_errors

        Or pass `since_id` (an `id` from a prior get_errors response) to only consider
        errors newer than that point. Returns `{pass, count, errors}`.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            since_id: %{type: "integer", description: "Only consider errors with id greater than this (default 0 = all)"}
          },
          required: []
        },
        callback: &expect_no_errors/1
      },
      %{
        name: "get_browser_logs",
        description: """
        Returns a tail of `console.{log,info,warn,error,debug}` calls captured
        from the host page since the LiveAgent server started.

        Useful when a browser-side command (click, screenshot, hook code, your
        own injected script) seems to fail silently — pull the console to see
        what the page actually said, without asking the user to open devtools.

        Filters:
          * `levels` — restrict to a subset, e.g. ["warn", "error"]. Defaults to all.
          * `since_id` — only entries newer than this id (use the `id` from the
            latest response to tail incrementally).
          * `limit` — cap on rows returned (default 100, max 500).

        Capture is a ring buffer (last 500 entries across all levels). Calls
        from inside the LiveAgent panel itself are excluded.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            levels: %{
              type: "array",
              items: %{type: "string", enum: ["log", "info", "warn", "error", "debug"]},
              description: "Restrict to these levels (default: all)"
            },
            since_id: %{type: "integer", description: "Return only entries with id greater than this (default: 0 = all)"},
            limit: %{type: "integer", description: "Max entries (default 100, max 500)"}
          },
          required: []
        },
        callback: &get_browser_logs/1
      },
      %{
        name: "clear_browser_logs",
        description: "Clears the browser console log buffer. Use before reproducing an issue so subsequent get_browser_logs calls only show new entries.",
        inputSchema: %{type: "object", properties: %{}, required: []},
        callback: &clear_browser_logs/1
      },
      %{
        name: "list_lv_routes",
        description: """
        Lists every Phoenix LiveView route in every router loaded in the running
        VM. Use this before calling `navigate` so you don't have to grep the
        host app's router.ex.

        Returns path, LiveView module, live_action, live_session, and the parent
        router for each route. Optionally filter by router (substring match) or
        by path prefix.
        """,
        inputSchema: %{
          type: "object",
          properties: %{
            router: %{type: "string", description: "Substring match on the router module name (e.g. \"AppWeb\" or \"Admin\")"},
            path_prefix: %{type: "string", description: "Only return routes whose path starts with this string"}
          },
          required: []
        },
        callback: &list_lv_routes/1
      }
    ]
  end

  # Tools that the host has to opt into via `plug LiveAgent, oban_tools: true`
  # (and similar). Surfaced only when enabled so MCP clients don't see tools
  # that would always 4xx.
  defp optional_tools do
    oban_tools_if_enabled() ++ pubsub_tools_if_enabled()
  end

  defp oban_tools_if_enabled do
    if LiveAgent.Config.oban_tools_enabled?() do
      [
        %{
          name: "list_oban_jobs",
          description: """
          Lists rows from the host app's `oban_jobs` table. Useful for
          verifying scheduled check-ins, retry behavior, and queue health
          without going through SQL.

          Filters (all optional):
            * `state` — one of: scheduled, available, executing, retryable,
              completed, discarded, cancelled
            * `queue` — exact queue name
            * `worker` — exact worker module name
            * `limit` — default 50, max 200

          Enabled by `plug LiveAgent, oban_tools: true` in the host endpoint.
          """,
          inputSchema: %{
            type: "object",
            properties: %{
              state: %{type: "string", description: "Filter by job state"},
              queue: %{type: "string", description: "Filter by queue name"},
              worker: %{type: "string", description: "Filter by worker module"},
              limit: %{type: "integer", description: "Max rows (default 50, max 200)"}
            },
            required: []
          },
          callback: &list_oban_jobs/1
        },
        %{
          name: "get_oban_job",
          description: """
          Fetch full details for one Oban job by id, including its error
          history (the closest thing Oban exposes to a per-job log).

          Enabled by `plug LiveAgent, oban_tools: true`.
          """,
          inputSchema: %{
            type: "object",
            properties: %{
              id: %{type: "integer", description: "oban_jobs.id"}
            },
            required: ["id"]
          },
          callback: &get_oban_job/1
        },
        %{
          name: "retry_oban_job",
          description: """
          Move an Oban job back to `available` so it's picked up on the next
          queue poll. Wraps `Oban.retry_job/1`. Useful for re-running a
          discarded or completed job during debugging.

          Enabled by `plug LiveAgent, oban_tools: true`.
          """,
          inputSchema: %{
            type: "object",
            properties: %{
              id: %{type: "integer", description: "oban_jobs.id"}
            },
            required: ["id"]
          },
          callback: &retry_oban_job/1
        }
      ]
    else
      []
    end
  end

  defp pubsub_tools_if_enabled do
    if LiveAgent.Config.pubsub_tools_enabled?() do
      [
        %{
          name: "list_pubsub_topics",
          description: """
          Lists every Phoenix.PubSub topic that currently has at least one
          local subscriber, with subscriber counts. Useful for verifying
          realtime fan-out and discovering topic names without grepping the
          codebase.

          Enabled by `plug LiveAgent, pubsub_tools: true` (auto-discovers
          the host's PubSub) or `pubsub_tools: MyApp.PubSub` (explicit).
          """,
          inputSchema: %{type: "object", properties: %{}, required: []},
          callback: &list_pubsub_topics/1
        },
        %{
          name: "tail_pubsub_topic",
          description: """
          Subscribes to a Phoenix.PubSub topic from a temporary task and
          returns up to `max_n` messages received within `wait_ms`.
          Blocks the MCP call for up to `wait_ms`.

          Useful for verifying that an action fans out the expected events —
          run this in one call, trigger the action in another (e.g. via
          `click`), and the second call returns the captured messages.

          Enabled by `plug LiveAgent, pubsub_tools: ...`.
          """,
          inputSchema: %{
            type: "object",
            properties: %{
              topic: %{type: "string", description: "Topic to subscribe to (e.g. \"demo:mode\")"},
              wait_ms: %{type: "integer", description: "Max time to wait for messages (default 5000, max 30000)"},
              max_n: %{type: "integer", description: "Max messages to capture before returning early (default 50, max 500)"}
            },
            required: ["topic"]
          },
          callback: &tail_pubsub_topic/1
        }
      ]
    else
      []
    end
  end

  defp list_live_views(_args) do
    views = SocketInspector.list_live_views()

    if Enum.empty?(views) do
      {:ok,
       "No LiveView processes found. Make sure your Phoenix app is running and has active LiveView connections."}
    else
      text =
        views
        # Connected root first — that's the one to drive / inspect.
        |> Enum.sort_by(fn v -> if v[:root] && v.connected, do: 0, else: 1 end)
        |> Enum.with_index(1)
        |> Enum.map(fn {view, i} ->
          keys_preview = Enum.take(view.assign_keys, 10) |> Enum.join(", ")

          more =
            if length(view.assign_keys) > 10,
              do: " (+#{length(view.assign_keys) - 10} more)",
              else: ""

          root_tag = if view[:root] && view.connected, do: "  ← connected root", else: ""

          """
          #{i}. #{view.view}#{root_tag}
             PID:       #{view.pid_string}
             Socket ID: #{view.id || "(none)"}
             URL:       #{view.url || "(none)"}
             Connected: #{view.connected}
             Root:      #{view[:root] == true}
             Assigns:   [#{keys_preview}#{more}]
          """
        end)
        |> Enum.join("\n")

      hint =
        "\nThe connected root (marked ←) is the live view on screen — pass its PID to " <>
          "get_assigns / get_scope / expect_assign. After an act_as reload, prior roots " <>
          "may briefly linger; the connected root is the current one.\n"

      {:ok, "Found #{length(views)} LiveView process(es):\n#{hint}\n#{text}"}
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

  defp get_scope(%{"pid" => pid}) do
    case ScopeInspector.get_scope(pid) do
      {:ok, scope} -> {:ok, Jason.encode!(scope, pretty: true)}
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp get_scope(_), do: {:error, :invalid_arguments}

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

  defp expect_assign(%{"pid" => pid, "key" => key} = args)
       when is_binary(pid) and is_binary(key) do
    case build_assign_matcher(args) do
      {:ok, matcher} ->
        timeout = normalize_expect_timeout(Map.get(args, "timeout_ms", 0))
        poll_expect_assign(pid, key, matcher, timeout, System.monotonic_time(:millisecond))

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp expect_assign(_),
    do:
      {:error,
       "expect_assign requires 'pid' and 'key' (strings) plus one of 'equals' or 'matches'"}

  defp build_assign_matcher(args) do
    cond do
      Map.has_key?(args, "equals") ->
        {:ok, {:equals, Map.get(args, "equals")}}

      Map.has_key?(args, "matches") ->
        case Map.get(args, "matches") do
          p when is_binary(p) -> {:ok, {:matches, p}}
          _ -> {:error, "'matches' must be a string (regex or substring)"}
        end

      true ->
        {:error, "expect_assign requires one of 'equals' or 'matches'"}
    end
  end

  defp normalize_expect_timeout(ms) when is_integer(ms) and ms > 0, do: min(ms, 30_000)
  defp normalize_expect_timeout(_), do: 0

  defp poll_expect_assign(pid, key, matcher, timeout, t0) do
    case SocketInspector.get_assigns(pid) do
      {:ok, assigns} ->
        {actual, found?} =
          case LiveAgent.KeyPath.get(assigns, key) do
            {:ok, value} -> {value, true}
            :not_found -> {nil, false}
          end

        pass? = found? and match_assign?(matcher, actual)
        elapsed = System.monotonic_time(:millisecond) - t0

        cond do
          pass? ->
            {:ok, expect_assign_verdict(true, key, matcher, actual, found?, elapsed)}

          elapsed >= timeout ->
            {:ok, expect_assign_verdict(false, key, matcher, actual, found?, elapsed)}

          true ->
            Process.sleep(100)
            poll_expect_assign(pid, key, matcher, timeout, t0)
        end

      {:error, reason} ->
        {:error,
         "Failed to read assigns for #{pid}: #{inspect(reason)} — call list_live_views to confirm the pid."}
    end
  end

  defp match_assign?({:equals, expected}, actual) do
    actual === expected or stringify_assign(actual) == stringify_assign(expected)
  end

  defp match_assign?({:matches, pattern}, actual) do
    subject = stringify_assign(actual)

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, subject)
      _ -> String.contains?(subject, pattern)
    end
  end

  defp stringify_assign(v) when is_binary(v), do: v
  defp stringify_assign(nil), do: ""
  defp stringify_assign(v) when is_number(v) or is_boolean(v) or is_atom(v), do: to_string(v)
  defp stringify_assign(v), do: Jason.encode!(v)

  defp expect_assign_verdict(pass?, key, matcher, actual, found?, elapsed) do
    expected =
      case matcher do
        {:equals, v} -> %{equals: v}
        {:matches, p} -> %{matches: p}
      end

    verdict = %{
      pass: pass?,
      path: key,
      expected: expected,
      actual: if(found?, do: actual, else: nil),
      waited_ms: elapsed
    }

    verdict =
      if found?, do: verdict, else: Map.put(verdict, :note, "key path not found in assigns")

    Jason.encode!(verdict, pretty: true)
  end

  defp expect_no_errors(args) when is_map(args) do
    since_id = Map.get(args, "since_id", 0)
    errors = LiveAgent.ErrorStore.get_errors(since_id)

    verdict = %{
      pass: errors == [],
      count: length(errors),
      errors: errors
    }

    {:ok, Jason.encode!(verdict, pretty: true)}
  end

  # ── Console capture ───────────────────────────────────────────────────────

  defp get_browser_logs(args) when is_map(args) do
    since_id = Map.get(args, "since_id", 0)
    limit = Map.get(args, "limit", 100) |> min(500) |> max(1)
    levels = Map.get(args, "levels", :all) |> normalize_levels()

    logs = LiveAgent.ConsoleLogStore.get_logs(since_id: since_id, levels: levels, limit: limit)

    if Enum.empty?(logs) do
      suffix =
        cond do
          since_id > 0 -> " since id #{since_id}"
          levels != :all -> " at levels #{inspect(levels)}"
          true -> ""
        end

      {:ok, "No browser console entries#{suffix}."}
    else
      counts = Enum.frequencies_by(logs, & &1.level)
      counts_text = Enum.map_join(counts, ", ", fn {lvl, n} -> "#{lvl}: #{n}" end)
      header =
        "#{length(logs)} console entr(ies). Latest id: #{hd(logs).id}. Levels — #{counts_text}.\n"

      body = logs |> Enum.map(&format_console_entry/1) |> Enum.join("\n")
      {:ok, header <> body}
    end
  end

  defp clear_browser_logs(_args) do
    LiveAgent.ConsoleLogStore.clear()
    {:ok, "Browser console log cleared."}
  end

  # ── Route inspection ──────────────────────────────────────────────────────

  defp list_lv_routes(args) when is_map(args) do
    router_filter = Map.get(args, "router")
    path_prefix = Map.get(args, "path_prefix")

    routes =
      LiveAgent.RouteInspector.list_live_routes()
      |> filter_by_router(router_filter)
      |> filter_by_path(path_prefix)

    if Enum.empty?(routes) do
      {:ok, "No LiveView routes found#{describe_filters(router_filter, path_prefix)}."}
    else
      grouped = Enum.group_by(routes, & &1.router)

      sections =
        grouped
        |> Enum.sort_by(fn {router, _} -> router end)
        |> Enum.map(fn {router, rs} ->
          rows = Enum.map(rs, &format_route_row/1) |> Enum.join("\n")
          "── #{router} (#{length(rs)} route#{if length(rs) == 1, do: "", else: "s"}) ──\n#{rows}"
        end)
        |> Enum.join("\n\n")

      header = "Found #{length(routes)} LiveView route(s) across #{map_size(grouped)} router(s).\n"
      {:ok, header <> sections}
    end
  end

  defp filter_by_router(routes, nil), do: routes
  defp filter_by_router(routes, ""), do: routes
  defp filter_by_router(routes, sub), do: Enum.filter(routes, &String.contains?(&1.router, sub))

  defp filter_by_path(routes, nil), do: routes
  defp filter_by_path(routes, ""), do: routes
  defp filter_by_path(routes, prefix), do: Enum.filter(routes, &String.starts_with?(&1.path, prefix))

  defp describe_filters(nil, nil), do: ""
  defp describe_filters(r, nil), do: " (router contains #{inspect(r)})"
  defp describe_filters(nil, p), do: " (path starts with #{inspect(p)})"
  defp describe_filters(r, p), do: " (router contains #{inspect(r)}, path starts with #{inspect(p)})"

  defp format_route_row(r) do
    session = if r.live_session, do: " [session: #{r.live_session}]", else: ""
    "  #{String.pad_trailing(r.path, 32)} → #{r.module} (:#{r.live_action})#{session}"
  end

  # ── Oban introspection (opt-in) ───────────────────────────────────────────

  defp list_oban_jobs(args) when is_map(args) do
    opts = [
      state: Map.get(args, "state"),
      queue: Map.get(args, "queue"),
      worker: Map.get(args, "worker"),
      limit: Map.get(args, "limit")
    ]

    case LiveAgent.ObanInspector.list_jobs(opts) do
      {:ok, []} ->
        {:ok, "No Oban jobs matched#{describe_oban_filters(opts)}."}

      {:ok, jobs} ->
        by_state = Enum.frequencies_by(jobs, & &1["state"])
        counts = Enum.map_join(by_state, ", ", fn {s, n} -> "#{s}: #{n}" end)
        header = "#{length(jobs)} oban job(s). By state — #{counts}.\n"
        body = jobs |> Enum.map(&format_oban_row/1) |> Enum.join("\n")
        {:ok, header <> body}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp get_oban_job(%{"id" => id}) when is_integer(id) do
    case LiveAgent.ObanInspector.get_job(id) do
      {:ok, job} -> {:ok, format_oban_job_detail(job)}
      {:error, msg} -> {:error, msg}
    end
  end

  defp get_oban_job(_), do: {:error, "id is required and must be an integer"}

  defp retry_oban_job(%{"id" => id}) when is_integer(id) do
    case LiveAgent.ObanInspector.retry_job(id) do
      :ok -> {:ok, "Job #{id} moved back to available."}
      {:error, msg} -> {:error, msg}
    end
  end

  defp retry_oban_job(_), do: {:error, "id is required and must be an integer"}

  defp describe_oban_filters(opts) do
    parts =
      opts
      |> Enum.filter(fn {_k, v} -> v not in [nil, ""] end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    case parts do
      [] -> ""
      ps -> " (filters: #{Enum.join(ps, ", ")})"
    end
  end

  defp format_oban_row(j) do
    attempts = "#{j["attempt"]}/#{j["max_attempts"]}"
    sched = j["scheduled_at"] || j["inserted_at"] || "-"
    "  [#{j["id"]}] #{String.pad_trailing(j["state"], 10)} #{String.pad_trailing(j["queue"], 14)} #{j["worker"]} (#{attempts}) sched=#{sched}"
  end

  defp format_oban_job_detail(j) do
    errors = j["errors"] || []

    error_section =
      case errors do
        [] -> "  errors:    (none)"
        _ ->
          formatted =
            errors
            |> Enum.with_index(1)
            |> Enum.map(fn {e, i} ->
              attempt = Map.get(e, "attempt") || Map.get(e, :attempt)
              at = Map.get(e, "at") || Map.get(e, :at)
              err = Map.get(e, "error") || Map.get(e, :error)
              "    ##{i} attempt=#{attempt} at=#{at}\n      #{truncate(to_string(err), 600)}"
            end)
            |> Enum.join("\n")

          "  errors:\n#{formatted}"
      end

    """
    Oban job ##{j["id"]}
      state:     #{j["state"]}
      queue:     #{j["queue"]}
      worker:    #{j["worker"]}
      attempt:   #{j["attempt"]}/#{j["max_attempts"]}
      priority:  #{j["priority"]}
      sched_at:  #{j["scheduled_at"]}
      attempted: #{j["attempted_at"] || "-"}
      completed: #{j["completed_at"] || "-"}
      discarded: #{j["discarded_at"] || "-"}
      cancelled: #{j["cancelled_at"] || "-"}
      tags:      #{inspect(j["tags"])}
      args:      #{truncate(inspect(j["args"]), 600)}
    #{error_section}
    """
  end

  defp truncate(str, n) when byte_size(str) > n, do: binary_part(str, 0, n) <> "…"
  defp truncate(str, _), do: str

  # ── PubSub introspection (opt-in) ─────────────────────────────────────────

  defp list_pubsub_topics(_args) do
    with {:ok, pubsub} <- resolve_pubsub() do
      case LiveAgent.PubSubInspector.list_topics(pubsub) do
        [] ->
          {:ok, "PubSub: #{inspect(pubsub)} — no topics with local subscribers."}

        rows ->
          body =
            rows
            |> Enum.map(fn {topic, count} ->
              "  #{String.pad_trailing(topic, 32)} #{count} sub(s)"
            end)
            |> Enum.join("\n")

          {:ok, "PubSub: #{inspect(pubsub)} — #{length(rows)} active topic(s).\n#{body}"}
      end
    end
  end

  defp tail_pubsub_topic(%{"topic" => topic} = args) when is_binary(topic) do
    with {:ok, pubsub} <- resolve_pubsub() do
      opts = [
        wait_ms: Map.get(args, "wait_ms"),
        max_n: Map.get(args, "max_n")
      ]

      case LiveAgent.PubSubInspector.tail_topic(pubsub, topic, opts) do
        {:ok, []} ->
          waited = opts[:wait_ms] || 5_000
          {:ok, "PubSub #{inspect(pubsub)} topic #{inspect(topic)} — no messages in #{waited}ms."}

        {:ok, msgs} ->
          body =
            msgs
            |> Enum.with_index(1)
            |> Enum.map(fn {m, i} -> "  ##{i} #{m.at}\n      #{m.payload}" end)
            |> Enum.join("\n")

          {:ok, "PubSub #{inspect(pubsub)} topic #{inspect(topic)} — captured #{length(msgs)} message(s).\n#{body}"}

        {:error, msg} ->
          {:error, msg}
      end
    end
  end

  defp tail_pubsub_topic(_), do: {:error, "topic is required and must be a string"}

  defp resolve_pubsub do
    case LiveAgent.Config.pubsub_tools() do
      :disabled ->
        {:error, "PubSub tools are not enabled. Add `pubsub_tools: true` (auto-discover) or `pubsub_tools: MyApp.PubSub` to your `plug LiveAgent, ...` config."}

      {:ok, :auto} ->
        LiveAgent.PubSubInspector.discover_pubsub()

      {:ok, name} when is_atom(name) ->
        {:ok, name}
    end
  end

  defp normalize_levels(:all), do: :all
  defp normalize_levels(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp normalize_levels(_), do: :all

  defp format_console_entry(e) do
    time = e.timestamp |> String.slice(11, 12)
    level = e.level |> String.upcase() |> String.pad_trailing(5)
    url = e.url || "-"
    "[#{e.id}] #{time} #{level} #{url}  #{e.message}"
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
    type = Map.get(args, "type", "click")

    with {:ok, pid} <- SocketInspector.parse_pid(pid_string),
         {:ok, topic, before_socket} <- SocketInspector.get_topic_and_socket(pid) do
      # Inject the same `"event"` message the JS client sends, rather than a
      # `GenServer.call({:run, fn})`. The latter is dispatched to the user's
      # `handle_event` callbacks fail clause `handle_call/3`, which a plain
      # LiveView doesn't define — so the call crashes before the handler runs.
      # A `Phoenix.Socket.Message` routes through the channel's full lifecycle
      # (telemetry, mount hooks, component dispatch) exactly like a real click.
      msg = %Phoenix.Socket.Message{
        topic: topic,
        event: "event",
        ref: nil,
        join_ref: nil,
        payload: %{"event" => event, "type" => type, "value" => params}
      }

      mref = Process.monitor(pid)
      send(pid, msg)

      # The channel drains its mailbox FIFO, so the `:sys.get_state` issued by
      # get_socket/1 (sent *after* our event, same process pair) only returns
      # once handle_event has finished — no arbitrary sleep needed.
      case SocketInspector.get_socket(pid) do
        {:ok, after_socket} ->
          Process.demonitor(mref, [:flush])
          diff = assigns_diff(before_socket, after_socket)
          format_send_event_result(event, diff)

        {:error, _} ->
          receive do
            {:DOWN, ^mref, :process, ^pid, reason} ->
              {:error, "handle_event crashed the LiveView: #{inspect(reason)}"}
          after
            0 ->
              Process.demonitor(mref, [:flush])
              {:error, "LiveView process no longer alive."}
          end
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
    case LiveAgent.BrowserStateStore.get_pinned_contexts() do
      [] ->
        {:ok,
         "No context pinned. Ask the user to select an element in the LiveAgent panel and click 'Pin to Claude Context'."}

      contexts ->
        {:ok, Jason.encode!(contexts, pretty: true)}
    end
  end

  defp get_panel_status(_args) do
    {:ok, LiveAgent.PanelStatus.snapshot() |> Jason.encode!(pretty: true)}
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
    payload = capture_payload(args)

    case LiveAgent.CommandQueue.enqueue_and_await("screenshot", payload,
           timeout_ms: 30_000,
           wait_ready_ms: 6_000
         ) do
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
        {:error, panel_timeout_message()}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp format_screenshot_text(path, result) do
    w = Map.get(result, "width")
    h = Map.get(result, "height")
    dims = if w && h, do: " (#{w}×#{h})", else: ""
    "Screenshot saved to #{path}#{dims}#{format_capture_rect(result)}"
  end

  defp format_capture_rect(%{"rect" => %{} = rect}) do
    "\nClipped to region: #{Jason.encode!(rect)}"
  end

  defp format_capture_rect(_), do: ""

  # Builds the browser capture payload from cid / selector / text args. Shared
  # by take_screenshot, screenshot_baseline, and screenshot_diff so all three
  # clip identically. Omitting all three captures the full page.
  defp capture_payload(args) do
    ["selector", "cid", "text"]
    |> Enum.reduce(%{}, fn k, acc ->
      case Map.get(args, k) do
        nil -> acc
        v -> Map.put(acc, String.to_atom(k), v)
      end
    end)
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

  defp screenshot_baseline(%{"name" => name} = args) when is_binary(name) do
    case LiveAgent.BaselineStore.validate_name(name) do
      {:ok, _} ->
        payload = capture_payload(args)

        case LiveAgent.CommandQueue.enqueue_and_await("screenshot", payload,
               timeout_ms: 30_000,
               wait_ready_ms: 6_000
             ) do
          {:ok, %{"ok" => true, "base64" => base64} = result} ->
            store_baseline(name, base64, result)

          {:ok, %{"ok" => false, "error" => err}} ->
            {:error, "browser: " <> to_string(err)}

          {:error, :timeout} ->
            {:error, panel_timeout_message()}

          {:error, reason} ->
            {:error, inspect(reason)}
        end

      {:error, msg} ->
        {:error, "invalid baseline name: #{msg}"}
    end
  end

  defp screenshot_baseline(_), do: {:error, "screenshot_baseline requires 'name' (string)"}

  defp store_baseline(name, base64, result) do
    case Base.decode64(base64) do
      {:ok, bytes} ->
        case LiveAgent.BaselineStore.put(name, bytes) do
          {:ok, path} ->
            w = Map.get(result, "width")
            h = Map.get(result, "height")
            dims = if w && h, do: " (#{w}×#{h})", else: ""
            {:ok, "Baseline #{inspect(name)} saved to #{path}#{dims}#{format_capture_rect(result)}"}

          {:error, reason} ->
            {:error, "failed to save baseline: #{inspect(reason)}"}
        end

      :error ->
        {:error, "screenshot base64 decode failed"}
    end
  end

  defp screenshot_diff(%{"name" => name} = args) when is_binary(name) do
    with {:ok, _} <- LiveAgent.BaselineStore.validate_name(name),
         {:ok, baseline_bytes} <- fetch_baseline(name) do
      payload =
        args
        |> capture_payload()
        |> Map.put(:baseline_png, Base.encode64(baseline_bytes))
        |> Map.put(:threshold, Map.get(args, "threshold", 0.1))
        |> Map.put(:include_aa, Map.get(args, "include_aa", false))

      case LiveAgent.CommandQueue.enqueue_and_await("screenshot_diff", payload,
             timeout_ms: 30_000,
             wait_ready_ms: 6_000
           ) do
        {:ok, %{"ok" => true} = result} ->
          format_diff_result(name, result)

        {:ok, %{"ok" => false, "error" => err}} ->
          {:error, "browser: " <> to_string(err)}

        {:error, :timeout} ->
          {:error, panel_timeout_message()}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    else
      {:error, :not_found} ->
        {:error,
         "No baseline named #{inspect(name)}. Capture one first with " <>
           "screenshot_baseline(name: #{inspect(name)})."}

      {:error, msg} when is_binary(msg) ->
        {:error, "invalid baseline name: #{msg}"}

      {:error, reason} ->
        {:error, "failed to read baseline: #{inspect(reason)}"}
    end
  end

  defp screenshot_diff(_), do: {:error, "screenshot_diff requires 'name' (string)"}

  defp fetch_baseline(name), do: LiveAgent.BaselineStore.get(name)

  # Dimensions diverged → the page reflowed; a pixel diff would be meaningless,
  # so report both sizes instead of a bogus ratio.
  defp format_diff_result(name, %{"dims_match" => false} = result) do
    baseline = Map.get(result, "baseline_size")
    current = Map.get(result, "current_size")

    summary = %{
      name: name,
      dims_match?: false,
      baseline_size: baseline,
      current_size: current,
      baseline_path: relative_path(LiveAgent.BaselineStore.baseline_path(name))
    }

    {:ok,
     "Dimensions differ — the page reflowed, so no pixel ratio was computed.\n" <>
       Jason.encode!(summary, pretty: true)}
  end

  defp format_diff_result(name, %{"diff_png" => diff_base64} = result) do
    case Base.decode64(diff_base64 || "") do
      {:ok, bytes} ->
        diff_path =
          case LiveAgent.BaselineStore.put_diff(name, bytes) do
            {:ok, path} -> relative_path(path)
            _ -> nil
          end

        summary = %{
          name: name,
          changed_ratio: Map.get(result, "changed_ratio"),
          changed_boxes: Map.get(result, "changed_boxes", []),
          dims_match?: true,
          width: Map.get(result, "width"),
          height: Map.get(result, "height"),
          overlay_path: diff_path,
          baseline_path: relative_path(LiveAgent.BaselineStore.baseline_path(name))
        }

        {:ok, Jason.encode!(summary, pretty: true)}

      :error ->
        {:error, "diff image base64 decode failed"}
    end
  end

  defp format_diff_result(_name, result),
    do: {:error, "unexpected diff result: #{Jason.encode!(result)}"}

  # Paths are shown relative to cwd (the project root) when possible — shorter
  # and directly openable by the user/Read tool.
  defp relative_path(abs) do
    cwd = File.cwd!()
    if String.starts_with?(abs, cwd <> "/"), do: Path.relative_to(abs, cwd), else: abs
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
    mode = resolve_navigate_mode(Map.get(args, "mode"), path)
    payload = %{"path" => path, "mode" => mode}
    dispatch_drive_command("navigate", payload, &format_drive_result(&1, "Navigated"))
  end

  defp navigate(_), do: {:error, "navigate requires 'path' (string)"}

  defp resolve_navigate_mode(nil, path), do: resolve_navigate_mode("auto", path)
  defp resolve_navigate_mode("auto", path), do: LiveAgent.SocketInspector.resolve_navigation_mode(path)
  defp resolve_navigate_mode(explicit, _path) when is_binary(explicit), do: explicit

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

  defp act_as(%{"identifier" => identifier}) when is_binary(identifier) and identifier != "" do
    with :ok <- act_as_available() do
      # Snapshot current LV pids so we can recognise the *fresh* socket that
      # appears after the panel reloads and reconnects as the new actor.
      old_pids = current_lv_pid_set()

      case LiveAgent.CommandQueue.enqueue_and_await("act_as", %{identifier: identifier},
             timeout_ms: 15_000
           ) do
        {:ok, %{"ok" => true} = result} ->
          {:ok, format_act_as(identifier, Map.get(result, "who"), await_new_scope(old_pids, 6_000))}

        {:ok, %{"ok" => false, "error" => err}} ->
          {:error, "browser: " <> to_string(err)}

        {:error, :timeout} ->
          {:error, panel_timeout_message()}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  defp act_as(_), do: {:error, "act_as requires 'identifier' (a non-empty string)"}

  # Mirrors the route's gate so Claude gets the precise setup error before we
  # ever drive the browser. The env check is an `if` (not a `cond` clause) so the
  # compile-time-constant `act_as_enabled?/0` doesn't read as a dead clause.
  defp act_as_available do
    if LiveAgent.Config.act_as_enabled?() do
      act_as_config_available()
    else
      {:error, "act_as is available only in :dev/:test builds."}
    end
  end

  defp act_as_config_available do
    cond do
      match?({:error, _}, LiveAgent.Config.act_as_fun()) ->
        {:error,
         "act_as is not configured. In config/dev.exs set " <>
           "`config :live_agent, act_as: &MyAppWeb.DevActAs.sign_in/2` (a 2-arity closure)."}

      match?({:error, _}, LiveAgent.Config.session_options()) ->
        {:error,
         "act_as needs `:session_options` too — copy it VERBATIM from your endpoint's " <>
           "@session_options (config :live_agent, session_options: [...]). A salt mismatch " <>
           "silently fails to authenticate after reload."}

      true ->
        :ok
    end
  end

  defp current_lv_pid_set do
    SocketInspector.list_live_views() |> Enum.map(& &1.pid_string) |> MapSet.new()
  end

  # After the reload, the old LV channel dies and a fresh connected one appears.
  # Poll for a connected LV whose pid wasn't present before, then read its scope.
  defp await_new_scope(old_pids, timeout) do
    await_new_scope(old_pids, timeout, System.monotonic_time(:millisecond))
  end

  defp await_new_scope(old_pids, timeout, t0) do
    # Prefer the fresh *connected root* (parent_pid nil); fall back to any fresh
    # connected LV so a child-only page still resolves.
    candidates =
      SocketInspector.list_live_views()
      |> Enum.filter(fn lv -> lv.connected and not MapSet.member?(old_pids, lv.pid_string) end)

    fresh = Enum.find(candidates, & &1[:root]) || List.first(candidates)

    cond do
      fresh != nil ->
        case LiveAgent.ScopeInspector.get_scope(fresh.pid_string) do
          {:ok, scope} -> {:ok, fresh.pid_string, scope}
          _ -> {:unreadable, fresh.pid_string}
        end

      System.monotonic_time(:millisecond) - t0 >= timeout ->
        :timeout

      true ->
        Process.sleep(200)
        await_new_scope(old_pids, timeout, t0)
    end
  end

  defp format_act_as(identifier, who, scope_result) do
    header = "Acting as: #{who || identifier}"

    body =
      case scope_result do
        {:ok, pid, scope} ->
          "\n\nActive LiveView pid: #{pid}  (pass this to get_assigns / get_scope / expect_assign)" <>
            "\n\nReconnected scope:\n" <> Jason.encode!(scope, pretty: true)

        {:unreadable, pid} ->
          "\n\nActive LiveView pid: #{pid}  (scope read failed — call get_scope #{pid} to verify)"

        :timeout ->
          "\n\n(Reconnect not confirmed within 6s — call list_live_views and use the " <>
            "connected root, or check that the panel reloaded.)"
      end

    header <> body
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

    case LiveAgent.CommandQueue.enqueue_and_await(op, args, []) do
      {:ok, %{"ok" => true} = result} ->
        after_snap = snapshot_all_live_views()
        diff = diff_live_view_snapshots(before_snap, after_snap)
        {:ok, formatter.(Map.put(result, "server_diff", diff))}

      {:ok, %{"ok" => false, "error" => err}} ->
        {:error, "browser: " <> to_string(err)}

      {:error, :timeout} ->
        {:error, panel_timeout_message()}

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

    case LiveAgent.CommandQueue.enqueue_and_await(op, args, timeout_ms: timeout) do
      {:ok, %{"ok" => true} = result} ->
        {:ok, formatter.(result)}

      {:ok, %{"ok" => false, "error" => err}} ->
        {:error, "browser: " <> to_string(err)}

      {:error, :timeout} ->
        {:error, panel_timeout_message()}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Shared diagnostic message for the three browser-bound dispatch paths.
  # Pulls the latest PanelStatus snapshot so callers see *why* the round-trip
  # failed (no panel ever opened? panel parked but page mid-reload?) instead
  # of the old generic "open the panel" prompt.
  defp panel_timeout_message do
    snap = LiveAgent.PanelStatus.snapshot()

    base =
      "LiveAgent panel did not respond in time. " <>
        "Open the panel in a browser tab and retry, or call get_panel_status to diagnose."

    case snap do
      %{last_seen_age_ms: nil} ->
        base <> " (No panel has ever reported in — is the host page loaded?)"

      %{ready: true} ->
        base <> " (Panel is connected but the command itself timed out.)"

      %{reason: reason, last_seen_age_ms: age} when is_binary(reason) ->
        base <> " (Panel last seen #{age}ms ago: #{reason}.)"

      %{last_seen_age_ms: age} ->
        base <> " (Panel last seen #{age}ms ago.)"
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
