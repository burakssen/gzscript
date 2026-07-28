extends SceneTree

const SCRIPT_PATH := "res://sprite_2d_test.zig"
const INVALID_SCRIPT_PATH := "res://invalid_save_test.zig"
const COPY_PATH := "res://save_copy_test.zig"
const MOVED_PATH := "res://save_as_test.zig"
const RACE_SOURCE_PATH := "res://save_as_race_source.zig"
const RACE_TARGET_PATH := "res://save_as_race_target.zig"
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
	var result := ResourceSaver.save(script, SCRIPT_PATH, ResourceSaver.FLAG_CHANGE_PATH)
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
	if FileAccess.get_file_as_string(SCRIPT_PATH) != script.source_code:
		push_error("Newer Zig source was not persisted before compilation")
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
	result = ResourceSaver.save(script, COPY_PATH)
	if result != OK or script.resource_path != SCRIPT_PATH:
		push_error("Saving a copy changed the Zig resource path")
		_cleanup()
		quit(1)
		return
	if FileAccess.get_file_as_string(COPY_PATH) != script.source_code:
		push_error("Zig save copy did not persist source")
		_cleanup()
		quit(1)
		return
	result = ResourceSaver.save(script, MOVED_PATH, ResourceSaver.FLAG_CHANGE_PATH)
	await process_frame
	if result != OK or script.resource_path != MOVED_PATH:
		push_error("Saving Zig source with FLAG_CHANGE_PATH did not update its resource path")
		_cleanup()
		quit(1)
		return
	if not await _wait_for_compilation():
		return

	var invalid_script := GzScript.new()
	invalid_script.source_code = "pub fn broken( {\n"
	result = ResourceSaver.save(invalid_script, INVALID_SCRIPT_PATH, ResourceSaver.FLAG_CHANGE_PATH)
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

	var moved_while_queued := GzScript.new()
	moved_while_queued.source_code = _source(3, run_id)
	if ResourceSaver.save(moved_while_queued, RACE_SOURCE_PATH, ResourceSaver.FLAG_CHANGE_PATH) != OK:
		push_error("Unable to save queued Save As source")
		_cleanup()
		quit(1)
		return
	if ResourceSaver.save(moved_while_queued, RACE_TARGET_PATH, ResourceSaver.FLAG_CHANGE_PATH) != OK:
		push_error("Unable to move queued Save As source")
		_cleanup()
		quit(1)
		return
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RACE_SOURCE_PATH))
	if not await _wait_for_compilation():
		return
	if moved_while_queued.resource_path != RACE_TARGET_PATH or not moved_while_queued.can_instantiate():
		push_error("Queued Save As compiled the obsolete resource path")
		_cleanup()
		quit(1)
		return

	script.take_over_path("")
	invalid_script.take_over_path("")
	moved_while_queued.take_over_path("")
	_cleanup()
	print("GZSCRIPT_SAVE_OK")
	quit()


func _wait_for_compilation() -> bool:
	await process_frame
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
	if directory == null:
		return 0
	var count := 0
	for file in directory.get_files():
		if file.get_extension() in ["dll", "dylib", "so"]:
			count += 1
	return count


func _source(value: int, run_id: int) -> String:
	return (SCRIPT_SOURCE % value) + "\n// asynchronous save run %d\n" % run_id


func _cleanup() -> void:
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid", INVALID_SCRIPT_PATH, INVALID_SCRIPT_PATH + ".uid", COPY_PATH, COPY_PATH + ".uid", MOVED_PATH, MOVED_PATH + ".uid", RACE_SOURCE_PATH, RACE_SOURCE_PATH + ".uid", RACE_TARGET_PATH, RACE_TARGET_PATH + ".uid"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
