# LiveAgent

An MCP (Model Context Protocol) server plug for Phoenix LiveView that exposes your socket assigns and browser context to AI coding tools like **Claude Code**.

Think of it as `live_debugger` but as an MCP server — giving Claude Code live read access to what's currently rendered on your screen, including a built-in browser panel for picking elements and sharing context.

---

## What it does

### In-browser panel

LiveAgent auto-injects a **bottom panel** into every page of your app (dev only). Click the **⚡ LA** button in the bottom-right corner to open it.

The panel has three tabs:

| Tab           | What it shows                                                      |
| ------------- | ------------------------------------------------------------------ |
| **LiveViews** | All active LiveView processes — click `▶` to expand assigns inline |
| **Selected**  | The DOM element you picked with the element picker                 |
| **Context**   | The element you pinned for Claude to read                          |

**Element picker** — click **🔍 Pick**, then click any element on the page. LiveAgent captures its HTML, CSS classes, Phoenix attributes (`phx-click`, `data-phx-component`, etc.), and parent chain. Click **📋 Pin to Claude Context** to make it available to Claude via MCP.

### MCP tools

Claude Code can call these tools while you work:

| Tool                   | Description                                                           |
| ---------------------- | --------------------------------------------------------------------- |
| `list_live_views`      | Lists all active LiveView processes (PID, view module, assign keys)   |
| `get_assigns`          | Returns the full assigns map for a LiveView — the live data on screen |
| `get_assign`           | Returns a single assign value by key                                  |
| `get_socket_info`      | Returns full socket metadata (view, IDs, transport, assigns)          |
| `watch_assigns`        | Snapshot assigns at this moment (call repeatedly to track changes)    |
| `get_selected_element` | Returns the element most recently picked in the browser panel         |
| `get_pinned_context`   | Returns the element the user explicitly pinned for Claude             |

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

For assigns inspection it uses the same technique as [`live_debugger`](https://github.com/software-mansion/live_debugger):

1. Scans all BEAM processes for those started by `Phoenix.LiveView.Channel`
2. Uses `:sys.get_state/1` to read the GenServer state from the channel process
3. Extracts the `%Phoenix.LiveView.Socket{}` and its `assigns` map
4. Sanitizes assigns to be JSON-encodable (handles PIDs, structs, atoms, etc.)

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
