extends Node

var zig_ready_count := 0
var reported_position := Vector2.ZERO


func _on_zig_ready() -> void:
	zig_ready_count += 1


func _on_position_changed(position: Vector2) -> void:
	reported_position = position


func _ready() -> void:
	var found_zig := false
	for index in Engine.get_script_language_count():
		if Engine.get_script_language(index) is GzLanguage:
			found_zig = true
	assert(found_zig, "Zig language was not registered")

	var zig_script := load("res://examples/basic/scripts/player.zig")
	assert(zig_script != null, "Zig script resource failed to load")
	assert(zig_script.can_instantiate(), "Zig script failed to compile")
	assert(zig_script.get_instance_base_type() == "Node2D")
	var property_names: Array[StringName] = []
	for property in zig_script.get_script_property_list():
		if property.usage != PROPERTY_USAGE_CATEGORY:
			property_names.push_back(property.name)
	assert(property_names == [&"amplitude", &"speed"])
	assert(zig_script.has_script_signal(&"zig_ready"))
	assert(zig_script.has_script_signal(&"position_changed"))
	var signal_list: Array = zig_script.get_script_signal_list()
	assert(signal_list.size() == 2)
	assert(signal_list[0].name == &"zig_ready")
	assert(signal_list[0].args.is_empty())
	assert(signal_list[1].name == &"position_changed")
	assert(signal_list[1].args.size() == 1)
	assert(signal_list[1].args[0].name == &"position")
	assert(signal_list[1].args[0].type == TYPE_VECTOR2)

	var player := Node2D.new()
	player.set_script(zig_script)
	player.connect(&"zig_ready", _on_zig_ready)
	player.connect(&"position_changed", _on_position_changed)
	add_child(player)
	var instance_property_names: Array[StringName] = []
	for property in player.get_property_list():
		if property.name in [&"amplitude", &"speed"]:
			instance_property_names.push_back(property.name)
	assert(instance_property_names == [&"amplitude", &"speed"])
	assert(player.position.is_equal_approx(Vector2(12.0, 34.0)))
	assert(is_equal_approx(player.rotation, 0.5))
	assert(player.scale.is_equal_approx(Vector2(2.0, 3.0)))
	assert(zig_ready_count == 1)
	assert(reported_position.is_equal_approx(Vector2(12.0, 34.0)))
	assert(is_equal_approx(player.get("amplitude"), 10.0))
	player.set("speed", 3.5)
	assert(is_equal_approx(player.get("speed"), 3.5))
	print("GZSCRIPT_INTEGRATION_OK")
	get_tree().quit()
