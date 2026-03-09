# LiveAgent

An MCP (Model Context Protocol) server plug for Phoenix LiveView that exposes your socket assigns and browser context to AI coding tools like **Claude Code**.

Think of it as `live_debugger` but as an MCP server — giving Claude Code live read access to what's currently rendered on your screen, including a built-in browser panel for picking elements and sharing context.

---

## Screenshots

**Inline panel** — docked to the bottom of your app, showing active LiveViews and their assigns:

![LiveAgent inline panel](screenshots/live_agent_inline_view.png)

**Standalone view** — open in a new tab with multiple panels visible at once (LiveViews, Resources, and Events side by side):

![LiveAgent standalone split view](screenshots/live_agent_new_tab_view.png)

---

## What it does

### In-browser panel

LiveAgent auto-injects a **bottom panel** into every page of your app (dev only). Click the **⚡ LA** button in the bottom-right corner to open it.

The panel has five panels, each toggled independently from the launcher bar — open as many as you want side by side:

| Panel         | What it shows                                                                  |
| ------------- | ------------------------------------------------------------------------------ |
| **LiveViews** | All active LiveView processes — click `▶` to expand assigns inline             |
| **Selected**  | The DOM element you picked with the element picker, with component resolution  |
| **Context**   | The element you pinned for Claude to read                                      |
| **Events**    | Live log of `handle_event`, `mount`, `handle_params`, and `handle_info` calls  |
| **Resources** | All Ash resources — click `▶` to expand attributes, actions, and relationships |

Click any panel button in the top bar to open or close it. Drag the divider between open panels to resize them. Click **↗** to open the whole panel in a new tab.

**Element picker** — click **🔍 Pick**, then click any element on the page. LiveAgent captures its HTML, CSS classes, and Phoenix attributes (`phx-click`, `data-phx-component`, etc.). If the element belongs to a LiveComponent, the **Selected** panel automatically shows the component module, its `id`, and its current assign keys — resolved directly from the running BEAM process. Click **📋 Pin to Claude Context** to make it available to Claude via MCP.

**Resources tab** — lists every Ash resource loaded in the running app. Click `▶` on any resource to expand a full breakdown: attributes with types and constraints, actions with their accepted fields and arguments, relationships with destination resources, and any calculations or aggregates. Loaded once when the tab is first opened. Requires Ash to be installed — the tab is still shown but displays a message if Ash is not available.

**Events tab** — shows a scrolling log of LiveView telemetry events as they happen. Each row displays the event type, event name (for `handle_event`), the LiveView or LiveComponent that handled it, duration, and how long ago it occurred. Click any row to expand the params or error details. Duration is color-coded: green under 10ms, amber 10–100ms, red over 100ms. Exceptions are highlighted in red. The log holds the last 200 events and can be cleared with the Clear button.

### MCP tools

Claude Code can call these tools while you work:

| Tool                    | Description                                                                     |
| ----------------------- | ------------------------------------------------------------------------------- |
| `list_live_views`       | Lists all active LiveView processes (PID, view module, assign keys)             |
| `get_assigns`           | Returns the full assigns map for a LiveView — the live data on screen           |
| `get_assign`            | Returns a single assign value by key                                            |
| `get_socket_info`       | Returns full socket metadata (view, IDs, transport, assigns)                    |
| `watch_assigns`         | Snapshot assigns at this moment (call repeatedly to track changes)              |
| `get_selected_element`  | Returns the element most recently picked in the browser panel                   |
| `get_pinned_context`    | Returns the element the user explicitly pinned for Claude                       |
| `get_component_tree`    | LiveComponent tree for the current page — modules, ids, assign keys, and events |
| `list_ash_resources`    | Lists all Ash resources with attributes, actions, and relationships (Ash only)  |
| `get_ash_resource_info` | Full introspection of a single Ash resource — types, constraints, actions, etc. |

---

## Installation

Add to your Phoenix app's deps in `mix.exs`:

```elixir
defp deps do
  [
    {:live_agent, "~> 0.1", only: :dev}
  ]
end
```

Then fetch deps:

```bash
mix deps.get
```

---

## Setup

### 1. Add the plug to your endpoint

In `lib/my_app_web/endpoint.ex`, add `plug LiveAgent` **before** the `if code_reloading?` block:

```elixir
if Code.ensure_loaded?(LiveAgent) do
  plug LiveAgent
end

if code_reloading? do
  plug Phoenix.CodeReloader
  # ...
end
```

### 2. Configure Claude Code

Add LiveAgent as an MCP server in your project's `.mcp.json`. If you're also using Tidewave, add it alongside:

```json
{
  "mcpServers": {
    "tidewave": {
      "type": "http",
      "url": "http://localhost:4000/tidewave/mcp"
    },
    "live-agent": {
      "type": "http",
      "url": "http://localhost:4000/live_agent/mcp"
    }
  }
}
```

### 3. Start your Phoenix app

```bash
mix phx.server
```

Claude Code will connect to LiveAgent over HTTP while your app is running. No separate process needed.

---

## How it works

`LiveAgent` is a `Plug` that:

