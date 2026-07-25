extends SceneTree

var fixture_2d: Control
var fixture_3d: Node3D
var control_probe: Control
var sprite_probe: Sprite2D
var node_3d_probe: Node3D
var verified := {}
var color_verified := false


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


func _on_color_verified(color: Color) -> void:
	color_verified = color.is_equal_approx(Color(0.2, 0.4, 0.6, 1.0))


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
	control_probe.connect(&"color_verified", _on_color_verified)
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
	if not _check(color_verified, "Color dynamic-call or signal conversion failed"):
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
	var wrong_object := Node.new()
	sprite_probe.set("held_texture", wrong_object)
	if not _check(sprite_probe.get("held_texture") == null, "Object export accepted the wrong Godot class"):
		wrong_object.free()
		return
	wrong_object.free()
	var texture := ImageTexture.new()
	var weak_texture: WeakRef = weakref(texture)
	sprite_probe.set("held_texture", texture)
	texture = null
	if not _check(weak_texture.get_ref() != null, "Object export did not retain a RefCounted value"):
		return
	sprite_probe.set("held_texture", null)
	await process_frame
	if not _check(weak_texture.get_ref() == null, "Clearing an object export did not release its retained value"):
		return
	texture = ImageTexture.new()
	weak_texture = weakref(texture)
	sprite_probe.texture = texture
	texture = null
	sprite_probe.notification(9002)
	sprite_probe.texture = null
	if not _check(weak_texture.get_ref() != null, "Script-side object assignment did not retain its value"):
		return
	sprite_probe.notification(9003)
	if not _check(sprite_probe.get("held_texture") == weak_texture.get_ref(), "Script-side object assignment bypassed class validation"):
		return
	sprite_probe.notification(9001)
	await process_frame
	if not _check(weak_texture.get_ref() == null, "Script-side object clearing did not release its retained value"):
		return

	var sprite_props := sprite_script.get_script_property_list()
	var enum_prop := {}
	var file_prop := {}
	var text_prop := {}
	var metadata_categories := 0
	for prop in sprite_props:
		if prop.name == "Metadata" and prop.usage == PROPERTY_USAGE_CATEGORY:
			metadata_categories += 1
		elif prop.name == "some_enum":
			enum_prop = prop
		elif prop.name == "some_file":
			file_prop = prop
		elif prop.name == "some_text":
			text_prop = prop

	if not _check(enum_prop.size() > 0, "some_enum property not found"):
		return
	if not _check(enum_prop.hint == PROPERTY_HINT_ENUM and enum_prop.hint_string == "First,Second,Third", "some_enum hint mismatch"):
		return
	if not _check(file_prop.size() > 0, "some_file property not found"):
		return
	if not _check(file_prop.hint == PROPERTY_HINT_FILE and file_prop.hint_string == "*.zig", "some_file hint mismatch"):
		return
	if not _check(text_prop.size() > 0, "some_text property not found"):
		return
	if not _check(metadata_categories == 1, "Repeated export categories produced duplicate Inspector headings"):
		return
	if not _check(text_prop.hint == PROPERTY_HINT_MULTILINE_TEXT, "some_text hint mismatch"):
		return

	fixture_2d.free()
	fixture_3d.free()
	print("GZSCRIPT_LIVE_BINDINGS_OK")
	quit()
