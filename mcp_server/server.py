#!/usr/bin/env python3
"""
MCP-Server für Godot.
Baut eine Brücke zwischen dem MCP-Protokoll (STDIO) und einem WebSocket-Server,
der im Godot-Editor als Addon läuft.
"""

import asyncio
import json
import logging
import os
import sys
from contextlib import asynccontextmanager
from typing import AsyncIterator

import websockets
from mcp.server import Server
from mcp.server.lowlevel.server import NotificationOptions
from mcp.server.models import InitializationOptions
from mcp.server.stdio import stdio_server
from mcp.types import Resource, Tool, TextContent, ImageContent

logging.basicConfig(level=logging.INFO, stream=sys.stderr)
logger = logging.getLogger("godot-mcp")

GODOT_HOST = os.environ.get("GODOT_HOST", "localhost")
GODOT_PORT = int(os.environ.get("GODOT_PORT", "8406"))
GODOT_WS_URI = f"ws://{GODOT_HOST}:{GODOT_PORT}"


class GodotClient:
    def __init__(self) -> None:
        self.websocket = None
        self._lock = asyncio.Lock()

    async def ensure_connected(self) -> websockets.WebSocketClientProtocol:
        async with self._lock:
            if self.websocket is None or self.websocket.closed:
                logger.info(f"Verbinde mit Godot unter {GODOT_WS_URI}")
                self.websocket = await websockets.connect(
                    GODOT_WS_URI, ping_interval=20, ping_timeout=10
                )
        return self.websocket

    async def send(self, method: str, params: dict | None = None) -> dict:
        ws = await self.ensure_connected()
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": method,
            "params": params or {}
        }
        await ws.send(json.dumps(payload))
        raw = await asyncio.wait_for(ws.recv(), timeout=30.0)
        response = json.loads(raw)
        if "error" in response:
            raise RuntimeError(response["error"])
        return response.get("result", {})

    def _next_id(self) -> int:
        GodotClient._counter += 1
        return GodotClient._counter

    _counter = 0

    async def close(self) -> None:
        async with self._lock:
            if self.websocket and not self.websocket.closed:
                await self.websocket.close()
                self.websocket = None


godot_client = GodotClient()


@asynccontextmanager
async def app_lifespan(server: Server) -> AsyncIterator[None]:
    try:
        logger.info("Godot MCP Server gestartet")
        yield
    finally:
        await godot_client.close()
        logger.info("Godot MCP Server beendet")


server = Server("godot-mcp", lifespan=app_lifespan)


@server.list_resources()
async def list_resources() -> list[Resource]:
    scene = await godot_client.send("get_scene_info")
    objects = scene.get("nodes", [])
    resources = []
    for obj in objects:
        uri = f"godot://node/{obj['name']}"
        resources.append(Resource(uri=uri, name=obj["name"], mimeType="application/json"))
    return resources


@server.read_resource()
async def read_resource(uri: str) -> str:
    if not uri.startswith("godot://node/"):
        raise ValueError(f"Unbekannte Ressource: {uri}")
    name = uri.split("/")[-1]
    result = await godot_client.send("get_node_info", {"name": name})
    return json.dumps(result, indent=2)


