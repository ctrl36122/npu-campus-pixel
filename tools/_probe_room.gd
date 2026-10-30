extends SceneTree
## 房间渲染调试：单独把 Room 挂起来截图，不启动联机、不加载校园。
##
## 跑法：
##   XGD_OFFLINE=1 godot --path . --script tools/_probe_room.gd --resolution 1280x720
##   XGD_CAM="95,50,1.5" 可指定「格x,格y,zoom」盯某个位置
## 产物：shot_room.png（项目根目录）
##
## 注意：搭建必须等到第一帧之后。在 _initialize() 里 root 还没进树，
## add_child 会「成功」但 is_inside_tree() 仍是 false，子节点的 _draw 也就不会执行。

const RoomScript := preload("res://net/scenes/Room.gd")
const OUT := "res://shot_room.png"

var _room: Node2D
var _frame := 0


func _initialize() -> void:
	RenderingServer.set_default_clear_color(Color("090d12"))


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 2:
		_build()
	elif _frame == 12:
		_shot()
		quit()
		return true
	return false


func _build() -> void:
	_room = Node2D.new()
	_room.name = "Room"
	_room.set_script(RoomScript)
	get_root().add_child(_room)

	if not bool(_room.call("load_room", "res://assets/rooms/dorm_space.json")):
		printerr("[probe] 房间加载失败")
		quit(1)
		return

	var size: Vector2 = _room.get("size_px")
	print("[probe] 房间局部尺寸 ", size, "  全局 ", size * 2.0)
	print("[probe] 家具节点 ", _room.get("objects").get_child_count(), " 个")

	var cam := Camera2D.new()
	cam.name = "ProbeCam"
	get_root().add_child(cam)

	var focus := OS.get_environment("XGD_CAM")
	if focus == "" or focus == "full":
		cam.position = size * 2.0 * 0.5
		var vp := Vector2(1280, 720)
		var need := maxf(size.x * 2.0 / vp.x, size.y * 2.0 / vp.y)
		cam.zoom = Vector2.ONE / maxf(need, 0.01) * 0.96
	else:
		var parts := focus.split(",")
		if parts.size() >= 2:
			cam.position = Vector2(float(parts[0]), float(parts[1])) * 8.0 * 2.0
			var z := parts[2].to_float() if parts.size() >= 3 else 1.2
			cam.zoom = Vector2(z, z)
	cam.make_current()
	print("[probe] 相机 ", cam.position, " zoom ", cam.zoom)


func _shot() -> void:
	var img := get_root().get_texture().get_image()
	if img.save_png(OUT) == OK:
		print("[probe] 已保存 ", OUT, "  ", img.get_width(), "×", img.get_height())
	else:
		printerr("[probe] 保存失败")
