extends SceneTree

const FIXTURE_DIR := "res://.godot/gzscript/compiler_tree"
const CONTROL_DIR := "res://.godot/gzscript/compiler_tree_control"
const SCRIPT_PATH := FIXTURE_DIR + "/main.zig"
const WRAPPER_PATH := CONTROL_DIR + "/zig-wrapper.sh"
const CHILD_PID_PATH := CONTROL_DIR + "/child_pid"
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
	call_deferred("_run")


func _run() -> void:
	if OS.get_name() == "Windows":
		print("GZSCRIPT_COMPILER_TREE_READY")
		quit()
		return
	var real_zig := OS.get_environment("GZSCRIPT_ZIG_PATH")
	if real_zig.is_empty():
		_fail("GZSCRIPT_ZIG_PATH is required")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTROL_DIR))
	_write(SCRIPT_PATH, SCRIPT_SOURCE)
	_write(WRAPPER_PATH, """#!/bin/sh
if [ "$1" = version ]; then
	exec '%s' "$@"
fi
nohup sh -c 'trap "" HUP TERM; sleep 30' >/dev/null 2>&1 &
printf '%%s\n' "$!" > '%s'
wait
""" % [_shell_quote(real_zig), _absolute(CHILD_PID_PATH)])
	if OS.execute("chmod", PackedStringArray(["+x", _absolute(WRAPPER_PATH)])) != 0:
		_fail("unable to make Zig wrapper executable")
		return
	ProjectSettings.set_setting(ZIG_PATH_SETTING, ProjectSettings.globalize_path(WRAPPER_PATH))
	var script := GzScript.new()
	script.source_code = SCRIPT_SOURCE
	if ResourceSaver.save(script, SCRIPT_PATH, ResourceSaver.FLAG_CHANGE_PATH) != OK:
		_fail("unable to save compiler tree fixture")
		return
	var deadline := Time.get_ticks_msec() + 10_000
	while not FileAccess.file_exists(CHILD_PID_PATH) and Time.get_ticks_msec() < deadline:
		GzBuildManager.pump()
		await process_frame
	if not FileAccess.file_exists(CHILD_PID_PATH):
		_fail("compiler wrapper did not spawn its child")
		return
	print("GZSCRIPT_COMPILER_TREE_READY")
	quit()


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("unable to write fixture: " + path)
		return
	file.store_string(contents)
	file.close()


func _absolute(path: String) -> String:
	return _shell_quote(ProjectSettings.globalize_path(path))


func _shell_quote(path: String) -> String:
	return path.replace("'", "'\"'\"'")


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
