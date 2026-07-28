extends SceneTree

const FIXTURE_DIR := "res://.godot/gzscript/compiler_version"
const SCRIPT_PATH := FIXTURE_DIR + "/main.zig"
const WRAPPER_PATH := FIXTURE_DIR + "/zig-wrapper.sh"
const INVOKED_PATH := FIXTURE_DIR + "/build-invoked"
const ZIG_PATH_SETTING := "gzscript/compiler/zig_path"
const SCRIPT_SOURCE := """const gd = @import("godot");
pub const Base = gd.Node;
const Self = @This();
base: Base,
pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _initialize() -> void:
	if OS.get_name() == "Windows":
		print("GZSCRIPT_COMPILER_VERSION_OK")
		quit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	_write(SCRIPT_PATH, SCRIPT_SOURCE)
	_write(WRAPPER_PATH, """#!/bin/sh
if [ "$1" = version ]; then
	printf '0.15.2\\n'
	exit 0
fi
touch '%s'
exit 1
""" % ProjectSettings.globalize_path(INVOKED_PATH))
	if OS.execute("chmod", PackedStringArray(["+x", ProjectSettings.globalize_path(WRAPPER_PATH)])) != 0:
		_fail("unable to make compiler version wrapper executable")
		return
	ProjectSettings.set_setting(ZIG_PATH_SETTING, ProjectSettings.globalize_path(WRAPPER_PATH))
	if GzBuildManager.compile_path(SCRIPT_PATH):
		_fail("incompatible Zig compiler unexpectedly compiled")
		return
	var diagnostics := GzBuildManager.get_last_diagnostics()
	if not diagnostics.contains("Zig 0.15.2") or not diagnostics.contains("0.16"):
		_fail("incompatible Zig compiler produced no actionable diagnostic")
		return
	if FileAccess.file_exists(INVOKED_PATH):
		_fail("incompatible Zig compiler reached build-lib")
		return
	_cleanup()
	print("GZSCRIPT_COMPILER_VERSION_OK")
	quit()


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("unable to write fixture: " + path)
		return
	file.store_string(contents)
	file.close()


func _fail(message: String) -> void:
	push_error(message)
	_cleanup()
	quit(1)


func _cleanup() -> void:
	ProjectSettings.set_setting(ZIG_PATH_SETTING, "")
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid", WRAPPER_PATH, INVOKED_PATH]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
