extends SceneTree
## 验证四个角色都能加载、动画齐全、且切换后朝向动画仍然正确
var step := 0
var p
var anim
var ids := ["adam", "ash", "lucy", "nancy"]
var dirs := [Vector2.RIGHT, Vector2.UP, Vector2.LEFT, Vector2.DOWN]
var names := ["right", "up", "left", "down"]

func _initialize() -> void:
	var scn = load("res://scenes/sandbox/phase1.tscn").instantiate()
	root.add_child(scn)
	p = scn.get_node("Player")
	anim = p.get_node("AnimatedSprite2D")
	p.set_physics_process(false)

func _physics_process(_d: float) -> bool:
	step += 1
	if step < 3: return false
	var i := step - 3
	if i < ids.size():
		p.set_hero(ids[i])
		var ok: bool = true
		var msg: String = ""
		for k in dirs.size():
			p._apply_movement(dirs[k])
			var want: String = str(names[k]) + "_walk"
			if String(anim.animation) != want or anim.sprite_frames.get_frame_count(want) != 6:
				ok = false
				msg += " [%s→%s]" % [want, anim.animation]
		var total: int = anim.sprite_frames.get_animation_names().size()
		print("%-6s 动画组=%d 四方向=%s%s" % [ids[i], total, "OK" if ok else "FAIL", msg])
	elif i == ids.size():
		quit(0)
		return true
	return false
