extends SceneTree

const CONTROL_DIR := "res://.godot/gzscript/save_atomic_control"
const TARGET_PATH := CONTROL_DIR + "/target.zig"
const STOP_PATH := CONTROL_DIR + "/stop"
const MISSING_PATH := CONTROL_DIR + "/missing"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_name() == "Windows":
		print("GZSCRIPT_SAVE_ATOMIC_OK")
		quit()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CONTROL_DIR))
	_write(TARGET_PATH, "initial\n")
	var command := "while [ ! -f '%s' ]; do if [ ! -e '%s' ]; then touch '%s'; exit 1; fi; done" % [
		_absolute(STOP_PATH),
		_absolute(TARGET_PATH),
		_absolute(MISSING_PATH),
	]
	var observer := OS.create_process("/bin/sh", PackedStringArray(["-c", command]))
	if observer <= 0:
		_fail("unable to start save observer")
		return

	var script := GzScript.new()
	script.take_over_path("res://save_atomic_source.zig")
	for index in range(5000):
		script.source_code = "// atomic save %d\n" % index
		var result := ResourceSaver.save(script, TARGET_PATH)
		if result != OK:
			OS.kill(observer)
			_fail("atomic save failed: %s" % error_string(result))
			return
	_write(STOP_PATH, "stop\n")
	var deadline := Time.get_ticks_msec() + 5000
	while OS.is_process_running(observer) and Time.get_ticks_msec() < deadline:
		await process_frame
	if OS.is_process_running(observer):
		OS.kill(observer)
		_fail("save observer did not stop")
		return
	if FileAccess.file_exists(MISSING_PATH):
		_fail("saving temporarily removed the destination path")
		return
	if FileAccess.get_file_as_string(TARGET_PATH) != script.source_code:
		_fail("atomic save did not publish the final source")
		return

	script.take_over_path("")
	_cleanup()
	print("GZSCRIPT_SAVE_ATOMIC_OK")
	quit()


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
	for path in [TARGET_PATH, TARGET_PATH + ".uid", STOP_PATH, MISSING_PATH]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CONTROL_DIR))
