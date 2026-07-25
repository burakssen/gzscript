extends SceneTree

const SCRIPT_PATH := "res://sprite_2d_test.zig"
const INVALID_SCRIPT_PATH := "res://invalid_save_test.zig"
const SCRIPT_SOURCE := """const gd = @import("godot");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _init() -> void:
	var script := GzScript.new()
	script.source_code = SCRIPT_SOURCE
	var result := ResourceSaver.save(script, SCRIPT_PATH)
	if result != OK:
		push_error("New Zig script failed to save and compile: %s" % error_string(result))
		_cleanup()
		quit(1)
		return

	var invalid_script := GzScript.new()
	invalid_script.source_code = "pub fn broken( {\n"
	result = ResourceSaver.save(invalid_script, INVALID_SCRIPT_PATH)
	if result != OK:
		push_error("Persisting invalid Zig source reported a save failure: %s" % error_string(result))
		_cleanup()
		quit(1)
		return
	if invalid_script.can_instantiate():
		push_error("Invalid saved Zig source was marked valid")
		_cleanup()
		quit(1)
		return
	if FileAccess.get_file_as_string(INVALID_SCRIPT_PATH) != invalid_script.source_code:
		push_error("Invalid Zig source was not persisted")
		_cleanup()
		quit(1)
		return

	_cleanup()
	print("GZSCRIPT_SAVE_OK")
	quit()


func _cleanup() -> void:
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid", INVALID_SCRIPT_PATH, INVALID_SCRIPT_PATH + ".uid"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
