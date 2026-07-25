extends SceneTree

const SCRIPT_PATH := "res://sprite_2d_test.zig"
const INVALID_SCRIPT_PATH := "res://invalid_save_test.zig"
const SCRIPT_SOURCE := """const gd = @import("godot");

pub const Base = gd.Sprite2D;
const Self = @This();

base: Base,
value: i64 = %d,

pub const exports = .{ .value = gd.property(.{}) };

pub fn init(ctx: gd.InitContext) !Self {
    return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var before := _module_count()
	var run_id := Time.get_ticks_usec()
	var script := GzScript.new()
	script.source_code = _source(1, run_id)
	var result := ResourceSaver.save(script, SCRIPT_PATH)
	if result != OK:
		push_error("New Zig script failed to save: %s" % error_string(result))
		_cleanup()
		quit(1)
		return
	if not GzBuildManager.is_compiling():
		push_error("Saving a cold Zig script did not start asynchronous compilation")
		_cleanup()
		quit(1)
		return

	# The active first build must not publish after this newer save.
	script.source_code = _source(2, run_id)
	result = ResourceSaver.save(script, SCRIPT_PATH)
	if result != OK:
		push_error("Newer Zig script failed to save: %s" % error_string(result))
		_cleanup()
		quit(1)
		return
	if not await _wait_for_compilation():
		return
	if not script.can_instantiate():
		push_error("Newest saved Zig script did not compile")
		_cleanup()
		quit(1)
		return
	var instance := Sprite2D.new()
	instance.set_script(script)
	if instance.get("value") != 2:
		push_error("Stale asynchronous compilation replaced the newest source")
		instance.free()
		_cleanup()
		quit(1)
		return
	instance.free()
	if _module_count() != before + 1:
		push_error("Stale asynchronous output was published")
		_cleanup()
		quit(1)
		return

	var invalid_script := GzScript.new()
	invalid_script.source_code = "pub fn broken( {\n"
	result = ResourceSaver.save(invalid_script, INVALID_SCRIPT_PATH)
	if result != OK:
		push_error("Persisting invalid Zig source reported a save failure: %s" % error_string(result))
		_cleanup()
		quit(1)
		return
	if not await _wait_for_compilation():
		return
	if invalid_script.can_instantiate():
		push_error("Invalid saved Zig source was marked valid")
		_cleanup()
		quit(1)
		return
	if FileAccess.get_file_as_string(INVALID_SCRIPT_PATH) != invalid_script.source_code:
		push_error("Invalid Zig source was not persisted")
		_cleanup()
		quit(1)
		return

	_cleanup()
	print("GZSCRIPT_SAVE_OK")
	quit()


func _wait_for_compilation() -> bool:
	var deadline := Time.get_ticks_msec() + 60_000
	while Time.get_ticks_msec() < deadline:
		if not GzBuildManager.is_compiling():
			return true
		await create_timer(0.01).timeout
	push_error("Timed out waiting for asynchronous Zig compilation")
	_cleanup()
	quit(1)
	return false


func _module_count() -> int:
	var platform := OS.get_name().to_lower()
	var path := "res://.godot/gzscript/modules/%s-%s" % [platform, Engine.get_architecture_name()]
	var directory := DirAccess.open(path)
	return 0 if directory == null else directory.get_files().size()


func _source(value: int, run_id: int) -> String:
	return (SCRIPT_SOURCE % value) + "\n// asynchronous save run %d\n" % run_id


func _cleanup() -> void:
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid", INVALID_SCRIPT_PATH, INVALID_SCRIPT_PATH + ".uid"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
