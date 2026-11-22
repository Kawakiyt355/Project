class_name EventLogger
extends RefCounted
## Единый журнал событий. Все компоненты пишут сюда, интерфейс подписан на entry_added.

signal entry_added(entry: Dictionary)

enum Level { INFO, WARN, ERROR }

const MAX_ENTRIES := 300

var entries: Array[Dictionary] = []


func log_event(text: String, level: Level = Level.INFO) -> void:
	var entry := {
		"time": Time.get_time_string_from_system(),
		"text": text,
		"level": level,
	}
	entries.append(entry)
	if entries.size() > MAX_ENTRIES:
		entries.pop_front()
	print("[%s] %s" % [entry["time"], text])  # дублируем в консоль Godot для отладки
	entry_added.emit(entry)


func info(text: String) -> void:
	log_event(text, Level.INFO)


func warn(text: String) -> void:
	log_event(text, Level.WARN)


func error(text: String) -> void:
	log_event(text, Level.ERROR)
