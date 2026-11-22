class_name WarehouseGrid
extends Node3D
## Карта склада: размеры, препятствия, точки назначения, зарядная станция,
## преобразование «ячейка <-> мировые координаты» и процедурная 3D-визуализация.
## Центр карты совпадает с началом мировых координат; ось Y клеток соответствует оси Z сцены.

const WIDTH := 24
const HEIGHT := 16
const CELL := 1.0

var shelf_rects: Array[Rect2i] = [
	Rect2i(4, 3, 6, 2), Rect2i(14, 3, 6, 2),
	Rect2i(4, 8, 6, 2), Rect2i(14, 8, 6, 2),
	Rect2i(10, 12, 4, 1),
]
var crates: Array[Vector2i] = [Vector2i(11, 6), Vector2i(12, 6), Vector2i(2, 10), Vector2i(21, 10)]
var destinations: Dictionary = {
	"A": Vector2i(2, 6),
	"B": Vector2i(21, 6),
	"C": Vector2i(11, 1),
	"D": Vector2i(21, 13),
	"E": Vector2i(11, 10),
}
var charger_cell := Vector2i(1, 14)
var initial_robot_cells: Array[Vector2i] = [
	Vector2i(3, 14), Vector2i(5, 14), Vector2i(7, 14), Vector2i(9, 14), Vector2i(11, 14),
]

var _blocked: Dictionary = {}  # Vector2i -> название препятствия
var _hover: MeshInstance3D


# ---------- Логика карты ----------

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < WIDTH and c.y < HEIGHT


func is_blocked(c: Vector2i) -> bool:
	return not in_bounds(c) or _blocked.has(c)


func obstacle_name(c: Vector2i) -> String:
	if not in_bounds(c):
		return "вне карты"
	return str(_blocked.get(c, ""))


func cell_to_world(c: Vector2i) -> Vector3:
	return Vector3((c.x - WIDTH * 0.5 + 0.5) * CELL, 0.0, (c.y - HEIGHT * 0.5 + 0.5) * CELL)


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CELL + WIDTH * 0.5), floori(p.z / CELL + HEIGHT * 0.5))


## «точка A», «зарядная станция» или пустая строка.
func place_name(c: Vector2i) -> String:
	if c == charger_cell:
		return "зарядная станция"
	for key in destinations:
		if destinations[key] == c:
			return "точка " + str(key)
	return ""


func cell_label(c: Vector2i) -> String:
	var base := "(%d, %d)" % [c.x, c.y]
	var place := place_name(c)
	return base if place == "" else "%s [%s]" % [base, place]


func _register_obstacles() -> void:
	_blocked.clear()
	for rect in shelf_rects:
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				_blocked[Vector2i(x, y)] = "стеллаж"
	for c in crates:
		_blocked[c] = "препятствие (ящики)"


# ---------- 3D-визуализация ----------

func build() -> void:
	_register_obstacles()
	_build_floor()
	_build_grid_lines()
	_build_walls()
	_build_obstacles()
	_build_destinations()
	_build_charger()
	_build_hover()


func _build_floor() -> void:
	VisualUtils.add_box(self, Vector3(WIDTH * CELL, 0.2, HEIGHT * CELL), Vector3(0, -0.1, 0), Color(0.17, 0.19, 0.23))
	VisualUtils.add_box(self, Vector3(WIDTH * CELL + 4.0, 0.3, HEIGHT * CELL + 4.0), Vector3(0, -0.35, 0), Color(0.07, 0.08, 0.10))


func _build_grid_lines() -> void:
	var im := ImmediateMesh.new()
	var mat := VisualUtils.material(Color(0.45, 0.55, 0.68, 0.45), 0.0, true)
	var x0 := -WIDTH * CELL * 0.5
	var z0 := -HEIGHT * CELL * 0.5
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for i in range(WIDTH + 1):
		im.surface_add_vertex(Vector3(x0 + i * CELL, 0.012, z0))
		im.surface_add_vertex(Vector3(x0 + i * CELL, 0.012, -z0))
	for j in range(HEIGHT + 1):
		im.surface_add_vertex(Vector3(x0, 0.012, z0 + j * CELL))
		im.surface_add_vertex(Vector3(-x0, 0.012, z0 + j * CELL))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	add_child(mi)


