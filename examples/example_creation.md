# Beispiel: Objekte über MCP in Godot erstellen

## Einfache rote Kugel

Claude Tool-Aufruf:
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

## Bodenplatte

```json
{
  "tool": "create_primitive",
  "arguments": {
    "type": "box",
    "name": "Floor",
    "location": [0, -0.5, 0],
    "size": 5.0,
    "color": [0.4, 0.4, 0.4, 1.0]
  }
}
```

## Szene auflisten

Claude Tool-Aufruf:
```json
{
  "tool": "list_nodes",
  "arguments": {}
}
```

Erwartete Antwort:
```json
{
  "nodes": [
    {"name": "Node3D", "class": "Node3D"},
    {"name": "RedSphere", "class": "MeshInstance3D"},
    {"name": "Floor", "class": "MeshInstance3D"}
  ]
}
```

## Transformation

```json
{
  "tool": "transform_node",
  "arguments": {
    "name": "RedSphere",
    "location": [2, 1, 0],
    "scale": [1.5, 1.5, 1.5]
  }
}
```
