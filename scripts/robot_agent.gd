class_name RobotAgent
extends Node3D
## Один робот: состояние, маршрут и плавное движение между центрами ячеек.
## Резервирование ячеек выполняет SimulationManager (try_reserve / release_cell),
## робот лишь спрашивает разрешение перед каждым шагом.

signal state_changed(robot: RobotAgent)

enum State { IDLE, MOVING, WORKING, PAUSED, DISABLED }

const WORK_TIME := 2.0       # сколько секунд «работает» после прибытия
const REROUTE_AFTER := 1.5   # через сколько секунд блокировки пересчитать маршрут
const REROUTE_RETRY := 2.0   # пауза между повторными пересчётами
const LONG_BLOCK_LOG := 6.0  # длительная блокировка -> запись в журнал
const ABORT_AFTER := 20.0    # слишком долгая блокировка -> задание отменяется
const TURN_SPEED := 12.0

var id: String = ""
var robot_color: Color = Color.WHITE
var speed: float = 2.0                    # ячеек в секунду
var manager = null                        # SimulationManager (без типа, чтобы не создавать циклическую зависимость)
var cell: Vector2i = Vector2i.ZERO        # последняя достигнутая ячейка
var next_cell: Vector2i = Vector2i.ZERO   # ячейка, в которую робот едет прямо сейчас
var start_cell: Vector2i = Vector2i.ZERO
var target: Vector2i = Vector2i.ZERO
var has_target: bool = false
var route: Array[Vector2i] = []           # оставшиеся ячейки (без next_cell)
var state: State = State.IDLE
var removed: bool = false

var _stepping := false                    # true, пока робот едет между двумя центрами ячеек
var _paused_from: State = State.IDLE
var _work_left := 0.0
var _blocked_time := 0.0
var _next_reroute := REROUTE_AFTER
var _block_logged := false
var _target_yaw := 0.0
var _body_mat: StandardMaterial3D
var _lamp_mat: StandardMaterial3D
var _ring: MeshInstance3D


func setup(p_id: String, p_color: Color, p_speed: float, p_cell: Vector2i, p_manager) -> void:
	id = p_id
	name = p_id
	robot_color = p_color
	speed = p_speed
	manager = p_manager
	cell = p_cell
	next_cell = p_cell
	start_cell = p_cell
	position = manager.grid.cell_to_world(p_cell)


func _ready() -> void:
	_build_visual()
	_update_visual()


func _process(delta: float) -> void:
	rotation.y = lerp_angle(rotation.y, _target_yaw, minf(1.0, TURN_SPEED * delta))


# ---------- Статика для интерфейса ----------

static func state_name(s: State) -> String:
	match s:
		State.IDLE: return "Idle"
		State.MOVING: return "Moving"
		State.WORKING: return "Working"
		State.PAUSED: return "Paused"
		State.DISABLED: return "Disabled"
	return "?"


static func state_color(s: State) -> Color:
	match s:
		State.IDLE: return Color(0.35, 0.62, 1.00)
		State.MOVING: return Color(0.30, 0.90, 0.45)
		State.WORKING: return Color(1.00, 0.65, 0.20)
		State.PAUSED: return Color(1.00, 0.90, 0.30)
		State.DISABLED: return Color(0.90, 0.30, 0.30)
	return Color.WHITE


# ---------- Запросы ----------

func is_controllable() -> bool:
	return state != State.DISABLED and not removed


func is_stepping() -> bool:
	return _stepping


## Ячейка, от которой нужно строить новый маршрут (если робот в пути — та, куда он уже едет).
func route_origin() -> Vector2i:
	return next_cell if _stepping else cell


## Ячейки для отображения маршрута в сцене.
func route_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _stepping:
		out.append(next_cell)
	out.append_array(route)
	return out


# ---------- Команды (вызываются из SimulationManager) ----------

func begin_task(p_target: Vector2i, path: Array[Vector2i]) -> void:
	target = p_target
	has_target = true
	route = path
	_reset_block_state()
	if state == State.PAUSED:
		_paused_from = State.MOVING  # задание принято, но робот остаётся на паузе
	else:
		_set_state(State.MOVING)


func pause() -> bool:
	if state != State.MOVING and state != State.WORKING:
		return false
	_paused_from = state
	_set_state(State.PAUSED)
	return true


func resume() -> bool:
	if state != State.PAUSED:
		return false
	# Если робот стоит в центре ячейки, пересчитываем маршрут заново (обстановка могла измениться).
	if _paused_from == State.MOVING and has_target and not _stepping and cell != target:
		var path: Array[Vector2i] = manager.plan_path(self, cell, target, true)
		if path.is_empty():
			path = manager.plan_path(self, cell, target, false)
		if not path.is_empty():
			route = path
	_reset_block_state()
	_set_state(_paused_from)
	return true


func disable() -> void:
	route.clear()
	has_target = false
	_paused_from = State.IDLE
	_set_state(State.DISABLED)


func enable() -> void:
	if state == State.DISABLED:
		_set_state(State.IDLE)


## Мгновенный возврат в ячейку p_cell с очисткой маршрута; робот снова доступен.
func reset_to(p_cell: Vector2i) -> void:
	_stepping = false
	route.clear()
	has_target = false
	_paused_from = State.IDLE
	_reset_block_state()
	cell = p_cell
	next_cell = p_cell
	position = manager.grid.cell_to_world(p_cell)
	_set_state(State.IDLE)
	_update_visual()


func set_selected(value: bool) -> void:
	if _ring != null:
		_ring.visible = value


