extends SceneTree

const SCRIPT_PATH := "res://sprite_2d_test.zig"
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
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRIPT_PATH))
	if result != OK:
		push_error("New Zig script failed to save and compile: %s" % error_string(result))
		quit(1)
		return
	print("GZSCRIPT_SAVE_OK")
	quit()
