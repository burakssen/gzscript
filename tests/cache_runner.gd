extends SceneTree

const FIXTURE_DIR := "res://.godot/gzscript/cache_test"
const SCRIPT_PATH := FIXTURE_DIR + "/main.zig"
const HELPER_PATH := FIXTURE_DIR + "/helper.zig"
const EMBEDDED_PATH := FIXTURE_DIR + "/data.txt"
const UNRELATED_PATH := FIXTURE_DIR + "/unrelated.txt"

const SCRIPT_SOURCE := """const gd = @import("godot");
const helper = @import("helper.zig");
const embedded_value: i64 = @intCast(@embedFile("data.txt")[0] - '0');

pub const Base = gd.Node;
const Self = @This();

base: Base,
value: i64 = helper.value + embedded_value,

pub const exports = .{ .value = gd.property(.{}) };

pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	_write(HELPER_PATH, "pub const value: i64 = 1;\n")
	_write(EMBEDDED_PATH, "1\n")
	_write(SCRIPT_PATH, SCRIPT_SOURCE)
	var worker := Thread.new()
	worker.start(_compile_on_worker)
	if not _require(not worker.wait_to_finish(), "worker-thread compilation was not rejected"):
		return

	var before_files := _module_files()
	var before := before_files.size()
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "initial fixture compile failed"):
		return
	var after_files := _module_files()
	var after_initial := after_files.size()
	if not _require(after_initial == before + 1, "initial compile did not create one module"):
		return
	var new_modules := after_files.filter(func(path: String) -> bool: return path not in before_files)
	if not _require(new_modules.size() == 1, "unable to identify initial cache module"):
		return
	var initial_module_bytes := FileAccess.get_file_as_bytes(new_modules[0])
	_write(new_modules[0], "not a native library")
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "corrupt cache module was not rebuilt automatically"):
		return
	_write(UNRELATED_PATH, "not a Zig dependency\n")
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "cache check failed after unrelated file change"):
		return
	if not _require(_module_count() == after_initial, "unrelated project file changed the Zig cache identity"):
		return

	var before_helper_files := _module_files()
	_write(HELPER_PATH, "pub const value: i64 = 2;\n")
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "fixture recompile failed"):
		return
	if not _require(_module_count() == after_initial + 1, "changing an imported Zig file reused a stale module"):
		return
	var helper_modules := _module_files().filter(func(path: String) -> bool: return path not in before_helper_files)
	if not _require(helper_modules.size() == 1, "unable to identify imported-file cache module"):
		return
	_write_bytes(helper_modules[0], initial_module_bytes)
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "valid stale cache module was not rebuilt"):
		return
	if not _require(FileAccess.get_file_as_bytes(helper_modules[0]) != initial_module_bytes, "valid stale cache module replaced newly compiled output"):
		return

	_write(EMBEDDED_PATH, "2\n")
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "embedded dependency recompile failed"):
		return
	if not _require(_module_count() == after_initial + 2, "changing an embedded non-Zig file reused a stale module"):
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
	script.set_source_code("pub fn broken( {\n")
	if not _require(script.reload(false) == ERR_COMPILATION_FAILED, "invalid reload unexpectedly succeeded"):
		return
	if not _require(script.can_instantiate(), "failed reload disabled the last accepted module"):
		return
	var fallback_instance := Node.new()
	fallback_instance.set_script(script)
	if not _require(fallback_instance.get("value") == 4, "failed reload did not preserve the last accepted module"):
		fallback_instance.free()
		return
	fallback_instance.free()

	_write(SCRIPT_PATH, SCRIPT_SOURCE)
	script.set_source_code(SCRIPT_SOURCE)
	if not _require(script.reload() == OK, "failed to reload recovered script"):
		return
	if not _require(GzBuildManager.get_last_diagnostics().is_empty(), "successful compile retained stale diagnostics"):
		return

	# Existing instances keep the module and state they were created with.
	var instance := Node.new()
	instance.set_script(script)
	instance.set("value", 42)

	var new_source := SCRIPT_SOURCE + "\n// modified to trigger recompile\n"
	_write(SCRIPT_PATH, new_source)
	script.set_source_code(new_source)

	if not _require(script.reload(false) == OK, "reload with an active instance failed"):
		return
	if not _require(instance.get("value") == 42, "reload replaced an existing instance"):
		return
	instance.free()

	_cleanup()
	print("GZSCRIPT_CACHE_OK")
	quit()


func _module_count() -> int:
	return _module_files().size()


func _module_files() -> Array[String]:
	var platform := OS.get_name().to_lower()
	if platform == "macos":
		platform = "macos"
	var path := "res://.godot/gzscript/modules/%s-%s" % [platform, Engine.get_architecture_name()]
	var directory := DirAccess.open(path)
	if directory == null:
		return []
	var result: Array[String] = []
	for file in directory.get_files():
		if file.get_extension() in ["dll", "dylib", "so"]:
			result.push_back(path.path_join(file))
	return result


func _compile_on_worker() -> bool:
	return GzBuildManager.compile_path(SCRIPT_PATH)


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("unable to write fixture: " + path)
		return
	file.store_string(contents)
	file.close()


func _write_bytes(path: String, contents: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("unable to write fixture: " + path)
		return
	file.store_buffer(contents)
	file.close()


func _require(condition: bool, message: String) -> bool:
	if not condition:
		_fail(message)
	return condition


func _fail(message: String) -> void:
	push_error(message)
	_cleanup()
	quit(1)


func _cleanup() -> void:
	var paths := [SCRIPT_PATH, SCRIPT_PATH + ".uid", HELPER_PATH, HELPER_PATH + ".uid", UNRELATED_PATH]
	paths.append_array([EMBEDDED_PATH, EMBEDDED_PATH + ".uid"])
	for path in paths:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
