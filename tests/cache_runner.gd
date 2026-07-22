extends SceneTree

const FIXTURE_DIR := "res://.godot/gzscript/cache_test"
const SCRIPT_PATH := FIXTURE_DIR + "/main.zig"
const HELPER_PATH := FIXTURE_DIR + "/helper.zig"

const SCRIPT_SOURCE := """const gd = @import("godot");
const helper = @import("helper.zig");

pub const Base = gd.Node;
const Self = @This();

base: Base,
value: i64 = helper.value,

pub const exports = .{ .value = gd.property(.{}) };

pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	_write(HELPER_PATH, "pub const value: i64 = 1;\n")
	_write(SCRIPT_PATH, SCRIPT_SOURCE)

	var before := _module_count()
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "initial fixture compile failed"):
		return
	var after_initial := _module_count()
	if not _require(after_initial == before + 1, "initial compile did not create one module"):
		return

	_write(HELPER_PATH, "pub const value: i64 = 2;\n")
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "fixture recompile failed"):
		return
	if not _require(_module_count() == after_initial + 1, "changing an imported Zig file reused a stale module"):
		return

	var script := load(SCRIPT_PATH) as Script
	if not _require(script != null, "unable to load cache fixture as a script"):
		return
	script.set_source_code(SCRIPT_SOURCE + "\n// unsaved source\n")
	if not _require(script.reload() == ERR_COMPILATION_FAILED, "unsaved source compiled different contents from disk"):
		return
	if not _require(GzBuildManager.get_last_diagnostics().contains("does not match the file on disk"), "source mismatch produced no actionable diagnostic"):
		return

	_write(SCRIPT_PATH, "pub fn broken( {\n")
	if not _require(not GzBuildManager.compile_path(SCRIPT_PATH), "invalid source unexpectedly compiled"):
		return
	if not _require(not GzBuildManager.get_last_diagnostics().is_empty(), "compile failure produced no diagnostics"):
		return

	_write(SCRIPT_PATH, SCRIPT_SOURCE)
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "valid source did not recover after failure"):
		return
	if not _require(GzBuildManager.get_last_diagnostics().is_empty(), "successful compile retained stale diagnostics"):
		return

	_cleanup()
	print("GZSCRIPT_CACHE_OK")
	quit()


func _module_count() -> int:
	var platform := OS.get_name().to_lower()
	if platform == "macos":
		platform = "macos"
	var path := "res://.godot/gzscript/modules/%s-%s" % [platform, Engine.get_architecture_name()]
	var directory := DirAccess.open(path)
	return 0 if directory == null else directory.get_files().size()


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("unable to write fixture: " + path)
		return
	file.store_string(contents)


func _require(condition: bool, message: String) -> bool:
	if not condition:
		_fail(message)
	return condition


func _fail(message: String) -> void:
	push_error(message)
	_cleanup()
	quit(1)


func _cleanup() -> void:
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid", HELPER_PATH, HELPER_PATH + ".uid"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
