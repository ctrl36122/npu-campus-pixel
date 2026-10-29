extends CanvasLayer
## Controls and round info while a round is running.

@onready var label: Label = $Label


func _process(_delta: float) -> void:
	if not is_instance_valid(SessionFlow.world) or GameState.phase == GameState.Phase.LOBBY:
		label.text = ""
		return
	var text: String = "WASD move | Shift sprint | Space emote | F3 inspector | F4 lag dial | Click the chat box to talk"
	text += "\nRound %d | %d players | %d s left" % [GameState.round_id, Net.peer_count(), ceili(GameState.seconds_left)]
	if GameState.phase == GameState.Phase.ENDED:
		text += "\nROUND OVER. Back to the lobby in a moment."
	label.text = text
