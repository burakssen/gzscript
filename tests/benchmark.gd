extends Node2D

var mode := 0
var result := 0.0
var elapsed_usec := 0


func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec()
	match mode:
		1:
			result = bench_boids(500, 20)
		2:
			result = bench_sort(10000)
		3:
			bench_api_calls(100000)
			result = position.x + position.y
		4:
			bench_batch_nodes()
			result = 2000.0
		_:
			return
	elapsed_usec = Time.get_ticks_usec() - started
	mode = 0


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

# 4. Batch Node Updates (2,000 sibling nodes)
func bench_batch_nodes() -> void:
	var parent := get_parent()
	var index := 0
	for child in parent.get_children():
		if child == self or not child is Node2D:
			continue
		var node := child as Node2D
		node.position = Vector2(index * 1.5, index * 2.5)
		node.rotation = index * 0.01
		node.visible = (index % 2 == 0)
		index += 1
