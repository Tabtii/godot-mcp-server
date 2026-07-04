# Godot MCP Server — Setup

Dieses Projekt erlaubt es Claude, den Godot-Editor über das Model Context Protocol (MCP) zu steuern.

## Architektur

```
Claude Desktop / Claude Code
  → Python MCP server (stdio)
    → WebSocket client
      → Godot Editor plugin (WebSocket server + command dispatcher)
        → Godot Editor APIs
```

## 1. Voraussetzungen

- Godot 4.x (getestet mit 4.6.3)
- Python 3.10+
- `mcp` und `websockets` Python-Pakete

## 2. Python-Abhängigkeiten installieren

```bash
cd /home/torben/projects/godot-mcp-server/mcp_server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Oder systemweit:

```bash
pip install --user -r requirements.txt
```

## 3. Godot-Editor-Plugin installieren

1. Erstelle ein Godot-Projekt oder öffne ein bestehendes.
2. Kopiere den Ordner `godot_addon` nach `<dein_projekt>/addons/godot_mcp`.
3. Öffne Godot → **Projekt → Projekteinstellungen → Plugins**.
4. Aktiviere **Godot MCP Bridge**.
5. Starte den Server über das Tool-Menü:
   - **Godot MCP: Start Server**

Optional:
- **Godot MCP: Toggle Arbitrary GDScript** aktiviert das `execute_gdscript`-Tool.
- **Godot MCP: Stop Server** beendet den WebSocket-Server.

## 4. Claude Desktop konfigurieren

Füge den Inhalt aus `claude_desktop_config.json` in deine Claude Desktop-Konfiguration ein:

- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Linux:** `~/.config/Claude/claude_desktop_config.json`

Starte Claude Desktop neu.

## 5. Claude Code nutzen

Falls du Claude Code verwendest, kannst du den MCP-Server über `mcp` tools anbinden, sofern deine Umgebung MCP-Server unterstützt.

## 6. Verfügbare Tools

| Tool | Beschreibung |
|------|--------------|
| `list_nodes` | Listet alle Nodes der aktuellen Szene. |
| `get_node_info` | Details zu einem Node (Position, Rotation, Skala). |
| `create_primitive` | Erstellt Box, Sphere, Cylinder, Capsule oder Prism. |
| `delete_node` | Löscht einen Node. |
| `transform_node` | Verschiebt, dreht oder skaliert einen Node. |
| `save_scene` | Speichert die aktuelle Szene. |
| `run_project` | Startet das Projekt im Play-Modus. |
| `stop_project` | Stoppt den Play-Modus. |
| `export_project` | Platzhalter für Projekt-Export. |
| `execute_gdscript` | Führt beliebigen GDScript-Code aus (nur mit Opt-in). |

## 7. Beispiel-Dialog

**Benutzer:** "Erstelle eine rote Kugel in Godot."

Claude ruft auf:
```json
{
  "tool": "create_primitive",
  "arguments": {
    "type": "sphere",
    "name": "RedSphere",
    "location": [0, 0, 0],
    "size": 1.0,
    "color": [1.0, 0.0, 0.0, 1.0]
  }
}
```

In Godot erscheint ein roter `MeshInstance3D` in der Szene.

## 8. Fehlerbehebung

| Problem | Lösung |
|---------|--------|
| Verbindung fehlgeschlagen | Stelle sicher, dass der Godot-Server gestartet ist (Tool-Menü). |
| Port bereits belegt | Beende andere Server oder ändere `MCP_PORT` im Plugin und in `server.py`. |
| `execute_gdscript` fehlgeschlagen | Aktiviere es im Tool-Menü. |
| Plugin wird nicht geladen | Prüfe, ob der Ordner unter `addons/godot_mcp` liegt und `plugin.cfg` + `godot_mcp.gd` enthalten sind. |

## 9. Sicherheitshinweis

Das `execute_gdscript`-Tool ist absichtlich deaktiviert. Es kann beliebigen Code im Godot-Editor ausführen und sollte nur aktiviert werden, wenn du den Anfragen vertraust.
