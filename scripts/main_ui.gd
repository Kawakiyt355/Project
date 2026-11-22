class_name MainUI
extends Control
## Весь интерфейс создаётся кодом:
##   слева — список роботов, по центру — 3D-сцена (SubViewport), справа — информация и команды,
##   снизу — общие команды симуляции и журнал событий.

signal move_mode_changed(active: bool)
signal camera_reset_requested

const COL_BG := Color(0.07, 0.08, 0.10)
const COL_PANEL := Color(0.12, 0.13, 0.16)
const COL_BORDER := Color(0.22, 0.25, 0.30)
const COL_ACCENT := Color(0.35, 0.68, 1.0)
const COL_DIM := Color(0.60, 0.65, 0.72)
const COL_TEXT := Color(0.88, 0.90, 0.93)
const LEVEL_COLORS := ["#a9bfd6", "#ffcc66", "#ff7070"]
const MAX_LOG_LINES := 400

var manager: SimulationManager
var logger: EventLogger
var grid: WarehouseGrid

var viewport_container: SubViewportContainer
var viewport: SubViewport
var move_mode := false

var _robot_list: VBoxContainer
var _rows: Dictionary = {}  # id робота -> {"button": Button, "dot": ColorRect}
var _count_label: Label
var _empty_label: Label
var _info_grid: GridContainer
var _info_values: Dictionary = {}
var _move_hint: Label
var _btn_move: Button
var _btn_pause: Button
var _btn_resume: Button
var _btn_reset: Button
var _btn_toggle: Button
var _btn_remove: Button
var _btn_run: Button
var _btn_resume_all: Button
var _btn_add: Button
var _btn_slower: Button
var _btn_faster: Button
var _speed_label: Label
var _sim_label: Label
var _msg_label: Label
var _msg_time := 0.0
var _hover_label: Label
var _mode_label: Label
var _log: RichTextLabel
var _log_lines := 0
var _confirm: ConfirmationDialog
var _pending_remove = null


# ---------- Построение интерфейса ----------

func build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := Theme.new()
	t.default_font_size = 14
	theme = t

	var bg := ColorRect.new()
	bg.color = COL_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)

	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	margin.add_child(rows)

	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.add_theme_constant_override("separation", 8)
	rows.add_child(mid)
	mid.add_child(_build_left_panel())
	mid.add_child(_build_center())
	mid.add_child(_build_right_panel())
	rows.add_child(_build_bottom_panel())

	_confirm = ConfirmationDialog.new()
	_confirm.title = "Подтверждение удаления"
	_confirm.ok_button_text = "Удалить"
	_confirm.cancel_button_text = "Отмена"
	_confirm.confirmed.connect(_on_remove_confirmed)
	add_child(_confirm)


func _make_panel(min_width: float = 0.0, content_margin: float = 10.0) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = COL_PANEL
	sb.border_color = COL_BORDER
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(content_margin)
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size.x = min_width
	return p


func _header(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", COL_ACCENT)
	l.add_theme_font_size_override("font_size", 13)
	return l


func _make_button(text: String, tip: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 32)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(handler)
	return b


func _build_left_panel() -> Control:
	var p := _make_panel(230)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)
	v.add_child(_header("РОБОТЫ"))
	_count_label = Label.new()
	_count_label.add_theme_color_override("font_color", COL_DIM)
	v.add_child(_count_label)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	_robot_list = VBoxContainer.new()
	_robot_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_robot_list.add_theme_constant_override("separation", 4)
	sc.add_child(_robot_list)
	return p


func _overlay_label(color: Color) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 5)
	return l


func _build_center() -> Control:
	var frame := _make_panel(0.0, 2.0)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var stack := Control.new()
	stack.custom_minimum_size = Vector2(420, 320)
	stack.clip_contents = true
	frame.add_child(stack)

	viewport_container = SubViewportContainer.new()
	viewport_container.stretch = true
	viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	stack.add_child(viewport_container)

	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport_container.add_child(viewport)

	# Подсказки поверх 3D-вида (мышь через них проходит к сцене).
	var overlay := MarginContainer.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		overlay.add_theme_constant_override("margin_" + side, 10)
	stack.add_child(overlay)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(col)
	_hover_label = _overlay_label(COL_TEXT)
	col.add_child(_hover_label)
	_mode_label = _overlay_label(Color(1.0, 0.9, 0.35))
	_mode_label.visible = false
	col.add_child(_mode_label)
	var spacer := Control.new()
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(spacer)
	var help := _overlay_label(COL_DIM)
	help.add_theme_font_size_override("font_size", 12)
	help.text = "ЛКМ — выбрать робота / цель  ·  ПКМ или Option+ЛКМ — вращение  ·  Shift+ПКМ или СКМ — сдвиг  ·  колесо — масштаб  ·  WASD / стрелки — движение камеры  ·  Q/E — поворот  ·  Пробел — пауза"
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(help)
	return frame


