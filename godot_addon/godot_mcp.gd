@tool
extends EditorPlugin

const MCP_PORT := 8406
const MCP_HOST := "127.0.0.1"

var tcp_server := TCPServer.new()
var socket : WebSocketPeer = null
var clients := []
var server_running := false
var allow_arbitrary_gdscript := false

# ────────────────────────────────────────────────
# EditorPlugin lifecycle
# ────────────────────────────────────────────────

func _enter_tree():
	add_tool_menu_item("Godot MCP: Start Server", _on_start_server)
	add_tool_menu_item("Godot MCP: Stop Server", _on_stop_server)
	add_tool_menu_item("Godot MCP: Toggle Arbitrary GDScript", _on_toggle_arbitrary_gdscript)
	# Auto-start only when explicitly requested (e.g., for CI/smoke tests).
	if OS.has_environment("GODOT_MCP_AUTOSTART") and OS.get_environment("GODOT_MCP_AUTOSTART") == "1":
		start_server()

func _exit_tree():
	stop_server()
	remove_tool_menu_item("Godot MCP: Start Server")
	remove_tool_menu_item("Godot MCP: Stop Server")
	remove_tool_menu_item("Godot MCP: Toggle Arbitrary GDScript")

func _has_main_screen() -> bool:
	return true

func _make_visible(visible: bool):
	pass

func _get_plugin_name() -> String:
	return "Godot MCP"

func _get_plugin_icon() -> Texture2D:
	return get_editor_interface().get_base_control().get_theme_icon("Node", "EditorIcons")

func _process(delta: float):
	if not server_running:
		return

	# Accept new connections
	if tcp_server.is_connection_available():
		var conn := tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		var err := peer.accept_stream(conn)
		if err == OK:
			clients.append(peer)
			print("[Godot MCP] Client verbunden")
		else:
			print("[Godot MCP] Verbindungsannahme fehlgeschlagen: ", err)

	# Poll existing clients
	for i in range(clients.size() - 1, -1, -1):
		var peer : WebSocketPeer = clients[i]
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			var packet := peer.get_packet()
			if packet.size() > 0:
				var text := packet.get_string_from_utf8()
				var response := handle_message(text)
				peer.send_text(response)
		elif state == WebSocketPeer.STATE_CLOSING or state == WebSocketPeer.STATE_CLOSED:
			clients.remove_at(i)
			print("[Godot MCP] Client getrennt")

# ────────────────────────────────────────────────
# Server start/stop
# ────────────────────────────────────────────────

func _on_start_server():
	start_server()

func _on_stop_server():
	stop_server()

func _on_toggle_arbitrary_gdscript():
	allow_arbitrary_gdscript = not allow_arbitrary_gdscript
	print("[Godot MCP] Arbitrary GDScript ist jetzt: " + ("aktiviert" if allow_arbitrary_gdscript else "deaktiviert"))

func start_server() -> void:
	if server_running:
		print("[Godot MCP] Server läuft bereits")
		return

	var err := tcp_server.listen(MCP_PORT, MCP_HOST)
	if err != OK:
		push_error("[Godot MCP] Konnte Port %d nicht binden: %d" % [MCP_PORT, err])
		return

	server_running = true
	print("[Godot MCP] WebSocket-Server gestartet auf ws://%s:%d" % [MCP_HOST, MCP_PORT])

func stop_server() -> void:
	server_running = false
	for peer in clients:
		peer.close()
	clients.clear()
	tcp_server.stop()
	print("[Godot MCP] Server gestoppt")

# ────────────────────────────────────────────────
# Message handling
# ────────────────────────────────────────────────

func handle_message(text: String) -> String:
	var request = JSON.parse_string(text)
	if request == null or typeof(request) != TYPE_DICTIONARY:
		return error_response(null, "Ungültiges JSON")

	var method := request.get("method", "") as String
	var params := request.get("params", {}) as Dictionary
	var req_id = request.get("id", null)

	var handler_name := "cmd_" + method
	if not has_method(handler_name):
		return error_response(req_id, "Unbekannte Methode: %s" % method)

	var result = call(handler_name, params)
	if result == null:
		return error_response(req_id, "Handler '%s' lieferte kein Ergebnis" % method)

	return JSON.stringify({
		"jsonrpc": "2.0",
		"id": req_id,
		"result": result
	})

func error_response(req_id, message: String) -> String:
	return JSON.stringify({
		"jsonrpc": "2.0",
		"id": req_id,
		"error": {
			"code": -32000,
			"message": message
		}
	})

# ────────────────────────────────────────────────
# Command handlers
# ────────────────────────────────────────────────

func cmd_list_nodes(_params: Dictionary) -> Dictionary:
	var nodes := []
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"nodes": [], "error": "Keine Szene geöffnet"}
	_collect_nodes(root, nodes)
	return {"nodes": nodes}

func _collect_nodes(node: Node, out: Array):
	if node == null:
		return
	out.append({
		"name": node.name,
		"class": node.get_class()
	})
	for child in node.get_children():
		_collect_nodes(child, out)

func cmd_get_scene_info(_params: Dictionary) -> Dictionary:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {"scene": "(none)", "node_count": 0, "nodes": []}
	var nodes := []
	_collect_nodes(root, nodes)
	return {
		"scene": root.name,
		"node_count": nodes.size(),
		"nodes": nodes
	}