@server.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="list_nodes",
            description="Listet alle Nodes der aktuellen Godot-Szene auf.",
            inputSchema={"type": "object", "properties": {}}
        ),
        Tool(
            name="get_node_info",
            description="Gibt Details zu einem Node zurück (Name, Typ, Position, etc.).",
            inputSchema={
                "type": "object",
                "required": ["name"],
                "properties": {
                    "name": {"type": "string"}
                }
            }
        ),
        Tool(
            name="create_primitive",
            description="Erstellt ein primitives 3D-Objekt in Godot (Box, Sphere, Cylinder, Capsule, Prism).",
            inputSchema={
                "type": "object",
                "required": ["type", "name"],
                "properties": {
                    "type": {"type": "string", "enum": ["box", "sphere", "cylinder", "capsule", "prism"]},
                    "name": {"type": "string"},
                    "location": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3, "default": [0, 0, 0]},
                    "size": {"type": "number", "default": 1.0},
                    "color": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 4, "default": [0.8, 0.8, 0.8, 1.0]}
                }
            }
        ),
        Tool(
            name="delete_node",
            description="Löscht einen Node aus der aktuellen Szene.",
            inputSchema={
                "type": "object",
                "required": ["name"],
                "properties": {
                    "name": {"type": "string"}
                }
            }
        ),
        Tool(
            name="transform_node",
            description="Verschiebt, dreht oder skaliert einen Node.",
            inputSchema={
                "type": "object",
                "required": ["name"],
                "properties": {
                    "name": {"type": "string"},
                    "location": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                    "rotation": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3},
                    "scale": {"type": "array", "items": {"type": "number"}, "minItems": 3, "maxItems": 3}
                }
            }
        ),
        Tool(
            name="save_scene",
            description="Speichert die aktuelle Szene.",
            inputSchema={"type": "object", "properties": {}}
        ),
        Tool(
            name="run_project",
            description="Startet das aktuelle Godot-Projekt im Play-Modus.",
            inputSchema={"type": "object", "properties": {}}
        ),
        Tool(
            name="stop_project",
            description="Stoppt das aktuelle Godot-Projekt im Play-Modus.",
            inputSchema={"type": "object", "properties": {}}
        ),
        Tool(
            name="export_project",
            description="Exportiert das Projekt für eine Plattform (aktuell nur Platzhalter).",
            inputSchema={
                "type": "object",
                "required": ["preset"],
                "properties": {
                    "preset": {"type": "string"}
                }
            }
        ),
        Tool(
            name="execute_gdscript",
            description="Führt beliebigen GDScript-Code im Godot-Editor aus. Erfordert eine ausdrückliche Freigabe im Addon.",
            inputSchema={
                "type": "object",
                "required": ["code"],
                "properties": {
                    "code": {"type": "string"}
                }
            }
        )
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent | ImageContent]:
    logger.info(f"Tool-Aufruf: {name}({arguments})")

    if name == "list_nodes":
        result = await godot_client.send("list_nodes")
        return [TextContent(type="text", text=json.dumps(result, indent=2))]

    if name == "get_node_info":
        result = await godot_client.send("get_node_info", {"name": arguments["name"]})
        return [TextContent(type="text", text=json.dumps(result, indent=2))]

    if name == "create_primitive":
        result = await godot_client.send("create_primitive", arguments)
        return [TextContent(type="text", text=f"Node erstellt: {result.get('name', '?')}")]

    if name == "delete_node":
        await godot_client.send("delete_node", {"name": arguments["name"]})
        return [TextContent(type="text", text=f"Node '{arguments['name']}' gelöscht.")]

    if name == "transform_node":
        result = await godot_client.send("transform_node", arguments)
        return [TextContent(type="text", text=f"Node '{result.get('name', '?')}' transformiert.")]

    if name == "save_scene":
        result = await godot_client.send("save_scene")
        return [TextContent(type="text", text=f"Szene gespeichert: {result.get('path', '?')}")]

    if name == "run_project":
        result = await godot_client.send("run_project")
        return [TextContent(type="text", text=result.get("status", "Projekt gestartet"))]

    if name == "stop_project":
        result = await godot_client.send("stop_project")
        return [TextContent(type="text", text=result.get("status", "Projekt gestoppt"))]

    if name == "export_project":
        result = await godot_client.send("export_project", {"preset": arguments["preset"]})
        return [TextContent(type="text", text=result.get("status", "Exportiert"))]

    if name == "execute_gdscript":
        result = await godot_client.send("execute_gdscript", {"code": arguments["code"]})
        return [TextContent(type="text", text=result.get("output", "OK"))]

    raise ValueError(f"Unbekanntes Tool: {name}")


async def main() -> None:
    async with stdio_server() as (read_stream, write_stream):
        init_options = InitializationOptions(
            server_name="godot-mcp",
            server_version="0.1.0",
            capabilities=server.get_capabilities(
                notification_options=NotificationOptions(),
                experimental_capabilities={}
            )
        )
        await server.run(read_stream, write_stream, init_options)


async def _smoke_test():
    """Smoke test: initialize and list tools without STDIO."""
    print("Capabilities:", server.get_capabilities(
        notification_options=NotificationOptions(),
        experimental_capabilities={}
    ))
    print("Tools:", await list_tools())
    print("Resources:", await list_resources())


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--smoke":
        asyncio.run(_smoke_test())
    else:
        asyncio.run(main())
