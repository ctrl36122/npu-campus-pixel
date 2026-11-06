extends SceneTree
## 图书馆自习空间回归测试。
##
## 覆盖：房间数据 / 亮色地板实际像素 / 两人一桌 / 内部楼层号 7 /
## 图书馆门口热点 → 进房 → 走回门口 → 出房 的完整闭环。
##
##   APPDATA=<临时目录> XGD_OFFLINE=1 XGD_NOHOME=1 XGD_ROOM=1 XGD_ROOM_FLOOR=7 \
##     godot --headless --script res://tools/_test_study_room.gd

var arena: Node = null
var net: Node = null
var frames := 0
var phase := 0
var checks := 0
var fails: Array[String] = []
var hotspot := Vector2.ZERO
var left_once := false


func _initialize() -> void:
	change_scene_to_file("res://scenes/online_boot.tscn")


func _find_arena(n: Node) -> Node:
	if n == null:
		return null
	var sc = n.get_script()
	if sc != null and String(sc.resource_path).ends_with("Arena.gd"):
		return n
	for c in n.get_children():
		var r := _find_arena(c)
		if r != null:
			return r
	return null


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _finish() -> bool:
	if fails.is_empty():
		print("结果 PASS：自习空间 %d 项全过" % checks)
		quit(0)
	else:
		print("结果 FAIL：%s" % ", ".join(fails))
		quit(1)
	return true


func _process(_d: float) -> bool:
	frames += 1
	if frames > 600:
		print("超时")
		fails.append("探针超时（有阶段没跑完）")
		return _finish()
	if arena == null:
		arena = _find_arena(root)
		net = root.get_node_or_null("Net")
		return false
	# 只有第 0 阶段要等「自动进房」。后面会主动 leave_room() 回校园，
	# 这里若还拿 in_room 当门槛，第 6 阶段永远进不去，会伪装成 PASS。
	if phase == 0 and not bool(arena.get("in_room")):
		return false
	match phase:
		0:
			_test_room()
			phase = 1
			frames = 0
		1:
			if frames < 3:
				return false
			_leave_and_probe_entry()
			phase = 2
			frames = 0
		2:
			if frames < 8:
				return false
			return _test_reentry()
	return false


