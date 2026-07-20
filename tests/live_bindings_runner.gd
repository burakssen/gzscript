extends SceneTree

var fixture_2d: Control
var fixture_3d: Node3D
var control_probe: Control
var sprite_probe: Sprite2D
var node_3d_probe: Node3D
var verified := {}


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false


func _on_verified(kind: String, parent: Node, self_node: Node) -> void:
	var expected_parent: Node = fixture_3d if kind == "node3d" else fixture_2d
	var expected_self: Node = {
		"control": control_probe,
		"sprite": sprite_probe,
		"node3d": node_3d_probe,
	}[kind]
	verified[kind] = parent == expected_parent and self_node == expected_self


func _on_control_verified(parent: Node, self_node: Node) -> void:
	_on_verified("control", parent, self_node)


func _on_sprite_verified(parent: Node, self_node: Node) -> void:
	_on_verified("sprite", parent, self_node)


func _on_node_3d_verified(parent: Node, self_node: Node) -> void:
	_on_verified("node3d", parent, self_node)


func _load_probe(path: String, base_type: StringName) -> Script:
	var script := load(path) as Script
	if not _check(script != null and script.can_instantiate(), "%s failed to compile" % path):
		return null
	if not _check(script.get_instance_base_type() == base_type, "%s has the wrong base type" % path):
		return null
	return script


func _run() -> void:
	var control_script := _load_probe("res://tests/live_control.zig", &"Control")
	var sprite_script := _load_probe("res://tests/live_sprite_2d.zig", &"Sprite2D")
	var node_3d_script := _load_probe("res://tests/live_node_3d.zig", &"Node3D")
	if control_script == null or sprite_script == null or node_3d_script == null:
		return

	fixture_2d = Control.new()
	control_probe = Control.new()
	control_probe.set_script(control_script)
	control_probe.connect(&"verified", _on_control_verified)
	sprite_probe = Sprite2D.new()
	sprite_probe.set_script(sprite_script)
	sprite_probe.connect(&"verified", _on_sprite_verified)
	fixture_2d.add_child(control_probe)
	fixture_2d.add_child(sprite_probe)

	fixture_3d = Node3D.new()
	node_3d_probe = Node3D.new()
	node_3d_probe.set_script(node_3d_script)
	node_3d_probe.connect(&"verified", _on_node_3d_verified)
	fixture_3d.add_child(node_3d_probe)

	root.add_child(fixture_2d)
	root.add_child(fixture_3d)
	await process_frame

	if not _check(verified.get("control", false), "Control bindings probe failed"):
		return
	if not _check(verified.get("sprite", false), "Sprite2D bindings probe failed"):
		return
	if not _check(verified.get("node3d", false), "Node3D bindings probe failed"):
		return
	if not _check(control_probe.position.is_equal_approx(Vector2(11.0, 13.0)), "Control position mismatch"):
		return
	if not _check(sprite_probe.position.is_equal_approx(Vector2(21.0, 34.0)), "Sprite2D position mismatch"):
		return
	if not _check(not sprite_probe.centered and sprite_probe.flip_h, "Sprite2D property mismatch"):
		return

	fixture_2d.free()
	fixture_3d.free()
	print("GZSCRIPT_LIVE_BINDINGS_OK")
	quit()
