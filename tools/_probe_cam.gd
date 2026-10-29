extends SceneTree
func _initialize() -> void:
	var scn = load("res://scenes/sandbox/phase1.tscn").instantiate()
	root.add_child(scn)
	var p = scn.get_node("Player")
	var c = p.get_node("Camera2D")
	print("level_bounds=", p.level_bounds, " limit=(", c.limit_left, ",", c.limit_top, ",", c.limit_right, ",", c.limit_bottom, ")")
	print("player=", p.position, " zoom=", c.zoom)
	quit(0)
