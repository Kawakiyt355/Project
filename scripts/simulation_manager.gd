class_name SimulationManager
extends Node
## Управляет списком роботов, резервированием ячеек (защита от столкновений),
## командами пользователя и временем симуляции.
##
## Модель столкновений: словарь occupancy {Vector2i -> id робота}. Робот занимает свою
## текущую ячейку и (во время шага) ячейку, в которую едет. Перед каждым шагом робот
## вызывает try_reserve(); если ячейка чужая или это препятствие — шаг не начинается.
## Так два робота не могут занять одну ячейку и не могут «поменяться местами» сквозь друг друга.

signal robot_added(robot: RobotAgent)
signal robot_removed(robot_id: String)
signal robot_changed(robot: RobotAgent)
signal selection_changed(robot: RobotAgent)

const MAX_ROBOTS := 10
const SPEEDS := [0.25, 0.5, 1.0, 2.0, 4.0]
const PALETTE := [
	Color(0.93, 0.33, 0.33), Color(0.30, 0.80, 0.45), Color(0.35, 0.55, 0.98),
	Color(0.98, 0.78, 0.20), Color(0.75, 0.40, 0.95), Color(0.25, 0.82, 0.85),
	Color(0.98, 0.55, 0.20), Color(0.90, 0.45, 0.75), Color(0.60, 0.85, 0.25),
	Color(0.70, 0.70, 0.78),
]
const MSG_GONE := "Робот не найден (возможно, он уже удалён)."

var grid: WarehouseGrid
var logger: EventLogger
var robots: Array[RobotAgent] = []
var selected: RobotAgent = null
var running := true
var speed_index := 2
var occupancy: Dictionary = {}

var _robots_root: Node3D
var _next_number := 1


func setup(p_grid: WarehouseGrid, p_logger: EventLogger, p_root: Node3D) -> void:
	grid = p_grid
	logger = p_logger
	_robots_root = p_root


func _process(delta: float) -> void:
	if not running:
		return
	var dt := minf(delta, 0.1) * speed_mult()
	for r in robots:
		r.tick(dt)


func speed_mult() -> float:
	return SPEEDS[speed_index]


# ---------- Логирование для роботов ----------

func log_info(text: String) -> void:
	logger.info(text)


func log_warn(text: String) -> void:
	logger.warn(text)


# ---------- Занятость ячеек ----------

func try_reserve(robot: RobotAgent, c: Vector2i) -> bool:
	if grid.is_blocked(c):
		return false
	var owner_id: String = occupancy.get(c, "")
	if owner_id != "" and owner_id != robot.id:
		return false
	occupancy[c] = robot.id
	return true


func release_cell(robot: RobotAgent, c: Vector2i) -> void:
	var owner_id: String = occupancy.get(c, "")
	if owner_id == robot.id:
		occupancy.erase(c)


func occupant_of(c: Vector2i) -> String:
	return occupancy.get(c, "")


func _release_all(robot: RobotAgent) -> void:
	var mine: Array = []
	for c in occupancy:
		if occupancy[c] == robot.id:
			mine.append(c)
	for c in mine:
		occupancy.erase(c)


func describe_cell(c: Vector2i) -> String:
	if not grid.in_bounds(c):
		return "вне карты"
	if grid.is_blocked(c):
		return grid.obstacle_name(c)
	var occ := occupant_of(c)
	if occ != "":
		return "занята: " + occ
	var place := grid.place_name(c)
	return place if place != "" else "свободна"


# ---------- Построение маршрутов ----------

func plan_path(robot: RobotAgent, from_cell: Vector2i, goal: Vector2i, avoid_robots: bool) -> Array[Vector2i]:
	var blocked: Dictionary = {}
	if avoid_robots:
		for c in occupancy:
			if occupancy[c] != robot.id:
				blocked[c] = true
	return PathfindingService.find_path(grid, from_cell, goal, blocked)


