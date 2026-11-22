extends Node
## Точка входа: создаёт интерфейс, 3D-мир (свет, камера, склад), менеджер симуляции
## и обрабатывает мышь в области 3D (выбор робота, выбор целевой ячейки, камера).

enum Drag { NONE, CLICK, ORBIT, PAN }

const ROUTE_MAX := 400

var logger := EventLogger.new()
var manager: SimulationManager
var ui: MainUI
var grid: WarehouseGrid
var rig: CameraRig

var _drag: Drag = Drag.NONE
var _press_pos := Vector2.ZERO
var _route_mm: MultiMesh
var _route_mat: StandardMaterial3D
var _target_ring: MeshInstance3D


func _ready() -> void:
	manager = SimulationManager.new()
	add_child(manager)

	var layer := CanvasLayer.new()
	add_child(layer)
	ui = MainUI.new()
	layer.add_child(ui)
	ui.build()

	var world: SubViewport = ui.viewport
	_build_environment(world)

	grid = WarehouseGrid.new()
	world.add_child(grid)
	grid.build()

	var robots_root := Node3D.new()
	robots_root.name = "Robots"
	world.add_child(robots_root)

	rig = CameraRig.new()
	world.add_child(rig)
	_build_route_view(world)

	manager.setup(grid, logger, robots_root)
	ui.bind(manager, logger, grid)
	ui.camera_reset_requested.connect(rig.reset)
	ui.viewport_container.gui_input.connect(_on_view_input)
	ui.viewport_container.mouse_exited.connect(_on_view_exited)

	logger.info("ModelControl запущен. Склад %dx%d ячеек." % [WarehouseGrid.WIDTH, WarehouseGrid.HEIGHT])
	manager.create_initial_robots()
	manager.assign_demo_tasks()


func _process(delta: float) -> void:
	# Клавиши камеры опрашиваем напрямую: так они работают независимо от фокуса интерфейса.
	var dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if dir != Vector2.ZERO:
		rig.move_planar(dir.normalized(), delta)
	var rot := 0.0
	if Input.is_physical_key_pressed(KEY_Q):
		rot -= 1.0
	if Input.is_physical_key_pressed(KEY_E):
		rot += 1.0
	if rot != 0.0:
		rig.rotate_yaw(rot * delta * 1.5)
	_update_route_view()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if key.keycode == KEY_ESCAPE:
			ui.set_move_mode(false)
		elif key.keycode == KEY_SPACE:
			manager.toggle_running()


# ---------- Построение мира ----------

func _build_environment(world: Node) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.65, 0.70, 0.80)
	env.ambient_light_energy = 0.6
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60.0, 30.0, 0.0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	world.add_child(sun)


func _build_route_view(world: Node) -> void:
	var dot := CylinderMesh.new()
	dot.top_radius = 0.12
	dot.bottom_radius = 0.12
	dot.height = 0.03
	_route_mat = VisualUtils.material(Color(1.0, 0.9, 0.3), 1.0)
	_route_mm = MultiMesh.new()
	_route_mm.transform_format = MultiMesh.TRANSFORM_3D
	_route_mm.mesh = dot
	_route_mm.instance_count = ROUTE_MAX
	_route_mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _route_mm
	mmi.material_override = _route_mat
	world.add_child(mmi)

	var ring := TorusMesh.new()
	ring.inner_radius = 0.36
	ring.outer_radius = 0.46
	_target_ring = MeshInstance3D.new()
	_target_ring.mesh = ring
	_target_ring.material_override = _route_mat
	_target_ring.visible = false
	world.add_child(_target_ring)


