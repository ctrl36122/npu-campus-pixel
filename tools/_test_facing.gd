extends SceneTree
## 验证四方向朝向切换与动画播放是否真的生效（绕过键盘，直接调移动函数）
var p
var anim
var step := 0
var dirs := [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]

func _initialize() -> void:
	var ps = load("res://scenes/sandbox/phase1.tscn")
	var scn = ps.instantiate()
	root.add_child(scn)
	p = scn.get_node("Player")
	anim = p.get_node("AnimatedSprite2D")
	p.set_physics_process(false)

func _physics_process(_d: float) -> bool:
	step += 1
	if step < 3: return false
	var i := step - 3
	if i < dirs.size():
		p._apply_movement(dirs[i])
		print("输入 ", dirs[i], " → facing=", p.facing, " anim=", anim.animation,
			" playing=", anim.is_playing(), " frames=", anim.sprite_frames.get_frame_count(anim.animation))
	elif i == dirs.size():
		p._apply_movement(Vector2.ZERO)
		print("松手 → anim=", anim.animation, " frame=", anim.frame, " playing=", anim.is_playing())
		var names = []
		for a in anim.sprite_frames.get_animation_names(): names.append(a)
		print("可用动画: ", names)
		quit(0)
		return true
	return false