## Пустая строка — цель допустима, иначе понятное сообщение об ошибке.
func validate_target(r: RobotAgent, c: Vector2i) -> String:
	if not grid.in_bounds(c):
		return "Цель (%d, %d) находится за пределами карты." % [c.x, c.y]
	if grid.is_blocked(c):
		return "Цель %s недоступна: %s." % [grid.cell_label(c), grid.obstacle_name(c)]
	var occ := occupant_of(c)
	if occ != "" and occ != r.id:
		return "Цель %s занята роботом %s." % [grid.cell_label(c), occ]
	for other in robots:
		if other != r and other.has_target and other.target == c:
			return "Цель %s уже назначена роботу %s." % [grid.cell_label(c), other.id]
	return ""


# ---------- Создание, удаление, выбор ----------

func create_initial_robots() -> void:
	for c in grid.initial_robot_cells:
		add_robot(c)


func add_robot(preferred: Vector2i = Vector2i(-1, -1)) -> RobotAgent:
	if robots.size() >= MAX_ROBOTS:
		logger.warn("Нельзя добавить робота: достигнут лимит (%d)." % MAX_ROBOTS)
		return null
	var start := preferred
	if start == Vector2i(-1, -1) or not _is_free_for_start(start):
		start = _find_free_start()
	if start == Vector2i(-1, -1):
		logger.warn("Нельзя добавить робота: на карте нет свободной стартовой ячейки.")
		return null

	var number := _next_number
	_next_number += 1
	var robot := RobotAgent.new()
	var color: Color = PALETTE[(number - 1) % PALETTE.size()]
	var spd := 1.6 + 0.2 * float((number - 1) % 4)
	robot.setup("R-%02d" % number, color, spd, start, self)
	_robots_root.add_child(robot)
	robots.append(robot)
	occupancy[start] = robot.id
	robot.state_changed.connect(_on_robot_state_changed)
	logger.info("Добавлен робот %s в ячейке %s" % [robot.id, grid.cell_label(start)])
	robot_added.emit(robot)
	return robot


func _on_robot_state_changed(robot: RobotAgent) -> void:
	robot_changed.emit(robot)


func _is_free_for_start(c: Vector2i) -> bool:
	if grid.is_blocked(c) or c == grid.charger_cell or occupancy.has(c):
		return false
	for r in robots:
		if r.start_cell == c:
			return false
	return true


func _find_free_start() -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := 1 << 30
	for y in range(WarehouseGrid.HEIGHT):
		for x in range(WarehouseGrid.WIDTH):
			var c := Vector2i(x, y)
			if not _is_free_for_start(c):
				continue
			var d := absi(c.x - grid.charger_cell.x) + absi(c.y - grid.charger_cell.y)
			if d < best_d:
				best_d = d
				best = c
	return best


func _cell_free_for(c: Vector2i, r: RobotAgent) -> bool:
	if grid.is_blocked(c):
		return false
	var occ := occupant_of(c)
	return occ == "" or occ == r.id


func _find_free_cell_near(origin: Vector2i, r: RobotAgent) -> Vector2i:
	var best := origin
	var best_d := 1 << 30
	for y in range(WarehouseGrid.HEIGHT):
		for x in range(WarehouseGrid.WIDTH):
			var c := Vector2i(x, y)
			if not _cell_free_for(c, r):
				continue
			var d := absi(c.x - origin.x) + absi(c.y - origin.y)
			if d < best_d:
				best_d = d
				best = c
	return best


func _valid(r) -> bool:
	return r != null and is_instance_valid(r) and not r.removed and robots.has(r)


func select(r: RobotAgent) -> void:
	if selected == r:
		return
	if selected != null and is_instance_valid(selected):
		selected.set_selected(false)
	selected = r
	if r != null:
		r.set_selected(true)
	selection_changed.emit(r)


# ---------- Команды управления роботом (возвращают "" при успехе или текст ошибки) ----------

