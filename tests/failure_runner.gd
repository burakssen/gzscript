extends SceneTree

const MISMATCH_PATH := "res://.godot/gzscript/base_mismatch.zig"


func _initialize() -> void:
	var script := load("res://tests/invalid_script.zig")
	assert(script != null, "Invalid Zig source must remain a resource")
	assert(not script.can_instantiate(), "Invalid Zig source must not instantiate")
	assert(GzBuildManager.get_last_diagnostics().contains("invalid_script.zig"))
	var file := FileAccess.open(MISMATCH_PATH, FileAccess.WRITE)
	assert(file != null)
	file.store_string("""const gd = @import("godot");
pub const Base = gd.Node2D;
const Self = @This();
base: gd.Node,
pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}
""")
	file.close()
	assert(not GzBuildManager.compile_path(MISMATCH_PATH), "Mismatched Base and base field compiled")
	assert(GzBuildManager.get_last_diagnostics().contains("base field must have type Script.Base"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MISMATCH_PATH))
	print("GZSCRIPT_FAILURE_HANDLING_OK")
	quit()
