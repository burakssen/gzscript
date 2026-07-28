extends SceneTree

const MISMATCH_PATH := "res://.godot/gzscript/base_mismatch.zig"
const UNKNOWN_OPTION_PATH := "res://.godot/gzscript/unknown_property_option.zig"
const INVALID_RANGE_PATH := "res://.godot/gzscript/invalid_property_range.zig"
const DUPLICATE_EXPORT_PATH := "res://.godot/gzscript/duplicate_export.zig"
const ORPHAN_SUBGROUP_PATH := "res://.godot/gzscript/orphan_subgroup.zig"
const INVALID_HINT_PATH := "res://.godot/gzscript/invalid_property_hint.zig"


func expect_compile_failure(path: String, source: String, diagnostic: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert(file != null)
	file.store_string(source)
	file.close()
	assert(not GzBuildManager.compile_path(path), "%s unexpectedly compiled" % path)
	assert(GzBuildManager.get_last_diagnostics().contains(diagnostic), GzBuildManager.get_last_diagnostics())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _initialize() -> void:
	var script := load("res://tests/invalid_script.zig")
	assert(script != null, "Invalid Zig source must remain a resource")
	assert(not script.can_instantiate(), "Invalid Zig source must not instantiate")
	assert(GzBuildManager.get_last_diagnostics().contains("invalid_script.zig"))
	expect_compile_failure(MISMATCH_PATH, """const gd = @import("godot");
pub const Base = gd.Node2D;
const Self = @This();
base: gd.Node,
pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}
""", "base field must have type Script.Base")
	expect_compile_failure(UNKNOWN_OPTION_PATH, """const gd = @import("godot");
pub const Base = gd.Node;
const Self = @This();
base: Base,
speed: f64 = 1,
pub const exports = .{ .speed = gd.property(.{ .categorry = "Movement" }) };
pub fn init(ctx: gd.InitContext) !Self { return .{ .base = .{ .owner = ctx.owner } }; }
""", "unknown property option: categorry")
	expect_compile_failure(INVALID_RANGE_PATH, """const gd = @import("godot");
pub const Base = gd.Node;
const Self = @This();
base: Base,
speed: f64 = 1,
pub const exports = .{ .speed = gd.property(.{ .range = .{ .min = 10, .max = 0, .step = 0 } }) };
pub fn init(ctx: gd.InitContext) !Self { return .{ .base = .{ .owner = ctx.owner } }; }
""", "property range minimum must not exceed maximum")
	expect_compile_failure(DUPLICATE_EXPORT_PATH, """const gd = @import("godot");
pub const Base = gd.Node;
const Self = @This();
base: Base,
speed: f64 = 1,
pub const exports = gd.exports(.{
	gd.field("speed", gd.property(.{})),
	gd.field("speed", gd.property(.{})),
});
pub fn init(ctx: gd.InitContext) !Self { return .{ .base = .{ .owner = ctx.owner } }; }
""", "duplicate exported field: speed")
	expect_compile_failure(ORPHAN_SUBGROUP_PATH, """const gd = @import("godot");
pub const Base = gd.Node;
const Self = @This();
base: Base,
speed: f64 = 1,
pub const exports = gd.exports(.{
	gd.subgroup("Timing", ""),
	gd.field("speed", gd.property(.{})),
});
pub fn init(ctx: gd.InitContext) !Self { return .{ .base = .{ .owner = ctx.owner } }; }
""", "export subgroup requires an active group: Timing")
	expect_compile_failure(INVALID_HINT_PATH, """const gd = @import("godot");
pub const Base = gd.Node;
const Self = @This();
base: Base,
speed: f64 = 1,
pub const exports = .{ .speed = gd.property(.{ .hint = .file }) };
pub fn init(ctx: gd.InitContext) !Self { return .{ .base = .{ .owner = ctx.owner } }; }
""", "property hint requires a string field: speed")
	print("GZSCRIPT_FAILURE_HANDLING_OK")
	quit()
