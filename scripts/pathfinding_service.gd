class_name PathfindingService
extends RefCounted
## A* по четырёхсвязной сетке (вверх/вниз/влево/вправо) с манхэттенской эвристикой.

const DIRECTIONS = [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]


## Возвращает клетки маршрута БЕЗ стартовой, но с целевой.
## Пустой массив — маршрута нет (или start == goal).
## extra_blocked: Dictionary {Vector2i: true} — дополнительно непроходимые клетки (например, другие роботы).
static func find_path(grid: WarehouseGrid, start: Vector2i, goal: Vector2i, extra_blocked: Dictionary = {}) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if start == goal:
		return result
	if grid.is_blocked(goal) or extra_blocked.has(goal):
		return result

	var open: Array = []  # элементы: [f, g, клетка]
	var came_from: Dictionary = {}
	var g_score: Dictionary = {}
	var closed: Dictionary = {}
	g_score[start] = 0
	open.append([_heuristic(start, goal), 0, start])

	while not open.is_empty():
		# Выбираем элемент с минимальным f; при равенстве — с большим g (ближе к цели).
		var best := 0
		for i in range(1, open.size()):
			var a: Array = open[i]
			var b: Array = open[best]
			if a[0] < b[0] or (a[0] == b[0] and a[1] > b[1]):
				best = i
		var current: Array = open[best]
		open.remove_at(best)
		var cell: Vector2i = current[2]
		if closed.has(cell):
			continue
		if cell == goal:
			return _reconstruct(came_from, cell, start)
		closed[cell] = true

		for dir in DIRECTIONS:
			var n: Vector2i = cell + dir
			if closed.has(n) or grid.is_blocked(n) or extra_blocked.has(n):
				continue
			var new_g: int = int(g_score[cell]) + 1
			if not g_score.has(n) or new_g < int(g_score[n]):
				g_score[n] = new_g
				came_from[n] = cell
				open.append([new_g + _heuristic(n, goal), new_g, n])
	return result


static func _heuristic(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


static func _reconstruct(came_from: Dictionary, goal: Vector2i, start: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var c: Vector2i = goal
	while c != start:
		path.append(c)
		c = came_from[c]
	path.reverse()
	return path
