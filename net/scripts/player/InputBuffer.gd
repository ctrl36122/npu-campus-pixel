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


## 服务端确认长时间不到时，丢掉最老一条给新输入让位。
## 缓冲满就停止采样会让本地预测一起停摆（人原地定住 ~2 秒后彻底不动），
## 宁可少一条待确认命令，也不能不读键盘。
func drop_oldest() -> void:
	if not entries.is_empty():
		entries.pop_front()
