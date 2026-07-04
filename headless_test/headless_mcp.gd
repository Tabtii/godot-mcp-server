extends Node

const MCP_PORT := 8406
const MCP_HOST := "127.0.0.1"

var tcp_server := TCPServer.new()
var clients := []
var server_running := false

func _ready():
	start_server()

func _process(_delta: float):
	if not server_running:
		return

	if tcp_server.is_connection_available():
		var conn := tcp_server.take_connection()
		var peer := WebSocketPeer.new()
		var err := peer.accept_stream(conn)
		if err == OK:
			clients.append(peer)
			print("[Godot MCP Headless] Client verbunden")
		else:
			print("[Godot MCP Headless] Verbindungsannahme fehlgeschlagen: ", err)

	for i in range(clients.size() - 1, -1, -1):
		var peer : WebSocketPeer = clients[i]
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			var packet := peer.get_packet()
			if packet.size() > 0:
				print("[Godot MCP Headless] Paket empfangen")
				var text := packet.get_string_from_utf8()
				print("[Godot MCP Headless] Text: ", text)
				var response := handle_message(text)
				print("[Godot MCP Headless] Antwort: ", response)
				peer.send_text(response)
		elif state == WebSocketPeer.STATE_CLOSING or state == WebSocketPeer.STATE_CLOSED:
			clients.remove_at(i)
			print("[Godot MCP Headless] Client getrennt")

func start_server() -> void:
	if server_running:
		return
	var err := tcp_server.listen(MCP_PORT, MCP_HOST)
	if err != OK:
		push_error("[Godot MCP Headless] Konnte Port %d nicht binden: %d" % [MCP_PORT, err])
		return
	server_running = true
	print("[Godot MCP Headless] WebSocket-Server gestartet auf ws://%s:%d" % [MCP_HOST, MCP_PORT])

func stop_server() -> void:
	server_running = false
	for peer in clients:
		peer.close()
	clients.clear()
	tcp_server.stop()
	print("[Godot MCP Headless] Server gestoppt")

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
# Command handlers (same protocol as editor plugin)
# ────────────────────────────────────────────────

func cmd_list_nodes(_params: Dictionary) -> Dictionary:
	var nodes := []
	_collect_nodes(self, nodes)
	return {"nodes": nodes}

func _collect_nodes(node: Node, out: Array):
	if node == null:
		return
	out.append({"name": node.name, "class": node.get_class()})
	for child in node.get_children():
		_collect_nodes(child, out)

func cmd_get_scene_info(_params: Dictionary) -> Dictionary:
	var nodes := []
	_collect_nodes(self, nodes)
	return {"scene": self.name, "node_count": nodes.size(), "nodes": nodes}

func cmd_get_node_info(params: Dictionary) -> Dictionary:
	var name := params.get("name", "") as String
	var node := _find_node_by_name(name)
	if node == null:
		return {"error": "Node nicht gefunden: %s" % name}
	var info := {"name": node.name, "class": node.get_class(), "path": str(node.get_path())}
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
		_:
			mesh = BoxMesh.new()
			mesh.size = Vector3(size, size, size)

	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.position = Vector3(location[0], location[1], location[2])

	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color_arr[0], color_arr[1], color_arr[2], color_arr[3] if color_arr.size() > 3 else 1.0)
	instance.material_override = material

	add_child(instance, true)
	return {"name": instance.name, "location": location}

func cmd_delete_node(params: Dictionary) -> Dictionary:
	var name := params.get("name", "") as String
	var node := _find_node_by_name(name)
	if node == null:
		return {"error": "Node nicht gefunden: %s" % name}
	node.queue_free()
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
	return {
		"name": n3d.name,
		"location": [n3d.position.x, n3d.position.y, n3d.position.z],
		"rotation": [n3d.rotation.x, n3d.rotation.y, n3d.rotation.z],
		"scale": [n3d.scale.x, n3d.scale.y, n3d.scale.z]
	}

func cmd_save_scene(_params: Dictionary) -> Dictionary:
	# In headless mode there's no scene save via EditorInterface.
	return {"status": "Speichern im Headless-Modus nicht verfügbar"}

func cmd_run_project(_params: Dictionary) -> Dictionary:
	return {"status": "Play-Modus im Headless-Server nicht verfügbar"}

func cmd_stop_project(_params: Dictionary) -> Dictionary:
	return {"status": "Stop im Headless-Server nicht verfügbar"}

func cmd_export_project(params: Dictionary) -> Dictionary:
	return {"status": "Export-Platzhalter", "preset": params.get("preset", "")}

func cmd_execute_gdscript(params: Dictionary) -> Dictionary:
	var code := params.get("code", "") as String
	var expression := Expression.new()
	var err := expression.parse(code, [])
	if err != OK:
		return {"error": "Parse-Fehler: %s" % expression.get_error_text()}
	var result = expression.execute([], self)
	if expression.has_execute_failed():
		return {"error": "Ausführungsfehler: %s" % expression.get_error_text()}
	return {"output": str(result)}

func _find_node_by_name(node_name: String) -> Node:
	if self.name == node_name:
		return self
	return _find_recursive(self, node_name)

func _find_recursive(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find_recursive(child, node_name)
		if found != null:
			return found
	return null