func _build_right_panel() -> Control:
	var p := _make_panel(290)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	v.add_child(_header("ВЫБРАННЫЙ РОБОТ"))

	_empty_label = Label.new()
	_empty_label.text = "Робот не выбран.\n\nКликните по роботу в 3D-сцене или выберите его в списке слева."
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.add_theme_color_override("font_color", COL_DIM)
	v.add_child(_empty_label)

	_info_grid = GridContainer.new()
	_info_grid.columns = 2
	_info_grid.add_theme_constant_override("h_separation", 12)
	_info_grid.add_theme_constant_override("v_separation", 6)
	v.add_child(_info_grid)
	_add_info_row("id", "ID")
	_add_info_row("cell", "Координаты")
	_add_info_row("status", "Статус")
	_add_info_row("speed", "Скорость")
	_add_info_row("target", "Цель")
	_add_info_row("route", "Точек маршрута")
	_add_info_row("access", "Управление")

	v.add_child(HSeparator.new())
	v.add_child(_header("КОМАНДЫ"))

	_move_hint = Label.new()
	_move_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_move_hint.add_theme_color_override("font_color", COL_DIM)
	_move_hint.add_theme_font_size_override("font_size", 12)
	v.add_child(_move_hint)

	var grid_btn := GridContainer.new()
	grid_btn.columns = 2
	grid_btn.add_theme_constant_override("h_separation", 6)
	grid_btn.add_theme_constant_override("v_separation", 6)
	v.add_child(grid_btn)

	_btn_move = _make_button("Move", "Назначить цель: нажмите, затем кликните по ячейке склада", _on_move_pressed)
	_btn_move.toggle_mode = true
	_btn_pause = _make_button("Pause", "Остановить движение, сохранив задание", _on_pause_pressed)
	_btn_resume = _make_button("Resume", "Продолжить движение по маршруту", _on_resume_pressed)
	_btn_reset = _make_button("Reset", "Вернуть робота на стартовую позицию и очистить маршрут", _on_reset_pressed)
	_btn_toggle = _make_button("Disable", "Отключить/включить робота (отключённый остаётся в сцене, но не движется)", _on_toggle_pressed)
	_btn_remove = _make_button("Remove", "Удалить робота из сцены (с подтверждением)", _on_remove_pressed)
	_btn_remove.add_theme_color_override("font_color", Color(1.0, 0.55, 0.50))
	for b in [_btn_move, _btn_pause, _btn_resume, _btn_reset, _btn_toggle, _btn_remove]:
		grid_btn.add_child(b)
	return p


func _add_info_row(key: String, caption: String) -> void:
	var c := Label.new()
	c.text = caption
	c.add_theme_color_override("font_color", COL_DIM)
	_info_grid.add_child(c)
	var val := Label.new()
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	val.add_theme_color_override("font_color", COL_TEXT)
	_info_grid.add_child(val)
	_info_values[key] = val


func _build_bottom_panel() -> Control:
	var p := _make_panel()
	p.custom_minimum_size.y = 190
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	p.add_child(v)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	v.add_child(bar)
	_btn_run = _make_button("Pause", "Запустить/остановить время симуляции (Пробел)", _on_run_pressed)
	_btn_resume_all = _make_button("Resume", "Возобновить все роботы на паузе и продолжить симуляцию", _on_resume_all_pressed)
	var btn_reset_sim := _make_button("Reset Simulation", "Вернуть всех роботов на стартовые позиции", _on_reset_sim_pressed)
	_btn_add = _make_button("Add Robot", "Добавить нового робота рядом с зарядной станцией", _on_add_pressed)
	var btn_demo := _make_button("Demo Tasks", "Раздать простаивающим роботам случайные точки назначения", _on_demo_pressed)
	for b in [_btn_run, _btn_resume_all, btn_reset_sim, _btn_add, btn_demo]:
		b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		b.custom_minimum_size.x = 110
		bar.add_child(b)

	bar.add_child(VSeparator.new())
	var speed_caption := Label.new()
	speed_caption.text = "Скорость:"
	speed_caption.add_theme_color_override("font_color", COL_DIM)
	bar.add_child(speed_caption)
	_btn_slower = _make_button("−", "Замедлить симуляцию", _on_slower_pressed)
	_btn_slower.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_btn_slower.custom_minimum_size.x = 34
	bar.add_child(_btn_slower)
	_speed_label = Label.new()
	_speed_label.custom_minimum_size.x = 44
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(_speed_label)
	_btn_faster = _make_button("+", "Ускорить симуляцию", _on_faster_pressed)
	_btn_faster.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_btn_faster.custom_minimum_size.x = 34
	bar.add_child(_btn_faster)

	var btn_cam := _make_button("Reset Camera", "Вернуть камеру в исходное положение", _on_camera_pressed)
	btn_cam.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	btn_cam.custom_minimum_size.x = 110
	bar.add_child(btn_cam)

	_sim_label = Label.new()
	bar.add_child(_sim_label)

	_msg_label = Label.new()
	_msg_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_msg_label.clip_text = true
	bar.add_child(_msg_label)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = false
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var log_style := StyleBoxFlat.new()
	log_style.bg_color = Color(0.08, 0.09, 0.11)
	log_style.set_corner_radius_all(6)
	log_style.set_content_margin_all(6)
	_log.add_theme_stylebox_override("normal", log_style)
	v.add_child(_log)
	return p


