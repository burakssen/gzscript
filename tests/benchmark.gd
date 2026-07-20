extends Node2D

# 1. Boids / Particle Physics Simulation (500 particles, 20 steps = 5M interaction calculations)
func bench_boids(particle_count: int, steps: int) -> float:
	var positions: Array[Vector2] = []
	var velocities: Array[Vector2] = []
	positions.resize(particle_count)
	velocities.resize(particle_count)

	for i in range(particle_count):
		positions[i] = Vector2(i * 1.5, i * 2.5)
		velocities[i] = Vector2((i % 10) - 5.0, (i % 7) - 3.0)

	var total_dist := 0.0

	for step in range(steps):
		for i in range(particle_count):
			var pos_i = positions[i]
			var force := Vector2.ZERO
			for j in range(particle_count):
				if i == j:
					continue
				var diff = pos_i - positions[j]
				var dist_sq = diff.length_squared()
				if dist_sq < 10000.0 and dist_sq > 0.0001:
					force += diff / dist_sq
			velocities[i] += force * 0.1
			positions[i] += velocities[i]
			total_dist += positions[i].length()

	return total_dist

# 2. Sorting Benchmark (Quicksort 10,000 elements)
func bench_sort(size: int) -> int:
	var arr: Array[int] = []
	arr.resize(size)
	for i in range(size):
		arr[i] = (i * 1103515245 + 12345) & 0x7FFFFFFF

	_quicksort(arr, 0, size - 1)
	return arr[0] + arr[size - 1]

func _quicksort(arr: Array[int], low: int, high: int) -> void:
	if low < high:
		var p = _partition(arr, low, high)
		_quicksort(arr, low, p - 1)
		_quicksort(arr, p + 1, high)

func _partition(arr: Array[int], low: int, high: int) -> int:
	var pivot = arr[high]
	var i = low - 1
	for j in range(low, high):
		if arr[j] <= pivot:
			i += 1
			var tmp = arr[i]
			arr[i] = arr[j]
			arr[j] = tmp
	var tmp2 = arr[i + 1]
	arr[i + 1] = arr[high]
	arr[high] = tmp2
	return i + 1

# 3. Engine API Call Overhead (100,000 calls)
func bench_api_calls(iterations: int) -> void:
	var target_pos := Vector2(10.0, 20.0)
	for i in range(iterations):
		set_position(target_pos)
		var p := get_position()
		target_pos.x = p.x + 0.001
		target_pos.y = p.y + 0.001

# 4. Batch Node Updates (2,000 nodes)
func bench_batch_nodes(nodes: Array) -> void:
	var count := nodes.size()
	for i in range(count):
		var n = nodes[i] as Node2D
		if n != null:
			n.position = Vector2(i * 1.5, i * 2.5)
			n.rotation += 0.01
			n.visible = (i % 2 == 0)