## Маршрут выбранного робота: точки по центрам ячеек и кольцо на цели.
func _update_route_view() -> void:
	var r: RobotAgent = manager.selected
	if r == null or r.removed:
		_route_mm.visible_instance_count = 0
		_target_ring.visible = false
		return
	_route_mat.albedo_color = r.robot_color.lightened(0.25)
	_route_mat.emission = r.robot_color.lightened(0.25)
	var cells: Array[Vector2i] = r.route_cells()
	var n := mini(cells.size(), ROUTE_MAX)
	for i in range(n):
		var p := grid.cell_to_world(cells[i]) + Vector3(0.0, 0.05, 0.0)
		_route_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))
	_route_mm.visible_instance_count = n
	_target_ring.visible = r.has_target
	if r.has_target:
		_target_ring.position = grid.cell_to_world(r.target) + Vector3(0.0, 0.06, 0.0)


# ---------- Мышь в области 3D ----------

func _on_view_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					rig.zoom(-1.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					rig.zoom(1.0)
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_press_pos = mb.position
					if mb.alt_pressed:
						_drag = Drag.ORBIT  # Option + ЛКМ: вращение (удобно на трекпаде)
					elif mb.shift_pressed:
						_drag = Drag.PAN
					else:
						_drag = Drag.CLICK
				else:
					if _drag == Drag.CLICK and mb.position.distance_to(_press_pos) < 6.0:
						_handle_click(mb.position)
					_drag = Drag.NONE
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_drag = Drag.PAN if mb.shift_pressed else Drag.ORBIT
				else:
					_drag = Drag.NONE
			MOUSE_BUTTON_MIDDLE:
				_drag = Drag.PAN if mb.pressed else Drag.NONE
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		match _drag:
			Drag.ORBIT:
				rig.orbit(mm.relative)
			Drag.PAN:
				rig.pan(mm.relative)
			Drag.NONE:
				_update_hover(mm.position)
			_:
				pass
	elif event is InputEventMagnifyGesture:
		rig.zoom_by(1.0 / maxf((event as InputEventMagnifyGesture).factor, 0.1))
	elif event is InputEventPanGesture:
		rig.zoom_by(1.0 + (event as InputEventPanGesture).delta.y * 0.05)


func _on_view_exited() -> void:
	grid.hide_hover()
	ui.set_hover_text("")


func _cell_at(pos: Vector2) -> Variant:
	var p: Variant = rig.ground_point(pos)
	if p == null:
		return null
	return grid.world_to_cell(p)


func _update_hover(pos: Vector2) -> void:
	var c: Variant = _cell_at(pos)
	if c == null:
		grid.hide_hover()
		ui.set_hover_text("")
		return
	var cell: Vector2i = c
	ui.set_hover_text("Ячейка (%d, %d) — %s" % [cell.x, cell.y, manager.describe_cell(cell)])
	if ui.move_mode and manager.selected != null:
		grid.show_hover(cell, manager.validate_target(manager.selected, cell) == "")
	else:
		grid.hide_hover()


func _handle_click(pos: Vector2) -> void:
	if ui.move_mode:
		var r: RobotAgent = manager.selected
		var c: Variant = _cell_at(pos)
		if c == null:
			ui.notify("Кликните по полу склада.", true)
			return
		var err := manager.cmd_move(r, c)
		if err != "":
			ui.notify(err, true)  # режим Move остаётся активным — можно выбрать другую ячейку
		else:
			ui.notify("Маршрут назначен.")
			ui.set_move_mode(false)
		return

	var hit := _robot_at(pos)
	manager.select(hit)  # клик по пустому месту снимает выделение


## Выбор робота лучом: пересечение луча камеры со сферой вокруг каждого робота.
func _robot_at(pos: Vector2) -> RobotAgent:
	var cam := rig.camera
	var from := cam.project_ray_origin(pos)
	var dir := cam.project_ray_normal(pos)
	var best: RobotAgent = null
	var best_t := INF
	for r in manager.robots:
		var center := r.global_position + Vector3(0.0, 0.4, 0.0)
		var oc := center - from
		var t := oc.dot(dir)
		if t < 0.0:
			continue
		var d2 := oc.length_squared() - t * t
		if d2 <= 0.55 * 0.55 and t < best_t:
			best = r
			best_t = t
	return best
