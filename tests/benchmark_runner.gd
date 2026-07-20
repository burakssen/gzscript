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
	print("[*] Running GDScript Workloads...")
	var gd_node := Node2D.new()
	gd_node.set_script(gdscript_bench_script)
	root.add_child(gd_node)

	# Warmup
	gd_node.bench_boids(50, 2)

	# Workload 1: Boids Physics (GDScript)
	var t0 := Time.get_ticks_usec()
	gd_node.bench_boids(500, 20)
	var gd_boids_us := Time.get_ticks_usec() - t0

	# Workload 2: QuickSort (GDScript)
	t0 = Time.get_ticks_usec()
	gd_node.bench_sort(10000)
	var gd_sort_us := Time.get_ticks_usec() - t0

	# Workload 3: API Call Overhead (GDScript)
	t0 = Time.get_ticks_usec()
	gd_node.bench_api_calls(100000)
	var gd_api_us := Time.get_ticks_usec() - t0

	# Workload 4: Batch Node Updates (GDScript - 2,000 nodes)
	var batch_container := Node2D.new()
	root.add_child(batch_container)
	var children: Array[Node2D] = []
	for i in range(2000):
		var child := Node2D.new()
		batch_container.add_child(child)
		children.append(child)

	t0 = Time.get_ticks_usec()
	gd_node.bench_batch_nodes(children)
	var gd_batch_us := Time.get_ticks_usec() - t0

	gd_node.queue_free()

	# --- 2. Zig (gzscript) Workloads ---
	print("[*] Running Zig (gzscript) Workloads...")
	var zig_node := Node2D.new()
	zig_node.set_script(zig_bench_script)
	root.add_child(zig_node)
	await process_frame

	# Workload 1: Boids Physics (Zig)
	t0 = Time.get_ticks_usec()
	zig_node.set("mode", 1)
	await process_frame
	var zig_boids_us := Time.get_ticks_usec() - t0

	# Workload 2: QuickSort (Zig)
	t0 = Time.get_ticks_usec()
	zig_node.set("mode", 2)
	await process_frame
	var zig_sort_us := Time.get_ticks_usec() - t0

	# Workload 3: API Call Overhead (Zig)
	t0 = Time.get_ticks_usec()
	zig_node.set("mode", 3)
	await process_frame
	var zig_api_us := Time.get_ticks_usec() - t0

	# Workload 4: Batch Node Updates (Zig - 2,000 nodes)
	t0 = Time.get_ticks_usec()
	zig_node.set("mode", 4)
	await process_frame
	var zig_batch_us := Time.get_ticks_usec() - t0

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