func _test_room() -> void:
	print("[1] 房间数据与内部楼层")
	var room: Node = arena.get("room")
	_ok(room != null and is_instance_valid(room), "房间实例已建")
	var d: Dictionary = room.get("data")
	_ok(String(d.get("id", "")) == "study_space", "加载的是 study_space")
	_ok(bool(d.get("bright", false)), "数据带 bright 标记")
	_ok(bool(room.get("bright")), "Room 已切到亮色主题")
	_ok(int(arena.get("current_floor")) == 7, "内部楼层号 = 7")
	_ok(String(arena.call("_room_path_for", 7)).ends_with("study_space.json"),
		"楼层 7 映射到自习空间")
	_ok(String(arena.call("_room_id_for", "res://assets/rooms/study_space.json")) == "study_space",
		"房间 id 映射正确")
	_ok(String((arena.get("_floor_label") as Label).text) == "图书馆 · 自习空间",
		"楼层标签文案正确")

	print("[2] 明亮（直接量地板像素，不靠肉眼）")
	var spr: Sprite2D = room.get_node_or_null("Floor") as Sprite2D
	_ok(spr != null and spr.texture != null, "地板贴图已烘焙")
	if spr != null and spr.texture != null:
		var img: Image = spr.texture.get_image()
		var px: Vector2i = Vector2i(int(img.get_width() * 0.5), int(img.get_height() * 0.5))
		var c := img.get_pixel(px.x, px.y)
		var lum := (c.r + c.g + c.b) / 3.0
		_ok(lum > 0.60, "房间中央地板是浅色", "亮度 %.3f @%s" % [lum, px])
		_ok(lum < 0.98, "没有亮到过曝成纯白", "亮度 %.3f" % lum)

	print("[3] 一整个大间 · 两个人一桌")
	var tables: Array = []
	for p in d.get("props", []):
		if String(p.get("k", "")) == "table" and float(p.get("w", 0)) == 9.0:
			tables.append(p)
	_ok(tables.size() == 12, "12 张双人桌", str(tables.size()))
	_ok((d.get("room_doors", []) as Array).is_empty(), "没有分隔单间的门")
	_ok((d.get("team_boards", []) as Array).is_empty(), "没有组队板")
	var walls: Array = d.get("walls", [])
	_ok(walls.size() == 5, "只有四面外墙（南墙按门洞切两段）", str(walls.size()))
	var seats: Array = d.get("seats", [])
	_ok(seats.size() == 26, "26 个座位（12×2 + 2 个坐垫）", str(seats.size()))
	var pairs := 0
	for t in tables:
		var fs: Array = []
		for s in seats:
			if absf(float(s["x"]) + float(s["w"]) * 0.5
					- (float(t["x"]) + float(t["w"]) * 0.5)) > 0.01:
				continue
			if absf(float(s["y"]) + float(s["h"]) - float(t["y"])) < 1.0 \
					or absf(float(s["y"]) - float(t["y"] + t["h"])) < 1.0:
				fs.append(String(s.get("face", "")))
		if fs.size() == 2 and fs.has("up") and fs.has("down"):
			pairs += 1
	_ok(pairs == 12, "12 张桌都配了南北对面的两把椅", str(pairs))
	_ok((room.get("seats") as Array).size() == 26, "Room 实际建出 26 个可坐点")
	var wins := 0
	for p in d.get("props", []):
		if String(p.get("k", "")) == "window":
			wins += 1
	_ok(wins == 6, "北墙 6 扇连续落地窗", str(wins))

	print("[4] 自习空间不混进宿舍 / B1 的东西")
	_ok((d.get("beds", []) as Array).is_empty(), "没有床")
	_ok((d.get("pod_floors", []) as Array).is_empty(), "没有深色机位地胶")
	_ok(not d.has("elevator"), "没有电梯（自习空间不换层）")
	arena.call("_open_floor_panel")
	_ok(not bool(arena.get("_floor_open")), "7 层里电梯面板打不开")
	var host: Node2D = room.call("anchor") as Node2D
	var beds := 0
	for c in host.get_children():
		if String(c.name).begins_with("CatBed_"):
			beds += 1
	_ok(beds == 0, "公共空间不摆猫窝")

	print("[4b] 回归：亮色主题只作用于自习空间")
	var RS = load("res://net/scenes/Room.gd")
	for p in ["res://assets/rooms/dorm_space.json", "res://assets/rooms/activity_room.json"]:
		var tmp := Node2D.new()
		tmp.set_script(RS)
		root.add_child(tmp)
		var loaded: bool = tmp.call("load_room", p)
		_ok(loaded, "能加载 %s" % p.get_file())
		if loaded:
			_ok(not bool(tmp.get("bright")), "%s 仍是暗色主题" % p.get_file())
			var fs: Sprite2D = tmp.get_node_or_null("Floor") as Sprite2D
			if fs != null and fs.texture != null:
				var im: Image = fs.texture.get_image()
				var cc := im.get_pixel(int(im.get_width() * 0.5), int(im.get_height() * 0.5))
				var lum2 := (cc.r + cc.g + cc.b) / 3.0
				_ok(lum2 < 0.35, "%s 地板仍是深色" % p.get_file(), "亮度 %.3f" % lum2)
		root.remove_child(tmp)
		tmp.queue_free()


func _leave_and_probe_entry() -> void:
	print("[5] 图书馆门口热点")
	var entries: Array = arena.get("_study_entries")
	_ok(entries.size() == 1, "收集到 1 处图书馆入口", str(entries.size()))
	if entries.is_empty():
		return
	var e: Dictionary = entries[0]
	var r: Rect2 = e["rect"]
	hotspot = r.get_center()
	_ok(String(e["name"]).contains("图书馆"), "入口挂在图书馆", String(e["name"]))
	_ok(hotspot.y >= 375.0 and hotspot.y <= 390.0,
		"门热点落在图书馆南沿广场", "y=%.1f" % hotspot.y)
	_ok(e.get("sign") != null, "门口有可见招牌")
	# 走出去，再站到热点上
	arena.call("leave_room")
	left_once = true
	var me: Node2D = arena.call("_local_avatar") as Node2D
	if me != null:
		me.call("teleport_to", hotspot * 8.0)
		print("  已站到图书馆门口 cell=%s" % hotspot)


func _test_reentry() -> bool:
	print("[6] 站在图书馆门口按 E 进自习空间")
	_ok(left_once, "已从自习空间走出来")
	_ok(not bool(arena.get("in_room")), "出房后回到校园")
	_ok(String(arena.get("_near_study")) != "", "热点被识别",
		String(arena.get("_near_study")))
	var hint: Button = arena.get("_door_hint")
	_ok(hint != null and hint.text.contains("自习空间"), "提示条写的是自习空间",
		hint.text if hint != null else "")
	arena.call("_try_interact")
	var room: Node = arena.get("room")
	_ok(bool(arena.get("in_room")), "按 E 后重新进房")
	_ok(room != null and String(room.get("data").get("id", "")) == "study_space",
		"进的是自习空间而不是宿舍")
	_ok(int(arena.get("current_floor")) == 7, "楼层号回到 7")
	return _finish()
