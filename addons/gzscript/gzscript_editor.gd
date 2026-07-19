@tool
extends EditorPlugin

var rebuild_timer: Timer


func _enter_tree() -> void:
	rebuild_timer = Timer.new()
	rebuild_timer.one_shot = true
	rebuild_timer.wait_time = 0.2
	rebuild_timer.timeout.connect(_rebuild_loaded_scripts)
	add_child(rebuild_timer)
	get_editor_interface().get_resource_filesystem().filesystem_changed.connect(_queue_rebuild)


func _exit_tree() -> void:
	var filesystem := get_editor_interface().get_resource_filesystem()
	if filesystem.filesystem_changed.is_connected(_queue_rebuild):
		filesystem.filesystem_changed.disconnect(_queue_rebuild)


func _queue_rebuild() -> void:
	rebuild_timer.start()


func _rebuild_loaded_scripts() -> void:
	if not GzBuildManager.compile_all():
		push_error(GzBuildManager.get_last_diagnostics())


func _build() -> bool:
	var success := GzBuildManager.compile_all()
	if not success:
		push_error(GzBuildManager.get_last_diagnostics())
	return success
