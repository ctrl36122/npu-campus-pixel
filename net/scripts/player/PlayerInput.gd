class_name PlayerInput
extends RefCounted
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
		# 只有「文本输入框」抢到焦点时才冻结移动（聊天框打字）。
		# 之前只要有控件持有焦点就清零，结果点过一次电梯/设置按钮之后，
		# 按钮一直拿着焦点，人就再也走不动了 —— 看着就是「莫名卡死」。
		var focus: Control = avatar.get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			direction = Vector2.ZERO
	var command: Dictionary = {"seq": seq, "x": direction.x, "y": direction.y, "aim": aim,
		"sprint": sprint}
	command["round"] = avatar.round_id
	return command
