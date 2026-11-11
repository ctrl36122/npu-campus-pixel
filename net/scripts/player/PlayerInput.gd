class_name PlayerInput
extends RefCounted

## 用 preload 而不是全局类名：无头导入时 global_script_class_cache 可能为空。
const GameThemeScript := preload("res://scripts/ui/theme.gd")
## Turns this frame's input into one movement command. A bot can drive it
## instead of the keyboard (see BotClient.gd), which is handy for testing with a
## single person at the computer.

var bot_driven: bool = false
var bot_move: Vector2 = Vector2.ZERO
var bot_aim: float = 0.0


func sample(avatar: Node2D, seq: int, _tick: int) -> Dictionary:
	var direction: Vector2 = bot_move.limit_length()
	var aim: float = bot_aim
	var sprint: bool = false
	if not bot_driven:
		direction = Input.get_vector("move_left", "move_right", "move_up", "move_down")
		aim = (avatar.get_global_mouse_position() - avatar.global_position).angle()
		sprint = Input.is_action_pressed("sprint")
		# 只挡「看得见、正在编辑」的文本输入框（和全局快捷键共用同一判定）。
		# 这里以前只判控件类型不判可见性：面板收起后焦点偶尔仍挂在隐藏的
		# LineEdit 上（设置昵称 / 领养命名 / 门口公告 / 聊天输入都可能），
		# 方向就被永久清零 —— 走在路上忽然卡死动不了的真凶之一。
		if GameThemeScript.is_typing(avatar.get_viewport()):
			direction = Vector2.ZERO
	var command: Dictionary = {"seq": seq, "x": direction.x, "y": direction.y, "aim": aim,
		"sprint": sprint}
	command["round"] = avatar.round_id
	return command