- Mounts an MCP server at `/live_agent/mcp` for Claude Code to connect to
- Auto-injects the browser panel into every HTML response (dev only)
- Exposes a small JSON API at `/live_agent/api/*` for the panel to call
- Runs a `BrowserStateStore` GenServer to hold the current selected element and pinned context
- Runs an `EventStore` GenServer that subscribes to Phoenix's built-in telemetry events and keeps a ring buffer of the last 200

For assigns inspection it uses the same technique as [`live_debugger`](https://github.com/software-mansion/live_debugger):

1. Scans all BEAM processes for those started by `Phoenix.LiveView.Channel`
2. Uses `:sys.get_state/1` to read the GenServer state from the channel process
3. Extracts the `%Phoenix.LiveView.Socket{}` and its `assigns` map
4. Sanitizes assigns to be JSON-encodable (handles PIDs, structs, atoms, etc.)

For component resolution (element picker and `get_component_tree`), LiveAgent reads the channel's internal `components` map (a `{cid_to_component, id_to_cid, uuids}` tuple) to look up a component integer CID and return the module name, `id`, and assign keys.

For the component tree, the HTML response flowing through the Plug is regex-scanned in the same `register_before_send` pass used for panel injection. Each `data-phx-component="N"` element is captured with its DOM id and all `phx-*` event bindings, then stored in `ComponentTreeStore` keyed by `view_id` (`phx-FgX2...`).

No instrumentation required in your LiveViews — it works with any existing Phoenix app.

---

## Usage with Claude Code

### Via the browser panel (recommended)

1. Open your app in the browser
2. Click **⚡ LA** (bottom-right) to open the panel
3. Click **🔍 Pick** and select any element on the page
4. Click **📋 Pin to Claude Context**
5. Ask Claude: _"Add a Status column to this table"_

Claude calls `get_pinned_context`, gets the element's HTML and Phoenix metadata, finds the `.heex` template, and makes the change.

### Via the Events tab

The Events tab is useful when you can't figure out why state isn't updating as expected:

1. Open the panel and switch to **Events**
2. Interact with the page — click a button, submit a form, navigate
3. Watch the event log to confirm your `handle_event` is firing, check params, and see duration
4. If an event shows red, click it to expand the exception details
5. Ask Claude: _"The save-form event is firing but the user isn't being updated — here's the event log"_

No instrumentation needed — LiveAgent hooks into the telemetry events Phoenix already emits.

The following event types are captured:

| Badge    | Telemetry event                              |
| -------- | -------------------------------------------- |
| `event`  | `handle_event` on LiveView and LiveComponent |
| `mount`  | `mount` on LiveView                          |
| `params` | `handle_params` on LiveView                  |
| `info`   | `handle_info` on LiveView                    |
| `error`  | Any of the above that raises an exception    |

### With Ash Framework

If your app uses [Ash](https://ash-hq.org), LiveAgent gives Claude direct access to your data model without it having to read source files.

**In the panel** — open the **Resources** tab to visually browse all your resources. Each resource expands to show:

| Section       | Details                                                                                   |
| ------------- | ----------------------------------------------------------------------------------------- |
| Attributes    | Name, type, PK badge, required/nil-ok, read-only flag                                     |
| Actions       | Name, type (color-coded), accepted attributes, arguments. Primary actions marked with `*` |
| Relationships | Name, type (`belongs_to`, `has_many`, etc.), destination resource                         |
| Calculations  | Names listed as chips                                                                     |
| Aggregates    | Name and kind listed as chips                                                             |

**Via MCP** — Claude can call these tools before writing any Ash code:

- _"What actions does MyApp.Accounts.User have?"_ → `list_ash_resources`
- _"Add a `:suspend` action to the User resource"_ → Claude calls `get_ash_resource_info` first to understand the existing structure, then makes the change
- _"What attributes does MyApp.Blog.Post accept on create?"_ → `get_ash_resource_info`

No configuration needed — LiveAgent scans all loaded BEAM modules at runtime to find Ash resources automatically.

### Via the component tree

`get_component_tree` gives Claude a structural map of the current page without reading source files:

- _"What LiveComponents are on this page?"_ → `get_component_tree`
- _"Add a `:loading` assign to the FormComponent"_ → Claude calls `get_component_tree` to find the module and its current assigns, then makes the change
- _"Why isn't my save-form event firing?"_ → `get_component_tree` shows which component handles that event and its current assign keys

The tree is parsed from the last HTML response LiveAgent intercepted. Navigate to the page you want to inspect first.

### Via assigns inspection

Ask Claude things like:

- _"What are the current assigns for the UserDashboardLive view?"_
- _"The user list on screen — what data is driving it?"_
- _"Watch the `:form` assign while I fill out this form"_
- _"What's the value of the `:current_user` assign?"_

Claude calls `list_live_views` to find the right process, then `get_assigns` to read the data.

---

## Options

`plug LiveAgent` accepts the following options:

| Option                | Default | Description                                                     |
| --------------------- | ------- | --------------------------------------------------------------- |
| `allow_remote_access` | `false` | Allow connections from non-localhost IPs. Leave `false` in dev. |

```elixir
plug LiveAgent, allow_remote_access: false
```

---

## Security

LiveAgent is **dev-only**. It gives read access to all socket assigns, which may include sensitive data (user IDs, session tokens, etc.). Do not add it to your production endpoint.

The plug is guarded by a localhost check by default — it will return `403` for any request not coming from `127.0.0.1` or `::1`.

---

## License

MIT
