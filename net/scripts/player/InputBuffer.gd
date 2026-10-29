class_name InputBuffer
extends RefCounted
## The commands this client has sent but the server has not confirmed yet, with
## the position the client predicted after each one. Used for reconciliation.
const CAPACITY: int = 64
var entries: Array[Dictionary] = []

func push(command: Dictionary, predicted: Vector2) -> void:
	if entries.size() < CAPACITY:
		entries.append({"command": command.duplicate(), "position": predicted})

func pending() -> Array:
	var commands: Array = []
	for entry in entries:
		commands.append(entry["command"])
	return commands

func predicted_at(seq: int) -> Variant:
	for entry in entries:
		if int(entry["command"]["seq"]) == seq:
			return entry["position"]
	return null

func drop_through(seq: int) -> void:
	while not entries.is_empty() and int(entries.front()["command"]["seq"]) <= seq:
		entries.pop_front()
