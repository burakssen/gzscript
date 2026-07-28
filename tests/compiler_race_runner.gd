extends SceneTree

const FIXTURE_DIR := "res://.godot/gzscript/compiler_race"
const SCRIPT_PATH := FIXTURE_DIR + "/main.zig"
const HELPER_PATH := FIXTURE_DIR + "/helper.zig"
const CONTROL_DIR := "res://.godot/gzscript/compiler_race_control"
const WRAPPER_PATH := CONTROL_DIR + "/zig-wrapper.sh"
const STARTED_PATH := CONTROL_DIR + "/started"
const RELEASE_PATH := CONTROL_DIR + "/release"
const ZIG_PATH_SETTING := "gzscript/compiler/zig_path"
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
	call_deferred("_run")


func _run() -> void:
	if OS.get_name() == "Windows":
		print("GZSCRIPT_COMPILER_RACE_OK")
		quit()
		return

	var real_zig := OS.get_environment("GZSCRIPT_ZIG_PATH")
	if real_zig.is_empty():
		_fail("GZSCRIPT_ZIG_PATH is required")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTROL_DIR))
	_write(HELPER_PATH, "pub const value: i64 = 1;\n")
	_write(SCRIPT_PATH, SCRIPT_SOURCE)
	_write(WRAPPER_PATH, """#!/bin/sh
if [ "$1" = version ]; then
	exec '%s' "$@"
fi
touch '%s'
while [ ! -f '%s' ]; do sleep 0.01; done
exec '%s' "$@"
""" % [real_zig, _absolute(STARTED_PATH), _absolute(RELEASE_PATH), real_zig])
	if OS.execute("chmod", PackedStringArray(["+x", _absolute(WRAPPER_PATH)])) != 0:
		_fail("unable to make Zig wrapper executable")
		return

	ProjectSettings.set_setting(ZIG_PATH_SETTING, _absolute(WRAPPER_PATH))
	var before_modules := _module_files()
	var script := GzScript.new()
	script.source_code = SCRIPT_SOURCE
	if ResourceSaver.save(script, SCRIPT_PATH, ResourceSaver.FLAG_CHANGE_PATH) != OK:
		_fail("unable to save compiler race fixture")
		return
	var deadline := Time.get_ticks_msec() + 10_000
	while not FileAccess.file_exists(STARTED_PATH) and Time.get_ticks_msec() < deadline:
		GzBuildManager.pump()
		await process_frame
	if not FileAccess.file_exists(STARTED_PATH):
		_fail("compiler wrapper did not start")
		return

	_write(HELPER_PATH, "pub const value: i64 = 2;\n")
	_write(RELEASE_PATH, "release\n")
	deadline = Time.get_ticks_msec() + 10_000
	while GzBuildManager.is_compiling() and Time.get_ticks_msec() < deadline:
		GzBuildManager.pump()
		await process_frame
	if GzBuildManager.is_compiling():
		_fail("compiler race fixture timed out")
		return
	if not GzBuildManager.compile_path(SCRIPT_PATH):
		_fail("current dependency generation did not compile")
		return
	var fixture_modules := _module_files().filter(func(path: String) -> bool: return path not in before_modules)
	if fixture_modules.size() != 1:
		_fail("dependency changed during compilation published an obsolete cache key")
		return
	var generated := DirAccess.open("res://.godot/gzscript/generated")
	if generated != null and not generated.get_files().is_empty():
		_fail("temporary generated adapters were not cleaned up")
		return

	_cleanup()
	print("GZSCRIPT_COMPILER_RACE_OK")
	quit()


func _module_files() -> Array[String]:
	var path := "res://.godot/gzscript/modules/%s-%s" % [OS.get_name().to_lower(), Engine.get_architecture_name()]
	var directory := DirAccess.open(path)
	if directory == null:
		return []
	var result: Array[String] = []
	for file in directory.get_files():
		if file.get_extension() in ["dll", "dylib", "so"]:
			result.push_back(path.path_join(file))
	return result


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("unable to write fixture: " + path)
		return
	file.store_string(contents)
	file.close()


func _absolute(path: String) -> String:
	return ProjectSettings.globalize_path(path).replace("'", "'\"'\"'")


func _fail(message: String) -> void:
	push_error(message)
	_cleanup()
	quit(1)


func _cleanup() -> void:
	ProjectSettings.set_setting(ZIG_PATH_SETTING, "")
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid", HELPER_PATH, HELPER_PATH + ".uid", WRAPPER_PATH, STARTED_PATH, RELEASE_PATH]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CONTROL_DIR))