func _build_walls() -> void:
	var col := Color(0.38, 0.42, 0.50)
	var hw := WIDTH * CELL * 0.5
	var hh := HEIGHT * CELL * 0.5
	VisualUtils.add_box(self, Vector3(WIDTH * CELL + 0.6, 0.6, 0.3), Vector3(0, 0.3, -hh - 0.15), col)
	VisualUtils.add_box(self, Vector3(WIDTH * CELL + 0.6, 0.6, 0.3), Vector3(0, 0.3, hh + 0.15), col)
	VisualUtils.add_box(self, Vector3(0.3, 0.6, HEIGHT * CELL), Vector3(-hw - 0.15, 0.3, 0), col)
	VisualUtils.add_box(self, Vector3(0.3, 0.6, HEIGHT * CELL), Vector3(hw + 0.15, 0.3, 0), col)


func _rect_center(rect: Rect2i) -> Vector3:
	return Vector3(
		(rect.position.x + rect.size.x * 0.5 - WIDTH * 0.5) * CELL,
		0.0,
		(rect.position.y + rect.size.y * 0.5 - HEIGHT * 0.5) * CELL)


func _build_obstacles() -> void:
	for rect in shelf_rects:
		var size := Vector3(rect.size.x * CELL - 0.12, 1.5, rect.size.y * CELL - 0.12)
		var center := _rect_center(rect)
		VisualUtils.add_box(self, size, center + Vector3(0, 0.75, 0), Color(0.24, 0.30, 0.40))
		for level in range(3):
			VisualUtils.add_box(self, Vector3(size.x + 0.06, 0.07, size.z + 0.06),
				center + Vector3(0, 0.3 + level * 0.5, 0), Color(0.92, 0.56, 0.16))
	for c in crates:
		VisualUtils.add_box(self, Vector3(0.8, 0.8, 0.8), cell_to_world(c) + Vector3(0, 0.4, 0), Color(0.55, 0.40, 0.22))


func _build_destinations() -> void:
	for key in destinations:
		var c: Vector2i = destinations[key]
		var p := cell_to_world(c)
		VisualUtils.add_cylinder(self, 0.38, 0.04, p + Vector3(0, 0.03, 0), Color(0.20, 0.90, 0.50), 0.6)
		VisualUtils.add_label(self, str(key), p + Vector3(0, 0.55, 0), 0.01, 64, Color(0.7, 1.0, 0.8))


func _build_charger() -> void:
	var p := cell_to_world(charger_cell)
	VisualUtils.add_cylinder(self, 0.42, 0.05, p + Vector3(0, 0.04, 0), Color(1.0, 0.85, 0.20), 0.7)
	VisualUtils.add_box(self, Vector3(0.5, 0.7, 0.12), p + Vector3(0, 0.35, 0.34), Color(0.95, 0.75, 0.15), 0.3)
	VisualUtils.add_label(self, "CHARGER", p + Vector3(0, 1.1, 0), 0.007, 56, Color(1.0, 0.92, 0.5))


func _build_hover() -> void:
	_hover = VisualUtils.add_box(self, Vector3(CELL * 0.94, 0.04, CELL * 0.94), Vector3(0, 0.05, 0), Color(0.3, 0.9, 0.5, 0.55))
	_hover.visible = false


## Подсветка ячейки под курсором (зелёная — можно назначить цель, красная — нельзя).
func show_hover(c: Vector2i, valid: bool) -> void:
	if _hover == null or not in_bounds(c):
		hide_hover()
		return
	_hover.position = cell_to_world(c) + Vector3(0, 0.05, 0)
	var mat := _hover.material_override as StandardMaterial3D
	mat.albedo_color = Color(0.3, 0.9, 0.5, 0.55) if valid else Color(0.95, 0.3, 0.3, 0.55)
	_hover.visible = true


func hide_hover() -> void:
	if _hover != null:
		_hover.visible = false
