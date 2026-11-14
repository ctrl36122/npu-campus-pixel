extends SceneTree
## 单独把 scenes/world.tscn 摆出来拍一张，专门核对静态画面（车辆、道具）。
## 用法：
##   godot --path . --script res://tools/_shot_world.gd --resolution 1280x720
## 环境变量：
##   XGD_SHOT_AT="格x,格y"  相机中心（默认 124,79 停车场）
##   XGD_SHOT_ZOOM=4        缩放（1 世界像素 = N 屏幕像素）
##   XGD_SHOT_OUT="res://shot_world.png"

var _f := 0
var _out := "res://shot_world.png"


func _initialize() -> void:
	var at := Vector2(124, 79)
	var raw := OS.get_environment("XGD_SHOT_AT").strip_edges()
	if not raw.is_empty():
		var p := raw.split(",")
		if p.size() == 2:
			at = Vector2(float(p[0]), float(p[1]))
	var zoom := 4.0
	var zr := OS.get_environment("XGD_SHOT_ZOOM").strip_edges()
	if not zr.is_empty() and zr.is_valid_float():
		zoom = float(zr)
	var oraw := OS.get_environment("XGD_SHOT_OUT").strip_edges()
	if not oraw.is_empty():
		_out = oraw

	var world = load("res://scenes/world.tscn").instantiate()
	root.add_child(world)
	var cam := Camera2D.new()
	cam.name = "ShotCam"
	cam.zoom = Vector2(zoom, zoom)
	cam.position = at * 8.0
	cam.enabled = true
	root.add_child(cam)
	print("[shot] 世界已加载，相机 ", at, " zoom ", zoom)


func _process(_dt: float) -> bool:
	_f += 1
	if _f == 12:
		var img := root.get_texture().get_image()
		img.save_png(_out)
		print("[shot] 已保存 ", _out, " ", img.get_size())
		return true
	return false