func cmd_get_node_info(params: Dictionary) -> Dictionary:
	var name := params.get("name", "") as String
	var node := _find_node_by_name(name)
	if node == null:
		return {"error": "Node nicht gefunden: %s" % name}

	var info := {
		"name": node.name,
		"class": node.get_class(),
		"path": str(node.get_path())
	}
	if node is Node3D:
		info["location"] = [node.position.x, node.position.y, node.position.z]
		info["rotation"] = [node.rotation.x, node.rotation.y, node.rotation.z]
		info["scale"] = [node.scale.x, node.scale.y, node.scale.z]
	return info

func cmd_create_primitive(params: Dictionary) -> Dictionary:
	var type := params.get("type", "box") as String
	var node_name := params.get("name", "Primitive_%s" % type) as String
	var location := params.get("location", [0.0, 0.0, 0.0]) as Array
	var size := params.get("size", 1.0) as float
	var color_arr := params.get("color", [0.8, 0.8, 0.8, 1.0]) as Array

	var mesh : Mesh
	match type:
		"sphere":
			mesh = SphereMesh.new()
			mesh.radius = size
			mesh.height = size * 2.0
		"cylinder":
			mesh = CylinderMesh.new()
			mesh.top_radius = size
			mesh.bottom_radius = size
			mesh.height = size * 2.0
		"capsule":
			mesh = CapsuleMesh.new()
			mesh.radius = size
			mesh.height = size * 2.0
		"prism":
			mesh = PrismMesh.new()
			mesh.size = Vector3(size, size, size)
		_: # box
			mesh = BoxMesh.new()
			mesh.size = Vector3(size, size, size)

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = Vector3(location[0], location[1], location[2])

	# Material mit Farbe
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color_arr[0], color_arr[1], color_arr[2], color_arr[3] if color_arr.size() > 3 else 1.0)
	instance.material_override = material

	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return {"error": "Keine Szene geöffnet"}
	scene_root.add_child(instance, true)
	instance.owner = scene_root

	get_editor_interface().mark_scene_as_unsaved()
	return {"name": instance.name, "location": location}

func cmd_delete_node(params: Dictionary) -> Dictionary:
	var name := params.get("name", "") as String
	var node := _find_node_by_name(name)
	if node == null:
		return {"error": "Node nicht gefunden: %s" % name}
	node.queue_free()
	get_editor_interface().mark_scene_as_unsaved()
	return {"deleted": name}

func cmd_transform_node(params: Dictionary) -> Dictionary:
	var name := params.get("name", "") as String
	var node := _find_node_by_name(name)
	if node == null:
		return {"error": "Node nicht gefunden: %s" % name}
	if not node is Node3D:
		return {"error": "Node ist kein Node3D: %s" % name}

	var n3d := node as Node3D
	if params.has("location"):
		var loc := params["location"] as Array
		n3d.position = Vector3(loc[0], loc[1], loc[2])
	if params.has("rotation"):
		var rot := params["rotation"] as Array
		n3d.rotation = Vector3(rot[0], rot[1], rot[2])
	if params.has("scale"):
		var sc := params["scale"] as Array
		n3d.scale = Vector3(sc[0], sc[1], sc[2])

	get_editor_interface().mark_scene_as_unsaved()
	return {
		"name": n3d.name,
		"location": [n3d.position.x, n3d.position.y, n3d.position.z],
		"rotation": [n3d.rotation.x, n3d.rotation.y, n3d.rotation.z],
		"scale": [n3d.scale.x, n3d.scale.y, n3d.scale.z]
	}

func cmd_save_scene(_params: Dictionary) -> Dictionary:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return {"error": "Keine Szene geöffnet"}
	var path := scene_root.scene_file_path
	if path.is_empty():
		path = "res://Untitled.tscn"
	var err := get_editor_interface().save_scene()
	if err != OK:
		return {"error": "Speichern fehlgeschlagen: %d" % err}
	return {"path": path}

func cmd_run_project(_params: Dictionary) -> Dictionary:
	get_editor_interface().play_main_scene()
	return {"status": "Projekt gestartet"}

func cmd_stop_project(_params: Dictionary) -> Dictionary:
	get_editor_interface().stop_playing_scene()
	return {"status": "Projekt gestoppt"}

func cmd_export_project(params: Dictionary) -> Dictionary:
	var preset := params.get("preset", "") as String
	# Echter Export würde EditorExportPreset/EditorExportPlatform benötigen.
	# Wir liefern hier nur einen Platzhalter.
	return {"status": "Export-Platzhalter", "preset": preset}

func cmd_execute_gdscript(params: Dictionary) -> Dictionary:
	if not allow_arbitrary_gdscript:
		return {"error": "execute_gdscript ist deaktiviert. Aktiviere es im Tool-Menü unter 'Godot MCP: Allow Arbitrary GDScript'."}

	var code := params.get("code", "") as String
	var expression := Expression.new()
	var err := expression.parse(code, [])
	if err != OK:
		return {"error": "Parse-Fehler: %s" % expression.get_error_text()}

	var result = expression.execute([], self)
	if expression.has_execute_failed():
		return {"error": "Ausführungsfehler: %s" % expression.get_error_text()}
	return {"output": str(result)}

# ────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────

func _find_node_by_name(node_name: String) -> Node:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return null
	if scene_root.name == node_name:
		return scene_root
	return _find_recursive(scene_root, node_name)

func _find_recursive(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find_recursive(child, node_name)
		if found != null:
			return found
	return null
