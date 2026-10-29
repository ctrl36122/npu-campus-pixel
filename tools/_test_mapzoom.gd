extends SceneTree
## 验证全屏地图的缩放：连续向下滚要能缩到下限（原来被写死 1.0，只能放大）

var step := 0
var boot


func _initialize() -> void:
	boot = load("res://scenes/online_boot.tscn").instantiate()
	root.add_child(boot)


func _process(_d: float) -> bool:
	step += 1
	if step == 330:
		boot.call("_open_map")
	elif step == 350:
		var m = boot.get("_map")
		if m == null or not is_instance_valid(m):
			print("结果 FAIL：地图没创建出来")
			quit(1)
			return true
		m.size = Vector2(1280, 720)
		print("初始 zoom=%.2f" % m.zoom)
		for _i in 10:
			m.call("_zoom_at", m.zoom / 1.18, Vector2(640, 360))
		print("连续缩小后 zoom=%.2f" % m.zoom)
		for _i in 40:
			m.call("_zoom_at", m.zoom * 1.18, Vector2(640, 360))
		print("连续放大后 zoom=%.2f" % m.zoom)
		m.call("reset_view")
		print("复位后 zoom=%.2f" % m.zoom)
		quit(0)
		return true
	return false
