extends SceneTree

const FIXTURE_DIR := "res://.godot/gzscript/compiler_output"
const SCRIPT_PATH := FIXTURE_DIR + "/main.zig"
const WRAPPER_PATH := FIXTURE_DIR + "/zig-wrapper.sh"
const VERSION_WRAPPER_PATH := FIXTURE_DIR + "/zig-version-wrapper.sh"
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
		print("GZSCRIPT_COMPILER_OUTPUT_OK")
		quit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	_write(SCRIPT_PATH, SCRIPT_SOURCE)
	_write(VERSION_WRAPPER_PATH, """#!/bin/sh
dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\000' x >&2
exit 1
""")
	if OS.execute("chmod", PackedStringArray(["+x", ProjectSettings.globalize_path(VERSION_WRAPPER_PATH)])) != 0:
		_fail("unable to make version output wrapper executable")
		return
	ProjectSettings.set_setting(ZIG_PATH_SETTING, ProjectSettings.globalize_path(VERSION_WRAPPER_PATH))
	if GzBuildManager.compile_path(SCRIPT_PATH):
		_fail("version diagnostic wrapper unexpectedly compiled")
		return
	var diagnostics := GzBuildManager.get_last_diagnostics()
	if diagnostics.length() > 70_000 or not diagnostics.contains("output truncated"):
		_fail("Zig version diagnostics were not bounded")
		return

	_write(WRAPPER_PATH, """#!/bin/sh
if [ "$1" = version ]; then
	printf '0.16.0\\n'
	exit 0
fi
dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\000' x >&2
exit 1
""")
	if OS.execute("chmod", PackedStringArray(["+x", ProjectSettings.globalize_path(WRAPPER_PATH)])) != 0:
		_fail("unable to make compiler output wrapper executable")
		return
	ProjectSettings.set_setting(ZIG_PATH_SETTING, ProjectSettings.globalize_path(WRAPPER_PATH))
	if GzBuildManager.compile_path(SCRIPT_PATH):
		_fail("diagnostic wrapper unexpectedly compiled")
		return
	diagnostics = GzBuildManager.get_last_diagnostics()
	if diagnostics.length() > 70_000:
		_fail("compiler diagnostics exceeded the retention limit")
		return
	if not diagnostics.contains("output truncated"):
		_fail("truncated compiler diagnostics were not identified")
		return
	_cleanup()
	print("GZSCRIPT_COMPILER_OUTPUT_OK")
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
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid", WRAPPER_PATH, VERSION_WRAPPER_PATH]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
