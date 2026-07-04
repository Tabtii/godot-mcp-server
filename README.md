# Godot MCP Server

A standalone Model Context Protocol (MCP) bridge for Godot 4.x.

Lets Claude inspect and manipulate the Godot editor scene over a WebSocket connection.

## Quick Start

1. Install Godot 4.x.
2. Install Python dependencies:
   ```bash
   cd mcp_server
   pip install -r requirements.txt
   ```
3. Copy `godot_addon/` into your Godot project's `addons/godot_mcp/` folder.
4. Enable the plugin in **Project → Project Settings → Plugins**.
5. Start the server from the Godot tool menu: **Godot MCP: Start Server**.
6. Add the MCP server to Claude Desktop using `claude_desktop_config.json`.
7. Ask Claude to create or inspect nodes in Godot.

## Project Structure

```
godot-mcp-server/
├── mcp_server/
│   ├── server.py           # Python MCP server (stdio → WebSocket)
│   └── requirements.txt
├── godot_addon/
│   ├── plugin.cfg          # Godot plugin metadata
│   └── godot_mcp.gd        # Godot editor plugin
├── docs/
│   └── setup.md            # Detailed setup instructions
├── claude_desktop_config.json
└── README.md
```

## Security

The `execute_gdscript` tool is disabled by default. Enable it only from the Godot tool menu when you need arbitrary script execution.

## License

MIT
