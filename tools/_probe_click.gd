extends SceneTree
## 最小实验：全屏 Control 里放一个 Button，注入鼠标点击，看 pressed 是否触发。
## 用来把「注入方式有问题」和「聊天框结构有问题」分开。

var b: Button
var n := 0
var hits := 0


func _initialize() -> void:
	var w := Control.new()
	w.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(w)
	b = Button.new()
	b.text = "X"
	b.position = Vector2(100, 100)
	b.size = Vector2(200, 80)
	b.pressed.connect(func():
		hits += 1
		print("  >>> pressed 触发"))
	w.add_child(b)


func _process(_d: float) -> bool:
	n += 1
	if n == 10:
		print("[probe] viewport=", root.get_visible_rect().size, " window=", DisplayServer.window_get_size())
		print("[probe] button rect=", b.get_global_rect())
		var md := InputEventMouseButton.new()
		md.button_index = MOUSE_BUTTON_LEFT
		md.position = Vector2(200, 140)
		md.global_position = md.position
		md.pressed = true
		root.push_input(md, true)
		var mu := InputEventMouseButton.new()
		mu.button_index = MOUSE_BUTTON_LEFT
		mu.position = Vector2(200, 140)
		mu.global_position = mu.position
		mu.pressed = false
		root.push_input(mu, true)
	elif n == 20:
		print("[probe] 鼠标注入 hits=", hits)
		var td := InputEventScreenTouch.new()
		td.index = 0
		td.position = Vector2(200, 140)
		td.pressed = true
		root.push_input(td, true)
		var tu := InputEventScreenTouch.new()
		tu.index = 0
		tu.position = Vector2(200, 140)
		tu.pressed = false
		root.push_input(tu, true)
	elif n == 30:
		print("[probe] 触摸注入后 hits=", hits)
		quit(0)
		return true
	return false
