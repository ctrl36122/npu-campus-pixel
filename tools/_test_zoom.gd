extends SceneTree
## 验证世界内镜头缩放：
##   1) 直接调 zoom_step 测上下限钳制
##   2) 用真实滚轮事件走一遍输入分发，确认没被 UI 层吃掉

var step := 0
var p
var cam


func _initialize() -> void:
	root.add_child(load("res://scenes/online_boot.tscn").instantiate())


func _process(_d: float) -> bool:
	step += 1
	if step == 320:
		for n in root.find_children("*", "CharacterBody2D", true, false):
			if n.is_local_player:
				p = n
				break
		if p == null:
			print("结果 FAIL：没找到本地玩家")
			quit(1)
			return true
		cam = p.get_node("Camera")
		print("初始 zoom=%.3f" % cam.zoom.x)
	elif step == 340:
		for _i in 12:
			p.zoom_step(1.0 / 1.14)
		print("缩小目标=%.3f" % p._cam_zoom_target)
	elif step == 400:
		print("缩小实际=%.3f" % cam.zoom.x)
		for _i in 20:
			p.zoom_step(1.14)
		print("放大目标=%.3f" % p._cam_zoom_target)
	elif step == 460:
		print("放大实际=%.3f" % cam.zoom.x)
		p.zoom_reset()
	elif step == 500:
		print("复位=%.3f" % cam.zoom.x)
		# 真实滚轮事件：模拟鼠标在屏幕中央向下滚 5 格
		for _i in 5:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
			ev.pressed = true
			ev.position = Vector2(640, 360)
			Input.parse_input_event(ev)
	elif step == 540:
		print("滚轮事件后目标=%.3f  实际=%.3f" % [p._cam_zoom_target, cam.zoom.x])
		quit(0)
		return true
	return false
