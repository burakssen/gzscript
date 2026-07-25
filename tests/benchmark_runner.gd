extends SceneTree

var gdscript_bench_script: Script
var zig_bench_script: Script


func _initialize() -> void:
	call_deferred("_run_benchmarks")


func _run_benchmarks() -> void:
	print("\n" + "=".repeat(80))
	print("          COMPREHENSIVE GZSCRIPT (ZIG) vs GDSCRIPT PROFILING SUITE       ")
	print("=".repeat(80))

	# Load scripts
	gdscript_bench_script = load("res://tests/benchmark.gd") as Script
	if gdscript_bench_script == null:
		push_error("Failed to load res://tests/benchmark.gd")
		quit(1)
		return

	zig_bench_script = load("res://tests/benchmark.zig") as Script
	if zig_bench_script == null:
		push_error("Failed to load res://tests/benchmark.zig")
		quit(1)
		return

	# --- 1. GDScript Workloads ---
	print("[BENCHMARK] Running GDScript workloads...")
	var gd_node := Node2D.new()
	gd_node.set_script(gdscript_bench_script)
	root.add_child(gd_node)
	await process_frame

	# Workload 1: Boids Physics (GDScript)
	var gd_boids_us := await _measure_workload(gd_node, 1, "GDScript boids")
	if gd_boids_us < 0:
		return

	# Workload 2: QuickSort (GDScript)
	var gd_sort_us := await _measure_workload(gd_node, 2, "GDScript sort")
	if gd_sort_us < 0:
		return

	# Workload 3: API Call Overhead (GDScript)
	var gd_api_us := await _measure_workload(gd_node, 3, "GDScript API calls")
	if gd_api_us < 0:
		return

	# Workload 4: Batch Node Updates (GDScript - 2,000 nodes)
	var batch_container := _create_batch_container()
	gd_node.reparent(batch_container)
	var gd_batch_us := await _measure_workload(gd_node, 4, "GDScript batch updates")
	if gd_batch_us < 0 or not _verify_batch(batch_container):
		return

	gd_node.free()
	batch_container.free()

	# --- 2. Zig (gzscript) Workloads ---
	print("[BENCHMARK] Running Zig workloads...")
	var zig_node := Node2D.new()
	zig_node.set_script(zig_bench_script)
	root.add_child(zig_node)
	await process_frame

	# Workload 1: Boids Physics (Zig)
	var zig_boids_us := await _measure_workload(zig_node, 1, "Zig boids")
	if zig_boids_us < 0:
		return

	# Workload 2: QuickSort (Zig)
	var zig_sort_us := await _measure_workload(zig_node, 2, "Zig sort")
	if zig_sort_us < 0:
		return

	# Workload 3: API Call Overhead (Zig)
	var zig_api_us := await _measure_workload(zig_node, 3, "Zig API calls")
	if zig_api_us < 0:
		return

	# Workload 4: Batch Node Updates (Zig - 2,000 nodes)
	batch_container = _create_batch_container()
	zig_node.reparent(batch_container)
	var zig_batch_us := await _measure_workload(zig_node, 4, "Zig batch updates")
	if zig_batch_us < 0 or not _verify_batch(batch_container):
		return

	zig_node.queue_free()
	batch_container.queue_free()

	# --- 3. Report Generation ---
	print("\n" + "-".repeat(80))
	print("%-35s | %-14s | %-14s | %-10s" % ["Workload Category", "GDScript (us)", "Zig Script (us)", "Speedup"])
	print("-".repeat(80))

	var boids_speedup := float(gd_boids_us) / float(max(zig_boids_us, 1))
	var sort_speedup := float(gd_sort_us) / float(max(zig_sort_us, 1))
	var api_speedup := float(gd_api_us) / float(max(zig_api_us, 1))
	var batch_speedup := float(gd_batch_us) / float(max(zig_batch_us, 1))

	print("%-35s | %12d us | %12d us | %8.2fx" % ["1. Particle Physics (500 boids x 20)", gd_boids_us, zig_boids_us, boids_speedup])
	print("%-35s | %12d us | %12d us | %8.2fx" % ["2. QuickSort Algorithm (10k items)", gd_sort_us, zig_sort_us, sort_speedup])
	print("%-35s | %12d us | %12d us | %8.2fx" % ["3. API Method Calls (100k calls)", gd_api_us, zig_api_us, api_speedup])
	print("%-35s | %12d us | %12d us | %8.2fx" % ["4. Batch Node Updates (2k nodes)", gd_batch_us, zig_batch_us, batch_speedup])
	print("-".repeat(80))

	print("\n>> PROFILING SUMMARY & ARCHITECTURAL HIGHLIGHTS:")
	print("   - Heavy Computation (Boids): Zig is %.2fx faster" % boids_speedup)
	print("   - Algorithmic Logic (QuickSort): Zig is %.2fx faster" % sort_speedup)
	print("   - GDExtension API Boundary Overhead: GDScript is %.2fx faster" % (1.0 / api_speedup if api_speedup < 1.0 else api_speedup))
	print("=".repeat(80) + "\n")

	print("GZSCRIPT_PROFILING_COMPLETE")
	quit(0)


func _run_workload(node: Node2D, mode: int, label: String) -> int:
	node.set("result", 0.0)
	node.set("elapsed_usec", 0)
	node.set("mode", mode)
	var deadline := Time.get_ticks_msec() + 60_000
	while node.get("mode") != 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	if node.get("mode") != 0:
		push_error("Benchmark workload did not complete: " + label)
		quit(1)
		return -1
	if float(node.get("result")) <= 0.0:
		push_error("Benchmark workload produced an invalid result: " + label)
		quit(1)
		return -1
	var elapsed := int(node.get("elapsed_usec"))
	if elapsed <= 0:
		push_error("Benchmark workload produced an invalid duration: " + label)
		quit(1)
		return -1
	return elapsed


func _measure_workload(node: Node2D, mode: int, label: String) -> int:
	if mode == 4:
		_reset_batch(node.get_parent())
	if await _run_workload(node, mode, label + " warmup") < 0:
		return -1
	var samples: Array[int] = []
	for _sample in range(5):
		if mode == 4:
			_reset_batch(node.get_parent())
		var elapsed := await _run_workload(node, mode, label)
		if elapsed < 0:
			return -1
		samples.push_back(elapsed)
	samples.sort()
	return samples[samples.size() / 2]


func _create_batch_container() -> Node2D:
	var container := Node2D.new()
	root.add_child(container)
	for _index in range(2000):
		container.add_child(Node2D.new())
	return container


func _reset_batch(container: Node2D) -> void:
	var nodes := container.get_children()
	for index in range(nodes.size() - 1):
		var node := nodes[index] as Node2D
		node.position = Vector2(-1.0, -1.0)
		node.rotation = -1.0
		node.visible = true


func _verify_batch(container: Node2D) -> bool:
	var nodes := container.get_children()
	var benchmark := nodes.back() as Node2D
	if nodes.size() != 2001 or benchmark == null or int(benchmark.get("result")) != 2000:
		push_error("Batch benchmark did not contain exactly 2,000 data nodes")
		quit(1)
		return false
	for index in [0, 999, 1999]:
		var node := nodes[index] as Node2D
		if node == null or not node.position.is_equal_approx(Vector2(index * 1.5, index * 2.5)) or not is_equal_approx(node.rotation, index * 0.01) or node.visible != (index % 2 == 0):
			push_error("Batch benchmark did not update all 2,000 nodes")
			quit(1)
			return false
	return true
