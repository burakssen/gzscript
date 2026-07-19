extends SceneTree


func _initialize() -> void:
	var script := load("res://tests/invalid_script.zig")
	assert(script != null, "Invalid Zig source must remain a resource")
	assert(not script.can_instantiate(), "Invalid Zig source must not instantiate")
	assert(GzBuildManager.get_last_diagnostics().contains("invalid_script.zig"))
	print("GZSCRIPT_FAILURE_HANDLING_OK")
	quit()
