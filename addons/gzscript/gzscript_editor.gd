@tool
extends EditorPlugin

const ZigHighlighter := preload("zig_highlighter.gd")

var rebuild_timer: Timer
var inspector_refresh_queued := false
var zig_highlighter: EditorSyntaxHighlighter
var configured_script_editors := {}
var zig_language: GzLanguage


func _enter_tree() -> void:
	for index in Engine.get_script_language_count():
		var candidate := Engine.get_script_language(index)
		if candidate is GzLanguage:
			zig_language = candidate
			zig_language.completion_ready.connect(_retry_zls_completion)
			break
	zig_highlighter = ZigHighlighter.new()
	var script_editor := EditorInterface.get_script_editor()
	if script_editor != null:
		script_editor.register_syntax_highlighter(zig_highlighter)
		script_editor.editor_script_changed.connect(_ensure_zig_highlighter)
		_ensure_zig_highlighter(script_editor.get_current_script())
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
	if is_instance_valid(zig_language) and zig_language.completion_ready.is_connected(_retry_zls_completion):
		zig_language.completion_ready.disconnect(_retry_zls_completion)
	zig_language = null
	if is_instance_valid(zig_highlighter):
		var se = EditorInterface.get_script_editor()
		if se != null:
			if se.editor_script_changed.is_connected(_ensure_zig_highlighter):
				se.editor_script_changed.disconnect(_ensure_zig_highlighter)
			se.unregister_syntax_highlighter(zig_highlighter)
	configured_script_editors.clear()
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


func _ensure_zig_highlighter(script) -> void:
	var script_editor := EditorInterface.get_script_editor()
	if script_editor == null:
		return
	var editor := script_editor.get_current_editor()
	if editor == null or configured_script_editors.has(editor.get_instance_id()):
		return
	if not script is GzScript:
		return
	var code_edit := editor.get_base_editor() as CodeEdit
	if code_edit == null:
		return
	configured_script_editors[editor.get_instance_id()] = true
	var current := code_edit.syntax_highlighter
	if current != null and current.get_script() == ZigHighlighter:
		return
	# ponytail: add one migration clone because Godot does not expose registered per-tab clones.
	var highlighter: EditorSyntaxHighlighter = ZigHighlighter.new()
	editor.add_syntax_highlighter(highlighter)
	code_edit.set_syntax_highlighter(highlighter)


func _queue_rebuild() -> void:
	rebuild_timer.start()


func _retry_zls_completion(path: String) -> void:
	var script_editor := _get_script_editor()
	if script_editor == null:
		return
	var script := script_editor.get_current_script()
	if not script is GzScript or script.resource_path != path:
		return
	var editor := script_editor.get_current_editor()
	if editor == null:
		return
	var code_edit := editor.get_base_editor() as CodeEdit
	if code_edit != null:
		# ponytail: Retry only after ZLS cached this exact request; the hook stays synchronous.
		code_edit.request_code_completion(true)


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
					edited_object.notify_property_list_changed()


func _rebuild_loaded_scripts() -> void:
	GzBuildManager.queue_all()


func _build() -> bool:
	var success := GzBuildManager.compile_all()
	if not success:
		push_error(GzBuildManager.get_last_diagnostics())
	return success
