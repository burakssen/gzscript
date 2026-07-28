extends SceneTree

const FIXTURE_DIR := "res://.godot/gzscript/compiler_lock"
const CONTROL_DIR := "res://.godot/gzscript/compiler_lock_control"
const SCRIPT_PATH := FIXTURE_DIR + "/main.zig"
const WRAPPER_PATH := CONTROL_DIR + "/zig-wrapper.sh"
const COUNT_PATH := CONTROL_DIR + "/count"
const COUNT_LOCK_PATH := CONTROL_DIR + "/count.lock"
var worker_pids: Array[int] = []
const SCRIPT_SOURCE := """const gd = @import("godot");

pub const Base = gd.Node;
const Self = @This();

base: Base,
value: i64 = 1,

pub const exports = .{ .value = gd.property(.{}) };

pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_cmdline_user_args() == PackedStringArray(["worker"]):
		var success := GzBuildManager.compile_path(SCRIPT_PATH)
		quit(0 if success else 1)
		return
	if OS.get_name() == "Windows":
		print("GZSCRIPT_COMPILER_LOCK_OK")
		quit()
		return

	var real_zig := OS.get_environment("GZSCRIPT_ZIG_PATH")
	if real_zig.is_empty():
		_fail("GZSCRIPT_ZIG_PATH is required")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTROL_DIR))
	_write(SCRIPT_PATH, SCRIPT_SOURCE + "\n// lock run %d\n" % Time.get_ticks_usec())
	_write(WRAPPER_PATH, """#!/bin/sh
if [ "$1" = version ]; then
	exec '%s' "$@"
fi
while ! mkdir '%s' 2>/dev/null; do sleep 0.01; done
count=0
if [ -f '%s' ]; then read count < '%s'; fi
count=$((count + 1))
printf '%%s\n' "$count" > '%s'
rmdir '%s'
sleep 1
exec '%s' "$@"
""" % [_shell_quote(real_zig), _absolute(COUNT_LOCK_PATH), _absolute(COUNT_PATH), _absolute(COUNT_PATH), _absolute(COUNT_PATH), _absolute(COUNT_LOCK_PATH), _shell_quote(real_zig)])
	if OS.execute("chmod", PackedStringArray(["+x", _absolute(WRAPPER_PATH)])) != 0:
		_fail("unable to make Zig wrapper executable")
		return

	OS.set_environment("GZSCRIPT_ZIG_PATH", ProjectSettings.globalize_path(WRAPPER_PATH))
	var arguments := PackedStringArray([
		"--headless",
		"--path",
		ProjectSettings.globalize_path("res://"),
		"--script",
		ProjectSettings.globalize_path("res://tests/compiler_lock_runner.gd"),
		"--",
		"worker",
	])
	var first := OS.create_process(OS.get_executable_path(), arguments)
	var second := OS.create_process(OS.get_executable_path(), arguments)
	for pid in [first, second]:
		if pid > 0:
			worker_pids.push_back(pid)
	OS.set_environment("GZSCRIPT_ZIG_PATH", real_zig)
	if first <= 0 or second <= 0:
		_fail("unable to start concurrent compiler workers")
		return

	var deadline := Time.get_ticks_msec() + 60_000
	while (OS.is_process_running(first) or OS.is_process_running(second)) and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	if OS.is_process_running(first) or OS.is_process_running(second):
		OS.kill(first)
		OS.kill(second)
		_fail("concurrent compiler workers timed out")
		return
	if OS.get_process_exit_code(first) != 0 or OS.get_process_exit_code(second) != 0:
		_fail("a concurrent compiler worker failed")
		return
	if not FileAccess.file_exists(COUNT_PATH) or FileAccess.get_file_as_string(COUNT_PATH).strip_edges() != "1":
		_fail("concurrent processes compiled the same cache key more than once")
		return

	_cleanup()
	print("GZSCRIPT_COMPILER_LOCK_OK")
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
	_cleanup()
	quit(1)


func _cleanup() -> void:
	for pid in worker_pids:
		if OS.is_process_running(pid):
			var command := """terminate_tree() {
	for child in $(pgrep -P "$1" 2>/dev/null); do terminate_tree "$child"; done
	kill -9 "$1" 2>/dev/null || true
}
terminate_tree %d
""" % pid
			OS.execute("/bin/sh", PackedStringArray(["-c", command]))
			OS.kill(pid)
	worker_pids.clear()
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid", WRAPPER_PATH, COUNT_PATH]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(COUNT_LOCK_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CONTROL_DIR))
