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
		# Typing in the chat box must not move the player.
		if avatar.get_viewport().gui_get_focus_owner() != null:
			direction = Vector2.ZERO
	var command: Dictionary = {"seq": seq, "x": direction.x, "y": direction.y, "aim": aim,
		"sprint": sprint}
	command["round"] = avatar.round_id
	return command
