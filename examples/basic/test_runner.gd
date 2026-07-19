extends Node


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

	var player := Node2D.new()
	player.set_script(zig_script)
	add_child(player)
	assert(is_equal_approx(player.get("amplitude"), 10.0))
	player.set("speed", 3.5)
	assert(is_equal_approx(player.get("speed"), 3.5))
	print("GZSCRIPT_INTEGRATION_OK")
	get_tree().quit()
