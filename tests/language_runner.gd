@tool
extends SceneTree

const SCRIPT_PATH := "res://.godot/gzscript/editor_test.zig"
const SCRIPT_SOURCE := """const gd = @import("godot");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,
speed: f64 = 1.0,

pub const exports = .{
    .speed = gd.property(.{
        .range = .{ .min = 0.0, .max = 20.0, .step = 0.1 },
    }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}
"""
const UPDATED_SCRIPT_SOURCE := """const gd = @import("godot");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,
amplitude: f64 = 2.0,

pub const exports = .{
    .amplitude = gd.property(.{
        .range = .{ .min = 0.0, .max = 10.0, .step = 0.5 },
    }),
};

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _init() -> void:
	call_deferred("_open_zig_script")


func _open_zig_script() -> void:
	var script := GzScript.new()
	script.source_code = SCRIPT_SOURCE
	var sprite := Sprite2D.new()
	sprite.set_script(script)
	if ResourceSaver.save(script, SCRIPT_PATH) != OK:
		push_error("Unable to save Zig script for editor test")
		sprite.free()
		_cleanup()
		quit(1)
		return
	var exported_speed := false
	for property in sprite.get_property_list():
		if property.name == &"speed":
			exported_speed = property.hint == PROPERTY_HINT_RANGE and property.hint_string == "0.0,20.0,0.1"
	if not exported_speed:
		push_error("Existing Zig placeholder did not receive exported properties")
		sprite.free()
		_cleanup()
		quit(1)
		return
	var property_list_changes := [0]
	sprite.property_list_changed.connect(func() -> void: property_list_changes[0] += 1)
	var editor_interface = Engine.get_singleton("EditorInterface")
	if editor_interface == null:
		push_error("EditorInterface singleton is unavailable")
		sprite.free()
		_cleanup()
		quit(1)
		return
	editor_interface.inspect_object(sprite)
	script.source_code = UPDATED_SCRIPT_SOURCE
	if ResourceSaver.save(script, SCRIPT_PATH) != OK:
		push_error("Unable to resave Zig script for editor test")
		sprite.free()
		_cleanup()
		quit(1)
		return
	var export_names: Array[StringName] = []
	for property in sprite.get_property_list():
		if property.name in [&"speed", &"amplitude"]:
			export_names.push_back(property.name)
	if export_names != [&"amplitude"] or property_list_changes[0] == 0:
		push_error("Zig exports did not refresh after save")
		sprite.free()
		_cleanup()
		quit(1)
		return
	editor_interface.edit_script(script)
	var lang = Engine.get_singleton("GzLanguage")
	if lang != null:
		var validation: Dictionary = lang._validate(SCRIPT_SOURCE, SCRIPT_PATH, true, true, true, true)
		if not validation.get("valid", false):
			push_error("GzLanguage._validate failed for valid Zig source")
			sprite.free()
			_cleanup()
			quit(1)
			return
		var invalid_validation: Dictionary = lang._validate("pub fn foo() { var x = ; }", SCRIPT_PATH, true, true, true, true)
		if invalid_validation.get("valid", true) or invalid_validation.get("errors", []).is_empty():
			push_error("GzLanguage._validate failed to report syntax errors for invalid Zig source")
			sprite.free()
			_cleanup()
			quit(1)
			return
		var completions: Dictionary = lang._complete_code(SCRIPT_SOURCE, SCRIPT_PATH, sprite)
		if completions.get("options", []).is_empty():
			push_error("GzLanguage._complete_code returned no completion options")
			sprite.free()
			_cleanup()
			quit(1)
			return
	print("GZSCRIPT_LANGUAGE_OK")
	await process_frame
	editor_interface.inspect_object(null)
	await process_frame
	sprite.free()
	_cleanup()
	quit()


func _cleanup() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRIPT_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRIPT_PATH + ".uid"))
