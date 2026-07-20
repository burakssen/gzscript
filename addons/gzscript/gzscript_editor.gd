@tool
extends EditorPlugin

var rebuild_timer: Timer
var inspector_refresh_queued := false


func _enter_tree() -> void:
	rebuild_timer = Timer.new()
	rebuild_timer.one_shot = true
	rebuild_timer.wait_time = 0.2
	rebuild_timer.timeout.connect(_rebuild_loaded_scripts)
	add_child(rebuild_timer)

	if Engine.has_singleton("EditorInterface"):
		var ei = Engine.get_singleton("EditorInterface")
		if ei != null:
			var fs = ei.get_resource_filesystem()
			if fs != null:
				fs.filesystem_changed.connect(_queue_rebuild)

	if GzBuildManager != null:
		GzBuildManager.script_compiled.connect(_queue_inspector_refresh)


func _exit_tree() -> void:
	if Engine.has_singleton("EditorInterface"):
		var ei = Engine.get_singleton("EditorInterface")
		if ei != null:
			var fs = ei.get_resource_filesystem()
			if fs != null and fs.filesystem_changed.is_connected(_queue_rebuild):
				fs.filesystem_changed.disconnect(_queue_rebuild)

	if GzBuildManager != null and GzBuildManager.script_compiled.is_connected(_queue_inspector_refresh):
		GzBuildManager.script_compiled.disconnect(_queue_inspector_refresh)


func _get_script_editor() -> ScriptEditor:
	if Engine.has_singleton("EditorInterface"):
		var ei = Engine.get_singleton("EditorInterface")
		if ei != null:
			return ei.get_script_editor()
	return null


func _queue_rebuild() -> void:
	rebuild_timer.start()


func _queue_inspector_refresh() -> void:
	if inspector_refresh_queued:
		return
	inspector_refresh_queued = true
	call_deferred("_refresh_inspector")


func _refresh_inspector() -> void:
	inspector_refresh_queued = false
	if Engine.has_singleton("EditorInterface"):
		var ei = Engine.get_singleton("EditorInterface")
		if ei != null:
			var inspector = ei.get_inspector()
			if inspector != null:
				var edited_object = inspector.get_edited_object()
				if edited_object != null and edited_object.get_script() is GzScript:
					inspector.edit(edited_object)


func _rebuild_loaded_scripts() -> void:
	if not GzBuildManager.compile_all():
		push_error(GzBuildManager.get_last_diagnostics())


func _build() -> bool:
	var success := GzBuildManager.compile_all()
	if not success:
		push_error(GzBuildManager.get_last_diagnostics())
	return success
