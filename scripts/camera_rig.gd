class_name CameraRig
extends Node3D
## Орбитальная камера: вращение, сдвиг, масштаб и пересечение луча с плоскостью пола.
## Сам узел стоит в точке фокуса, камера — на расстоянии distance позади него.

const MIN_DIST := 6.0
const MAX_DIST := 55.0
const DEFAULT_YAW := 0.0
const DEFAULT_PITCH := 0.95
const DEFAULT_DIST := 25.0
const PITCH_MIN := 0.2
const PITCH_MAX := 1.45

var camera: Camera3D
var focus := Vector3.ZERO
var yaw := DEFAULT_YAW
var pitch := DEFAULT_PITCH
var distance := DEFAULT_DIST
var limit := Vector2(16.0, 12.0)  # насколько далеко от центра можно сдвигать фокус


func _ready() -> void:
	camera = Camera3D.new()
	camera.fov = 45.0
	camera.near = 0.1
	camera.far = 250.0
	add_child(camera)
	camera.current = true
	_apply()


func reset() -> void:
	focus = Vector3.ZERO
	yaw = DEFAULT_YAW
	pitch = DEFAULT_PITCH
	distance = DEFAULT_DIST
	_apply()


func orbit(relative: Vector2) -> void:
	yaw -= relative.x * 0.005
	pitch = clampf(pitch + relative.y * 0.005, PITCH_MIN, PITCH_MAX)
	_apply()


func rotate_yaw(amount: float) -> void:
	yaw += amount
	_apply()


## Сдвиг «за землю»: сцена следует за курсором.
func pan(relative: Vector2) -> void:
	var s := distance * 0.0016
	focus += (_forward() * relative.y - _right() * relative.x) * s
	_apply()


## dir.x — вправо/влево, dir.y — назад/вперёд (W = -1).
func move_planar(dir: Vector2, delta: float) -> void:
	focus += (_right() * dir.x - _forward() * dir.y) * distance * 0.6 * delta
	_apply()


func zoom(direction: float) -> void:
	zoom_by(1.0 + 0.1 * direction)


func zoom_by(factor: float) -> void:
	distance = clampf(distance * factor, MIN_DIST, MAX_DIST)
	_apply()


## Точка пересечения луча из камеры через пиксель с плоскостью y = 0; null — луч не попал в пол.
func ground_point(screen_pos: Vector2) -> Variant:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	return from + dir * t


func _forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


func _right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


func _apply() -> void:
	focus.x = clampf(focus.x, -limit.x, limit.x)
	focus.z = clampf(focus.z, -limit.y, limit.y)
	position = focus
	rotation = Vector3(-pitch, yaw, 0.0)
	if camera != null:
		camera.position = Vector3(0.0, 0.0, distance)
