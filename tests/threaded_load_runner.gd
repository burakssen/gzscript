extends SceneTree

const SCRIPT_PATH := "res://threaded_load_test.zig"
const SCRIPT_SOURCE := """const gd = @import("godot");
pub const Base = gd.Node;
const Self = @This();
base: Base,
pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}
"""


func _initialize() -> void:
	var file := FileAccess.open(SCRIPT_PATH, FileAccess.WRITE)
	assert(file != null)
	file.store_string(SCRIPT_SOURCE)
	file.close()
	call_deferred("_run")


func _run() -> void:
	var error := ResourceLoader.load_threaded_request(SCRIPT_PATH, "", false, ResourceLoader.CACHE_MODE_IGNORE)
	if error != OK:
		_fail("Unable to start threaded Zig resource load")
		return
	var status := ResourceLoader.load_threaded_get_status(SCRIPT_PATH)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await process_frame
		status = ResourceLoader.load_threaded_get_status(SCRIPT_PATH)
	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var resource := ResourceLoader.load_threaded_get(SCRIPT_PATH)
		if resource != null:
			_fail("Threaded Zig resource loading returned a silently invalid resource")
			return
	elif status != ResourceLoader.THREAD_LOAD_FAILED:
		_fail("Threaded Zig resource loading ended in an unexpected state")
		return
	_cleanup()
	print("GZSCRIPT_THREADED_LOAD_OK")
	quit()


func _fail(message: String) -> void:
	push_error(message)
	_cleanup()
	quit(1)


func _cleanup() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRIPT_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SCRIPT_PATH + ".uid"))