func cmd_move(r, c: Vector2i) -> String:
	if not _valid(r):
		return MSG_GONE
	if r.state == RobotAgent.State.DISABLED:
		return "%s отключён и не принимает команды перемещения." % r.id
	var err := validate_target(r, c)
	if err != "":
		logger.warn("%s: команда Move отклонена — %s" % [r.id, err])
		return err
	var origin: Vector2i = r.route_origin()
	if c == origin and not r.is_stepping():
		err = "%s уже находится в ячейке %s." % [r.id, grid.cell_label(c)]
		logger.warn(err)
		return err

	var path: Array[Vector2i] = []
	if c != origin:
		path = plan_path(r, origin, c, true)
		if path.is_empty():
			# Возможно, путь временно перекрыт роботами — пробуем без их учёта.
			path = plan_path(r, origin, c, false)
			if path.is_empty():
				err = "Маршрут к %s не найден (путь перекрыт препятствиями)." % grid.cell_label(c)
				logger.warn("%s: %s" % [r.id, err])
				return err
			logger.info("%s: путь временно занят другими роботами, маршрут построен без их учёта" % r.id)
	r.begin_task(c, path)
	logger.info("%s: цель %s, шагов в маршруте: %d" % [r.id, grid.cell_label(c), path.size()])
	robot_changed.emit(r)
	return ""


func cmd_pause(r) -> String:
	if not _valid(r):
		return MSG_GONE
	if r.state == RobotAgent.State.DISABLED:
		return "%s отключён." % r.id
	if not r.pause():
		return "%s не выполняет задание — приостанавливать нечего." % r.id
	logger.info("%s приостановлен" % r.id)
	return ""


func cmd_resume(r) -> String:
	if not _valid(r):
		return MSG_GONE
	if not r.resume():
		return "%s не находится на паузе." % r.id
	logger.info("%s продолжает выполнение задания" % r.id)
	return ""


func cmd_reset(r) -> String:
	if not _valid(r):
		return MSG_GONE
	_release_all(r)
	var c: Vector2i = r.start_cell
	if not _cell_free_for(c, r):
		c = _find_free_cell_near(r.start_cell, r)
		logger.warn("%s: стартовая ячейка занята, робот возвращён в ближайшую свободную %s" % [r.id, grid.cell_label(c)])
	r.reset_to(c)
	occupancy[c] = r.id
	logger.info("%s сброшен в стартовую позицию %s" % [r.id, grid.cell_label(c)])
	robot_changed.emit(r)
	return ""


func cmd_toggle_disabled(r) -> String:
	if not _valid(r):
		return MSG_GONE
	if r.state == RobotAgent.State.DISABLED:
		r.enable()
		logger.info("%s включён и снова доступен для управления" % r.id)
	else:
		r.disable()
		logger.info("%s отключён от симуляции (остаётся в сцене, но не движется)" % r.id)
	robot_changed.emit(r)
	return ""


func cmd_remove(r) -> String:
	if not _valid(r):
		return MSG_GONE
	var rid: String = r.id
	_release_all(r)
	robots.erase(r)
	if selected == r:
		select(null)
	r.removed = true
	r.queue_free()
	logger.info("%s удалён из сцены" % rid)
	robot_removed.emit(rid)
	return ""


# ---------- Общие команды симуляции ----------

func toggle_running() -> void:
	running = not running
	logger.info("Симуляция запущена" if running else "Симуляция поставлена на паузу")


func resume_all() -> void:
	var n := 0
	for r in robots:
		if r.state == RobotAgent.State.PAUSED:
			r.resume()
			n += 1
	if not running:
		running = true
	logger.info("Resume: симуляция продолжена, возобновлено роботов: %d" % n)


func reset_all() -> void:
	occupancy.clear()
	for r in robots:
		r.reset_to(r.start_cell)
		occupancy[r.start_cell] = r.id
		robot_changed.emit(r)
	logger.info("Симуляция сброшена: все роботы возвращены на стартовые позиции")


func change_speed(step: int) -> void:
	speed_index = clampi(speed_index + step, 0, SPEEDS.size() - 1)
	logger.info("Скорость симуляции: ×%s" % str(speed_mult()))


## Раздаёт простаивающим роботам случайные точки назначения (для демонстрации).
func assign_demo_tasks() -> void:
	var dests: Array = grid.destinations.values()
	var n := 0
	for r in robots:
		if r.state != RobotAgent.State.IDLE:
			continue
		dests.shuffle()
		for d in dests:
			var dc: Vector2i = d
			if dc == r.cell or validate_target(r, dc) != "":
				continue
			if cmd_move(r, dc) == "":
				n += 1
				break
	logger.info("Демо-задания назначены роботам: %d" % n)
