@tool
extends SceneTree

const SCRIPT_PATH := "res://editor_test.zig"
const SCENE_PATH := "res://editor_test.tscn"
const SCRIPT_SOURCE := """const gd = @import("godot");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,
speed: f64 = 1.0,

pub const exports = gd.exports(.{
    gd.category("Movement"),
    gd.group("Rates", ""),
    gd.field("speed", gd.property(.{
        .range = .{ .min = 0.0, .max = 20.0, .step = 0.1 },
    })),
});

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}
"""
const UPDATED_SCRIPT_SOURCE := """const gd = @import("godot");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,
speed: f64 = 1.0,
amplitude: f64 = 2.0,

pub const exports = gd.exports(.{
    gd.category("Tuning"),
    gd.group("Strength", ""),
    gd.field("speed", gd.property(.{
        .range = .{ .min = 0.0, .max = 20.0, .step = 0.1 },
    })),
    gd.field("amplitude", gd.property(.{
        .range = .{ .min = 0.0, .max = 10.0, .step = 0.5 },
    })),
});

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _init() -> void:
	call_deferred("_open_zig_script")


func _open_zig_script() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SCRIPT_PATH.get_base_dir()))
	var script := GzScript.new()
	script.source_code = SCRIPT_SOURCE
	if ResourceSaver.save(script, SCRIPT_PATH, ResourceSaver.FLAG_CHANGE_PATH) != OK:
		push_error("Unable to save Zig script for editor test")
		_cleanup()
		quit(1)
		return
	if not await _wait_for_compilation():
		return
	if not script.can_instantiate():
		push_error("Compiled Zig script cannot instantiate for editor test")
		_cleanup()
		quit(1)
		return
	var fixture := Sprite2D.new()
	fixture.name = "EditorTest"
	fixture.set_script(script)
	var packed_scene := PackedScene.new()
	if packed_scene.pack(fixture) != OK or ResourceSaver.save(packed_scene, SCENE_PATH) != OK:
		push_error("Unable to save scene for editor test")
		fixture.free()
		_cleanup()
		quit(1)
		return
	fixture.free()
	var editor_interface = Engine.get_singleton("EditorInterface")
	if editor_interface == null:
		push_error("EditorInterface singleton is unavailable")
		_cleanup()
		quit(1)
		return
	editor_interface.open_scene_from_path(SCENE_PATH)
	var scene_deadline := Time.get_ticks_msec() + 2_000
	while editor_interface.get_edited_scene_root() == null or editor_interface.get_edited_scene_root().scene_file_path != SCENE_PATH:
		if Time.get_ticks_msec() >= scene_deadline:
			push_error("Unable to open scene for editor test")
			_cleanup()
			quit(1)
			return
		await process_frame
	var sprite := editor_interface.get_edited_scene_root() as Sprite2D
	script = sprite.get_script() as GzScript
	var exported_speed := false
	for property in sprite.get_property_list():
		if property.name == &"speed":
			exported_speed = property.hint == PROPERTY_HINT_RANGE and property.hint_string == "0.0,20.0,0.1"
	if not exported_speed:
		push_error("Existing Zig instance did not receive initial exported properties")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	var property_list_changes := [0]
	sprite.property_list_changed.connect(func() -> void: property_list_changes[0] += 1)
	sprite.set("speed", 7.5)
	editor_interface.inspect_object(sprite)
	var inspector: EditorInspector = editor_interface.get_inspector()
	if inspector == null or not await _wait_for_inspector_property(inspector, &"speed"):
		push_error("Inspector did not render the initial Zig export")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	var inspector_callback := Callable()
	for connection in sprite.get_signal_connection_list(&"property_list_changed"):
		var callback: Callable = connection["callable"]
		if callback.get_object() == inspector:
			inspector_callback = callback
			break
	if not inspector_callback.is_valid():
		push_error("Unable to isolate the Inspector refresh fallback")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	sprite.disconnect(&"property_list_changed", inspector_callback)
	script.source_code = UPDATED_SCRIPT_SOURCE
	if ResourceSaver.save(script, SCRIPT_PATH) != OK:
		push_error("Unable to resave Zig script for editor test")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	var compilation_succeeded := await _wait_for_compilation()
	sprite.connect(&"property_list_changed", inspector_callback)
	if not compilation_succeeded:
		return
	if Engine.has_singleton("GzBuildManager"):
		Engine.get_singleton("GzBuildManager").emit_signal(&"script_compiled")
	var export_names: Array[StringName] = []
	var marker_names: Array[StringName] = []
	for property in sprite.get_property_list():
		if property.name in [&"speed", &"amplitude"]:
			export_names.push_back(property.name)
		elif property.usage in [PROPERTY_USAGE_CATEGORY, PROPERTY_USAGE_GROUP, PROPERTY_USAGE_SUBGROUP]:
			marker_names.push_back(property.name)
	if export_names != [&"speed", &"amplitude"] or not is_equal_approx(sprite.get("speed"), 7.5) or not &"Tuning" in marker_names or not &"Strength" in marker_names or &"Movement" in marker_names or &"Rates" in marker_names or property_list_changes[0] == 0:
		push_error("Zig exports did not refresh after save")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	if not await _wait_for_inspector_property(inspector, &"amplitude"):
		push_error("Inspector did not render the refreshed Zig export")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	editor_interface.edit_script(script)
	if not await _wait_for_zig_highlighter(editor_interface):
		push_error("Zig syntax highlighter was not selected")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	if _has_zls() and not await _wait_for_zls_completion(editor_interface):
		push_error("ZLS completion did not return the inferred struct member")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	var lang: GzLanguage = null
	for index in Engine.get_script_language_count():
		var candidate := Engine.get_script_language(index)
		if candidate is GzLanguage:
			lang = candidate
			break
	if lang == null:
		push_error("GzLanguage is not registered with ScriptServer")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	var label_template := lang.make_template_for_base("Label")
	if label_template == null or not label_template.source_code.contains("pub const Base = gd.Control;"):
		push_error("Unsupported subclasses do not use their nearest generated base")
		editor_interface.close_scene()
		_cleanup()
		quit(1)
		return
	print("GZSCRIPT_LANGUAGE_OK")
	await process_frame
	editor_interface.inspect_object(null)
	await process_frame
	editor_interface.close_scene()
	_cleanup()
	quit()


func _wait_for_compilation() -> bool:
	var deadline := Time.get_ticks_msec() + 60_000
	while Time.get_ticks_msec() < deadline:
		GzBuildManager.pump()
		if not GzBuildManager.is_compiling():
			await process_frame
			return true
		await create_timer(0.01).timeout
	push_error("Timed out waiting for Zig compilation")
	_cleanup()
	quit(1)
	return false


func _wait_for_inspector_property(inspector: EditorInspector, property: StringName) -> bool:
	var deadline := Time.get_ticks_msec() + 2_000
	while Time.get_ticks_msec() < deadline:
		for editor in inspector.find_children("*", "EditorProperty", true, false):
			if editor.get_edited_property() == property:
				return true
		await process_frame
	return false


func _wait_for_zig_highlighter(editor_interface) -> bool:
	var deadline := Time.get_ticks_msec() + 2_000
	while Time.get_ticks_msec() < deadline:
		var editor = editor_interface.get_script_editor().get_current_editor()
		if editor != null:
			var code_edit := editor.get_base_editor() as CodeEdit
			if code_edit != null:
				var highlighter := code_edit.syntax_highlighter as EditorSyntaxHighlighter
				if highlighter != null and highlighter.get_script() == load("res://addons/gzscript/zig_highlighter.gd"):
					var highlighting := highlighter.get_line_syntax_highlighting(0)
					return highlighting.has(0)
		await process_frame
	return false


func _wait_for_zls_completion(editor_interface) -> bool:
	var editor = editor_interface.get_script_editor().get_current_editor()
	if editor == null:
		return false
	var code_edit := editor.get_base_editor() as CodeEdit
	if code_edit == null:
		return false
	var original_text := code_edit.text
	code_edit.text = """const Probe = struct { alpha: i32 };

