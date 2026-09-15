extends SceneTree

# Portable smoke runner: identical semantics on every platform.
# Driven by tests/smoke/run.sh through cold, warm, and recompile stages.
# Expected behavior version travels via GZSCRIPT_SMOKE_EXPECT_VERSION.

const SCRIPT_PATH := "res://smoke.zig"
const RESULT_PATH := "res://smoke-result.json"

var signal_received := false


func _initialize() -> void:
	call_deferred("_run")


func _on_smoke_ready() -> void:
	signal_received = true


func _write_result(values: Dictionary) -> void:
	var file := FileAccess.open(RESULT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("unable to write smoke result")
		quit(1)
		return
	file.store_string(JSON.stringify(values))
	file.close()


func _check(condition: bool, message: String) -> bool:
	if condition:
		return true
	push_error(message)
	quit(1)
	return false


func _run() -> void:
	var expected_version := 1
	if OS.has_environment("GZSCRIPT_SMOKE_EXPECT_VERSION"):
		expected_version = int(OS.get_environment("GZSCRIPT_SMOKE_EXPECT_VERSION"))
	var result := {
		"ready": false, "property": false, "method": false, "godot_api": false,
		"structured_value": false, "string": false, "signal": false,
		"destroy": false, "version": 0,
	}

	var script := load(SCRIPT_PATH) as Script
	if not _check(script != null and script.can_instantiate(), "SMOKE FAILED: SCRIPT_LOAD_FAILURE"):
		return
	print("GZSCRIPT_SMOKE_SCRIPT_LOADED")

	var node := Node.new()
	node.set_script(script)
	node.connect(&"smoke_ready", _on_smoke_ready)
	root.add_child(node)
	await process_frame
	await process_frame

	if not _check(int(node.get("counter")) == 42, "SMOKE FAILED: RUNTIME_FAILURE ready callback"):
		return
	if not _check(int(node.get("version")) == expected_version, "SMOKE FAILED: RUNTIME_FAILURE version"):
		return
	if not _check(node.name == &"SmokeNode", "SMOKE FAILED: ABI_FAILURE godot api call"):
		return
	result["godot_api"] = true
	if not _check(signal_received, "SMOKE FAILED: RUNTIME_FAILURE signal"):
		return
	result["signal"] = true
	result["ready"] = true
	print("GZSCRIPT_SMOKE_READY")

	if not _check(bool(node.get("enabled")), "SMOKE FAILED: ABI_FAILURE bool default"):
		return
	node.set("enabled", false)
	if not _check(not bool(node.get("enabled")), "SMOKE FAILED: ABI_FAILURE bool round-trip"):
		return
	node.set("enabled", true)
	if not _check(is_equal_approx(float(node.get("speed")), 2.5), "SMOKE FAILED: ABI_FAILURE float default"):
		return
	node.set("speed", 7.5)
	if not _check(is_equal_approx(float(node.get("speed")), 7.5), "SMOKE FAILED: ABI_FAILURE float round-trip"):
		return
	node.notification(9002)
	if not _check(int(node.get("counter")) == 49, "SMOKE FAILED: ABI_FAILURE zig reads godot write"):
		return
	result["property"] = true
	print("GZSCRIPT_SMOKE_PROPERTY_OK")

	node.notification(9001)
	if not _check(int(node.get("calls")) == 1, "SMOKE FAILED: RUNTIME_FAILURE method dispatch"):
		return
	result["method"] = true
	print("GZSCRIPT_SMOKE_METHOD_OK")

	if not _check(String(node.get("label")) == "gzscript-smoke", "SMOKE FAILED: ABI_FAILURE string"):
		return
	result["string"] = true
	var point: Vector2 = node.get("point")
	if not _check(point.is_equal_approx(Vector2(1.25, -9.5)), "SMOKE FAILED: ABI_FAILURE vector2"):
		return
	result["structured_value"] = true
	print("GZSCRIPT_SMOKE_VALUE_OK")

	node.queue_free()
	await process_frame
	await process_frame
	if not _check(not is_instance_valid(node), "SMOKE FAILED: SHUTDOWN_FAILURE destroy"):
		return
	result["destroy"] = true
	print("GZSCRIPT_SMOKE_DESTROY_OK")

	result["version"] = expected_version
	_write_result(result)
	print("GZSCRIPT_SMOKE_OK")
	quit()