# ---------- Такт симуляции ----------

func tick(dt: float) -> void:
	if removed:
		return
	if state == State.WORKING:
		_work_left -= dt
		if _work_left <= 0.0:
			_finish_work()
	elif state == State.MOVING or (state == State.IDLE and _stepping):
		# Второй случай: робота отключили/включили посреди шага — дорабатываем шаг до центра ячейки.
		_advance(dt)


func _advance(dt: float) -> void:
	var budget := speed * dt
	var guard := 0
	while budget > 0.0001 and guard < 16:
		guard += 1
		if not _stepping:
			if state != State.MOVING:
				return
			if route.is_empty():
				_arrive()
				return
			if not _begin_step(dt):
				return
		var dest: Vector3 = manager.grid.cell_to_world(next_cell)
		var to := dest - position
		var dist := to.length()
		if dist > 0.001:
			_target_yaw = atan2(to.x, to.z)  # +Z модели — «перёд»
		if dist <= budget:
			position = dest
			budget -= dist
			_finish_step()
		else:
			position += to / dist * budget
			budget = 0.0


## Пытается занять следующую ячейку маршрута. false — шаг не начат (ячейка занята).
func _begin_step(dt: float) -> bool:
	var nxt: Vector2i = route[0]
	if manager.try_reserve(self, nxt):
		route.remove_at(0)
		next_cell = nxt
		_stepping = true
		if _block_logged:
			manager.log_info("%s: путь освободился, движение продолжено" % id)
		_reset_block_state()
		return true

	_blocked_time += dt
	if _blocked_time >= _next_reroute:
		_next_reroute = _blocked_time + REROUTE_RETRY
		_try_reroute()
	if _blocked_time >= LONG_BLOCK_LOG and not _block_logged:
		_block_logged = true
		var who: String = manager.occupant_of(nxt)
		manager.log_warn("%s: длительная блокировка — ячейка %s занята (%s)" % [id, manager.grid.cell_label(nxt), who if who != "" else "препятствие"])
	if _blocked_time >= ABORT_AFTER:
		_abort_task("путь заблокирован дольше %d с" % int(ABORT_AFTER))
	return false


func _try_reroute() -> void:
	if not has_target:
		return
	var path: Array[Vector2i] = manager.plan_path(self, cell, target, true)
	if path.is_empty():
		return  # обойти других роботов нельзя — продолжаем ждать
	route = path
	manager.log_info("%s: маршрут пересчитан (обход занятой ячейки), шагов: %d" % [id, path.size()])


func _finish_step() -> void:
	manager.release_cell(self, cell)
	cell = next_cell
	_stepping = false


func _arrive() -> void:
	_work_left = WORK_TIME
	_set_state(State.WORKING)
	manager.log_info("%s прибыл в %s и выполняет задание" % [id, manager.grid.cell_label(cell)])


func _finish_work() -> void:
	has_target = false
	_set_state(State.IDLE)
	manager.log_info("%s завершил задание и ожидает" % id)


func _abort_task(reason: String) -> void:
	route.clear()
	has_target = false
	_set_state(State.IDLE)
	manager.log_warn("%s: задание отменено — %s" % [id, reason])


func _reset_block_state() -> void:
	_blocked_time = 0.0
	_block_logged = false
	_next_reroute = REROUTE_AFTER


func _set_state(s: State) -> void:
	if state == s:
		return
	state = s
	_update_visual()
	state_changed.emit(self)


# ---------- Внешний вид (простые примитивы) ----------

func _build_visual() -> void:
	VisualUtils.add_box(self, Vector3(0.64, 0.2, 0.74), Vector3(0, 0.16, 0), Color(0.14, 0.15, 0.18))
	for sx in [-1.0, 1.0]:
		var wheel := VisualUtils.add_cylinder(self, 0.13, 0.08, Vector3(sx * 0.35, 0.13, 0.0), Color(0.05, 0.05, 0.06))
		wheel.rotation_degrees = Vector3(0, 0, 90)
	var body := VisualUtils.add_box(self, Vector3(0.5, 0.24, 0.56), Vector3(0, 0.38, 0), robot_color)
	_body_mat = body.material_override as StandardMaterial3D
	# «Лицо» на передней (+Z) стороне, чтобы было видно направление движения.
	VisualUtils.add_box(self, Vector3(0.2, 0.1, 0.12), Vector3(0, 0.42, 0.3), Color(0.95, 0.95, 0.98), 0.4)
	VisualUtils.add_cylinder(self, 0.025, 0.3, Vector3(0, 0.65, -0.15), Color(0.7, 0.7, 0.75))
	var lamp := VisualUtils.add_sphere(self, 0.075, Vector3(0, 0.84, -0.15), Color.WHITE, 1.0)
	_lamp_mat = lamp.material_override as StandardMaterial3D
	VisualUtils.add_label(self, id, Vector3(0, 1.2, 0), 0.006, 56)

	var torus := TorusMesh.new()
	torus.inner_radius = 0.5
	torus.outer_radius = 0.6
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.material_override = VisualUtils.material(Color(1.0, 0.9, 0.3), 1.5)
	_ring.position = Vector3(0, 0.05, 0)
	_ring.visible = false
	add_child(_ring)


func _update_visual() -> void:
	if _lamp_mat == null or _body_mat == null:
		return
	var c := state_color(state)
	_lamp_mat.albedo_color = c
	_lamp_mat.emission = c
	_body_mat.albedo_color = robot_color.darkened(0.65) if state == State.DISABLED else robot_color