# ---------- Связь с логикой ----------

func bind(p_manager: SimulationManager, p_logger: EventLogger, p_grid: WarehouseGrid) -> void:
	manager = p_manager
	logger = p_logger
	grid = p_grid
	manager.robot_added.connect(_on_robot_added)
	manager.robot_removed.connect(_on_robot_removed)
	manager.robot_changed.connect(_update_row)
	manager.selection_changed.connect(_on_selection_changed)
	logger.entry_added.connect(_on_log_entry)
	for e in logger.entries:
		_append_log(e)
		_log_lines += 1
	_rebuild_list()


func notify(text: String, is_error: bool = false) -> void:
	_msg_label.text = text
	_msg_label.add_theme_color_override("font_color", Color(1.0, 0.45, 0.40) if is_error else Color(0.5, 0.9, 0.6))
	_msg_time = 6.0


func set_hover_text(text: String) -> void:
	_hover_label.text = text


func set_move_mode(on: bool) -> void:
	var changed := on != move_mode
	move_mode = on
	_btn_move.set_pressed_no_signal(on)
	_mode_label.visible = on
	if changed:
		move_mode_changed.emit(on)


# ---------- Список роботов ----------

func _rebuild_list() -> void:
	for child in _robot_list.get_children():
		_robot_list.remove_child(child)
		child.queue_free()
	_rows.clear()
	for r in manager.robots:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var swatch := ColorRect.new()  # цвет самого робота в 3D-сцене
		swatch.color = r.robot_color
		swatch.custom_minimum_size = Vector2(5, 22)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var dot := ColorRect.new()     # индикатор статуса
		dot.custom_minimum_size = Vector2(12, 12)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(dot)
		var btn := Button.new()
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_row_pressed.bind(r))
		row.add_child(btn)
		_robot_list.add_child(row)
		_rows[r.id] = {"button": btn, "dot": dot}
		_update_row(r)
	_count_label.text = "Всего: %d" % manager.robots.size()


func _update_row(r: RobotAgent) -> void:
	if not _rows.has(r.id):
		return
	var entry: Dictionary = _rows[r.id]
	var dot: ColorRect = entry["dot"]
	var btn: Button = entry["button"]
	dot.color = RobotAgent.state_color(r.state)
	btn.text = "%s   %s" % [r.id, RobotAgent.state_name(r.state)]
	btn.set_pressed_no_signal(manager.selected == r)


func _on_row_pressed(r: RobotAgent) -> void:
	manager.select(r)
	_update_all_rows()  # если нажали на уже выбранного, тумблер должен остаться нажатым


func _update_all_rows() -> void:
	for r in manager.robots:
		_update_row(r)


func _on_robot_added(_r: RobotAgent) -> void:
	_rebuild_list()


func _on_robot_removed(_id: String) -> void:
	_rebuild_list()


func _on_selection_changed(_r: RobotAgent) -> void:
	set_move_mode(false)
	_update_all_rows()


# ---------- Обновление каждый кадр ----------

func _process(delta: float) -> void:
	if manager == null:
		return
	_refresh()
	if _msg_time > 0.0:
		_msg_time -= delta
		if _msg_time <= 0.0:
			_msg_label.text = ""


func _set_info(key: String, text: String, color: Color = COL_TEXT) -> void:
	var l: Label = _info_values[key]
	l.text = text
	l.add_theme_color_override("font_color", color)


