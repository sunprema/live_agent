# LiveAgent

An MCP (Model Context Protocol) server for Phoenix LiveView that exposes your socket assigns to AI coding tools like **Claude Code**.
Think of it as `live_debugger` but as an MCP server — giving Claude Code live read access to what's currently rendered on your screen.

We will be building the tools that will integrate with tidewave_phoenix and register new tools with it using Tidewave.Plugin.register_tool

---

## What it does

Claude Code can call these MCP tools while you work:

| Tool | Description |
|------|-------------|
| `list_live_views` | Lists all active LiveView processes (PID, view module, assign keys) |
| `get_assigns` | Returns the full assigns map for a LiveView — the live data on screen |
| `get_assign` | Returns a single assign value by key |
| `get_socket_info` | Returns full socket metadata (view, IDs, transport, assigns) |
| `watch_assigns` | Snapshot assigns at this moment (call repeatedly to track changes) |
