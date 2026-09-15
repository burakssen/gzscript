extends SceneTree

# Phase 1 minimal lifecycle regression fixture.
#
# Minimum trigger sequence:
#   load gzscript -> load one Zig script -> instantiate -> destroy -> quit
# plus the generation regression:
#   compile v1 -> instance A -> recompile v2 -> A still uses v1, B uses v2.
#
# Behavior is driven through explicit Object.notification() calls (forwarded
# to the Zig module), so the test is fully deterministic and needs no frame
# timing. Any premature module unload, use-after-free, or shutdown race
# aborts here instead of hiding inside the full suite.

const FIXTURE_DIR := "res://.godot/gzscript/lifecycle"
const SCRIPT_PATH := FIXTURE_DIR + "/main.zig"
const PING := 9001
const SOURCE_V1 := """const gd = @import("godot");

pub const Base = gd.Node;
const Self = @This();

base: Base,
pings: i64 = 0,

pub const exports = .{ .pings = gd.property(.{}) };

pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}

pub fn notification(self: *Self, what: i32) !void {
	if (what == 9001) self.pings += 1;
}
"""
const SOURCE_V2 := """const gd = @import("godot");

pub const Base = gd.Node;
const Self = @This();

base: Base,
pings: i64 = 0,
generation: i64 = 2,

pub const exports = .{
	.pings = gd.property(.{}),
	.generation = gd.property(.{}),
};

pub fn init(ctx: gd.InitContext) !Self {
	return .{ .base = .{ .owner = ctx.owner } };
}

pub fn notification(self: *Self, what: i32) !void {
	if (what == 9001) self.pings += 100;
}
"""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
	# Phase 1: single script, single module, single instance executing code.
	_write(SCRIPT_PATH, SOURCE_V1)
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "v1 compile failed"):
		return
	var script := load(SCRIPT_PATH) as Script
	if not _require(script != null and script.can_instantiate(), "v1 script cannot instantiate"):
		return
	var first := Node.new()
	first.set_script(script)
	root.add_child(first)
	first.notification(PING)
	if not _require(int(first.get("pings")) == 1, "v1 instance did not execute module code"):
		return
	# Phase 2: many instances sharing one module, destroyed LIFO.
	var instances: Array[Node] = []
	for i in 100:
		var node := Node.new()
		node.set_script(script)
		root.add_child(node)
		instances.push_back(node)
	for node in instances:
		node.notification(PING)
		if not _require(int(node.get("pings")) == 1, "shared-module instance did not execute"):
			return
	while not instances.is_empty():
		var node: Node = instances.pop_back()
		node.queue_free()
	await process_frame
	first.notification(PING)
	if not _require(int(first.get("pings")) == 2, "first instance broke after sibling churn"):
		return
	# Phase 3: reload while an instance is alive (module generations).
	_write(SCRIPT_PATH, SOURCE_V2)
	if not _require(GzBuildManager.compile_path(SCRIPT_PATH), "v2 recompile failed"):
		return
	script = load(SCRIPT_PATH) as Script
	# Old instance must still execute the retired v1 module (+1).
	first.notification(PING)
	if not _require(int(first.get("pings")) == 3, "old instance lost its pinned v1 module"):
		return
	var second := Node.new()
	second.set_script(script)
	root.add_child(second)
	# New instance uses v2 (+100).
	second.notification(PING)
	if not _require(int(second.get("pings")) == 100, "new instance did not use v2 module"):
		return
	second.queue_free()
	first.queue_free()
	script = null
	if OS.get_environment("GZ_LIFECYCLE_ABANDON") == "1":
		# Shutdown permutation: instances and script resources die with the
		# scene tree instead of being freed explicitly. The pinned modules
		# must still unload exactly once with exit code 0.
		_cleanup()
		print("GZSCRIPT_LIFECYCLE_OK")
		quit()
		return
	await process_frame
	await process_frame
	_cleanup()
	print("GZSCRIPT_LIFECYCLE_OK")
	quit()


func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("unable to write fixture: " + path)
		return
	file.store_string(contents)
	file.close()


func _require(condition: bool, message: String) -> bool:
	if condition:
		return true
	_fail(message)
	return false


func _fail(message: String) -> void:
	push_error(message)
	_cleanup()
	quit(1)


func _cleanup() -> void:
	for path in [SCRIPT_PATH, SCRIPT_PATH + ".uid"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(FIXTURE_DIR))