fn completion_probe() void {
	var probe: Probe = undefined;
	_ = probe.
}
"""
	code_edit.set_caret_line(4)
	code_edit.set_caret_column(code_edit.get_line(4).length())
	code_edit.request_code_completion(true)
	var deadline := Time.get_ticks_msec() + 12_000
	while Time.get_ticks_msec() < deadline:
		for option in code_edit.get_code_completion_options():
			if option.get("display_text", "") == "alpha":
				code_edit.text = original_text
				return true
		await process_frame
	code_edit.text = original_text
	return false


func _has_zls() -> bool:
	if not OS.get_environment("GZSCRIPT_ZLS_PATH").is_empty():
		return true
	var home := OS.get_environment("HOME")
	if home.is_empty():
		home = OS.get_environment("USERPROFILE")
	var executable := "zls.exe" if OS.get_name() == "Windows" else "zls"
	return FileAccess.file_exists(home.path_join(".zvm/bin").path_join(executable))


func _cleanup() -> void:
	var editor_interface = Engine.get_singleton("EditorInterface")
	if editor_interface != null:
		var script_editor = editor_interface.get_script_editor()
		if script_editor != null:
			script_editor.close_file(SCRIPT_PATH)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRIPT_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRIPT_PATH + ".uid"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCENE_PATH))