func _refresh() -> void:
	var r: RobotAgent = manager.selected
	var has := r != null
	var is_disabled := has and r.state == RobotAgent.State.DISABLED
	_empty_label.visible = not has
	_info_grid.visible = has

	if has:
		_set_info("id", r.id)
		_set_info("cell", "(%d, %d)\nмир: %.1f; %.1f" % [r.cell.x, r.cell.y, r.position.x, r.position.z])
		_set_info("status", RobotAgent.state_name(r.state), RobotAgent.state_color(r.state))
		_set_info("speed", "%.1f яч./с  (×%s)" % [r.speed, str(manager.speed_mult())])
		_set_info("target", grid.cell_label(r.target) if r.has_target else "—")
		_set_info("route", str(r.route_cells().size()))
		_set_info("access", "отключён" if is_disabled else "доступен",
			Color(1.0, 0.5, 0.45) if is_disabled else Color(0.5, 0.9, 0.6))

	if move_mode and (not has or is_disabled):
		set_move_mode(false)

	_btn_move.disabled = not has or is_disabled
	_btn_pause.disabled = not has or not (r.state == RobotAgent.State.MOVING or r.state == RobotAgent.State.WORKING)
	_btn_resume.disabled = not has or r.state != RobotAgent.State.PAUSED
	_btn_reset.disabled = not has
	_btn_toggle.disabled = not has
	_btn_toggle.text = "Enable" if is_disabled else "Disable"
	_btn_remove.disabled = not has

	if move_mode and has:
		_mode_label.text = "Режим Move: кликните по свободной ячейке склада для %s  (Esc — отмена)" % r.id
		_move_hint.text = "Выберите ячейку в 3D-сцене. Зелёная подсветка — цель допустима, красная — недоступна."
	elif not has:
		_move_hint.text = "Выберите робота, чтобы управлять им."
	elif is_disabled:
		_move_hint.text = "Робот отключён: нажмите Enable, чтобы вернуть управление."
	else:
		_move_hint.text = "Нажмите Move и выберите ячейку на складе."

	# Общие команды
	_btn_run.text = "Pause" if manager.running else "Start"
	var any_paused := false
	for rb in manager.robots:
		if rb.state == RobotAgent.State.PAUSED:
			any_paused = true
			break
	_btn_resume_all.disabled = manager.running and not any_paused
	_btn_add.disabled = manager.robots.size() >= SimulationManager.MAX_ROBOTS
	_btn_slower.disabled = manager.speed_index <= 0
	_btn_faster.disabled = manager.speed_index >= SimulationManager.SPEEDS.size() - 1
	_speed_label.text = "×" + str(manager.speed_mult())
	_sim_label.text = "  Симуляция: идёт" if manager.running else "  Симуляция: ПАУЗА"
	_sim_label.add_theme_color_override("font_color", Color(0.5, 0.9, 0.6) if manager.running else Color(1.0, 0.85, 0.3))


# ---------- Обработчики кнопок ----------

func _on_move_pressed() -> void:
	if manager.selected == null:
		set_move_mode(false)
		notify("Сначала выберите робота.", true)
		return
	set_move_mode(_btn_move.button_pressed)


func _on_pause_pressed() -> void:
	_report(manager.cmd_pause(manager.selected))


func _on_resume_pressed() -> void:
	_report(manager.cmd_resume(manager.selected))


func _on_reset_pressed() -> void:
	_report(manager.cmd_reset(manager.selected))


func _on_toggle_pressed() -> void:
	_report(manager.cmd_toggle_disabled(manager.selected))


func _on_remove_pressed() -> void:
	var r := manager.selected
	if r == null:
		notify("Сначала выберите робота.", true)
		return
	_pending_remove = r
	_confirm.dialog_text = "Удалить робота %s из сцены?\nЭто действие нельзя отменить." % r.id
	_confirm.popup_centered()


func _on_remove_confirmed() -> void:
	var r = _pending_remove
	_pending_remove = null
	_report(manager.cmd_remove(r))


func _on_run_pressed() -> void:
	manager.toggle_running()


func _on_resume_all_pressed() -> void:
	manager.resume_all()


func _on_reset_sim_pressed() -> void:
	manager.reset_all()
	set_move_mode(false)


func _on_add_pressed() -> void:
	var r := manager.add_robot()
	if r == null:
		notify("Не удалось добавить робота: достигнут лимит или нет свободного места.", true)
	else:
		manager.select(r)


func _on_demo_pressed() -> void:
	manager.assign_demo_tasks()


func _on_slower_pressed() -> void:
	manager.change_speed(-1)


func _on_faster_pressed() -> void:
	manager.change_speed(1)


func _on_camera_pressed() -> void:
	camera_reset_requested.emit()


func _report(err: String) -> void:
	if err != "":
		notify(err, true)


# ---------- Журнал ----------

func _on_log_entry(e: Dictionary) -> void:
	_log_lines += 1
	if _log_lines > MAX_LOG_LINES:
		# Периодически перестраиваем журнал из буфера логгера, чтобы он не рос бесконечно.
		_log.clear()
		_log_lines = 0
		for old in logger.entries:
			_append_log(old)
			_log_lines += 1
		return
	_append_log(e)


func _append_log(e: Dictionary) -> void:
	_log.append_text("[color=#6c7a89]%s[/color]  [color=%s]%s[/color]\n" % [e["time"], LEVEL_COLORS[e["level"]], e["text"]])
