extends SceneTree
## 验证截图工具：加载指定场景 → 渲染 60 帧 → 存 PNG → 退出
##
## 用法：
##   godot --path . --script res://tools/_verify_shot.gd --resolution 1280x720 -- \
##         --scene=res://scenes/sandbox/phase1.tscn --shot=user://a.png [--zoom=2] [--at=48,52]

var n := 0
var shot_path := "user://verify_shot.png"
var scene_path := "res://scenes/main.tscn"
var zoom := -1.0                 # <=0 表示不改，沿用场景自带视距
var at := Vector2(-1, -1)
var confirm_name := ""
var frames := 60
var open_map := false
var map_zoom := -1.0             # 打开全屏地图后把它设到这个倍率（验证楼名）
var teleport_to := Vector2(-1, -1)
var chat_text := ""


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			shot_path = a.substr(7)
		elif a.begins_with("--scene="):
			scene_path = a.substr(8)
		elif a.begins_with("--zoom="):
			zoom = float(a.substr(7))
		elif a.begins_with("--frames="):
			frames = int(a.substr(9))
		elif a.begins_with("--confirm="):
			confirm_name = a.substr(10)
		elif a == "--open-map":
			open_map = true
		elif a.begins_with("--map-zoom="):
			map_zoom = float(a.substr(11))
		elif a.begins_with("--tp="):
			var v2 := a.substr(5).split(",")
			if v2.size() == 2:
				teleport_to = Vector2(float(v2[0]), float(v2[1]))
		elif a.begins_with("--chat="):
			chat_text = a.substr(7)
		elif a.begins_with("--at="):
			var v := a.substr(5).split(",")
			if v.size() == 2:
				at = Vector2(float(v[0]), float(v[1]))
	var ps = load(scene_path)
	if ps == null:
		push_error("场景加载失败: " + scene_path)
		quit(1)
		return
	root.add_child(ps.instantiate())


func _process(_delta: float) -> bool:
	n += 1
	if n == 12 and at.x >= 0.0:
		var found := root.find_children("*", "CharacterBody2D", true, false)
		if found.size() > 0:
			found[0].position = at * 8.0
	if n == 25 and confirm_name != "":
		var ui = root.find_child("CharCreate", true, false)
		if ui != null:
			ui._name_edit.text = confirm_name
			ui._confirm()
	if zoom > 0.0 and n >= int(frames * 0.15):
		# 必须改玩家自己的目标视距：直接写 cam.zoom 会被 _update_camera_zoom 拉回去。
		# 每帧重设（幂等）：联机握手要几秒，玩家可能在任意帧才生成，
		# 只在单帧设一次会赶在角色出生前执行然后永远丢失。
		for node in root.find_children("*", "CharacterBody2D", true, false):
			if node.is_local_player:
				node._cam_zoom_target = zoom
				break
	if open_map and n == frames - 40:
		var boot = root.get_node_or_null("OnlineBoot")
		if boot != null:
			boot.call("_open_map")
			# --map-zoom=N：打开后把全屏地图设到指定倍率（验证楼名显示）
			if map_zoom > 0.0:
				var mp = boot.get_node_or_null("UILayer/WorldMap")
				if mp == null:
					for c in boot.get_children():
						if c.name == "WorldMap":
							mp = c
							break
				if mp != null:
					mp.zoom = map_zoom
					mp.queue_redraw()
	# 传送放在 63% 处：headless 不限帧时帧数不等于时间，留太短相机会追不上
	if teleport_to.x >= 0.0 and n == int(frames * 0.63):
		# --tp=x,y 传的是「校园格坐标」，转成世界坐标后请求传送
		# SceneTree 脚本里拿不到 autoload 的全局名，走节点路径
		var sf = root.get_node_or_null("SessionFlow")
		if sf != null:
			var w = sf.world
			if w != null and is_instance_valid(w):
				w.request_teleport(w.campus.to_global(teleport_to * 8.0))
	if chat_text != "" and n == int(frames * 0.72):
		var net = root.get_node_or_null("Net")
		if net != null:
			net.call("post_message", chat_text)
	if n == frames:
		var img := root.get_texture().get_image()
		var abs_path := ProjectSettings.globalize_path(shot_path)
		var err := img.save_png(abs_path)
		print("SHOT ", abs_path, " err=", err, " size=", img.get_width(), "x", img.get_height())
		return true
	return false
