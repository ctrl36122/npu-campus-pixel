extends SceneTree
## 图书馆内景回归测试。
##
## 覆盖：回字形大房间 / 中庭镂空（地板像素实测）/ 亮色主题只作用于本间 /
## 一张桌两把并排椅 / 内部楼层号 7 / 不挂常驻招牌与标签 /
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
		print("结果 PASS：图书馆内景 %d 项全过" % checks)
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
	_ok(not String(d.get("name", "")).contains("自习空间"), "房间名不标自习空间",
		String(d.get("name", "")))
	_ok(not bool((arena.get("_floor_label") as Label).visible), "房内不挂楼层/空间标签")
	_ok(float(d.get("zoom", 0.0)) > 0.0, "大房间自带镜头倍率",
		"zoom=%.2f" % float(d.get("zoom", 0.0)))

	print("[2] 明亮（直接量地板像素，不靠肉眼）")
	var spr: Sprite2D = room.get_node_or_null("Floor") as Sprite2D
	_ok(spr != null and spr.texture != null, "地板贴图已烘焙")
	if spr != null and spr.texture != null:
		var img: Image = spr.texture.get_image()
		_ok(img.get_width() == 960 and img.get_height() == 960,
			"地板图是 120×120 格", "%d×%d" % [img.get_width(), img.get_height()])
		# 固定像素避开每 12px 的木板拼缝 / 中庭 40px 的天窗格线，量的是面色
		var wood := img.get_pixel(200, 203)
		var hole := img.get_pixel(499, 503)
		var lum_w := (wood.r + wood.g + wood.b) / 3.0
		var lum_h := (hole.r + hole.g + hole.b) / 3.0
		_ok(lum_w > 0.75, "环带地板是浅色", "亮度 %.3f" % lum_w)
		_ok(lum_w < 0.98, "没有亮到过曝成纯白", "亮度 %.3f" % lum_w)
		_ok(lum_h > 0.60, "中庭天光也是浅色（不破坏明亮氛围）", "亮度 %.3f" % lum_h)
		_ok(hole.b - wood.b > 0.12, "中庭与木地板明显不同色（真的挖空了）",
			"Δb=%.3f" % (hole.b - wood.b))

	print("[3] 正方形套正方形 · 四倍面积 · 中间镂空")
	_ok(float(d["W"]) == float(d["H"]), "外框是正方形")
	var area_ratio := float(d["W"]) * float(d["H"]) / (96.0 * 38.0)
	_ok(area_ratio > 3.7 and area_ratio < 4.3, "面积约为原来的 4 倍", "%.2f 倍" % area_ratio)
	var voids: Array = d.get("voids", [])
	_ok(voids.size() == 1, "有 1 块镂空中庭")
	if not voids.is_empty():
		var v: Dictionary = voids[0]
		_ok(float(v["w"]) == float(v["h"]), "中庭也是正方形")
		_ok(absf(float(v["x"]) + float(v["w"]) * 0.5 - float(d["W"]) * 0.5) < 0.01
			and absf(float(v["y"]) + float(v["h"]) * 0.5 - float(d["H"]) * 0.5) < 0.01,
			"中庭居中")
		_ok(float(v["w"]) >= 48.0, "中庭够大，看得出来是回字", "%.0f 格" % float(v["w"]))
	var rails := 0
	for p in d.get("props", []):
		if String(p.get("k", "")) == "rail" and bool(p.get("solid", false)):
			rails += 1
	_ok(rails == 4, "中庭四边都有带碰撞的护栏", str(rails))
	var mm: Texture2D = room.get("minimap_tex")
	if mm != null:
		var mi: Image = mm.get_image()
		var mc := mi.get_pixel(int(mi.get_width() * 0.5), int(mi.get_height() * 0.5))
		var mo := mi.get_pixel(int(mi.get_width() * 0.13), int(mi.get_height() * 0.13))
		_ok((mc.r + mc.g + mc.b) / 3.0 > (mo.r + mo.g + mo.b) / 3.0,
			"小地图上也读得出中间那块方洞")

	print("[4] 一张桌两把椅并排、全部朝前（跟宿舍一样）")
	var tables: Array = []
	for p in d.get("props", []):
		if String(p.get("k", "")) == "table" and float(p.get("w", 0)) == 9.0:
			tables.append(p)
	_ok(tables.size() == 34, "环带里 34 张双人桌", str(tables.size()))
	_ok((d.get("room_doors", []) as Array).is_empty(), "没有分隔单间的门")
	_ok((d.get("team_boards", []) as Array).is_empty(), "没有组队板")
	var walls: Array = d.get("walls", [])
	_ok(walls.size() == 5, "只有四面外墙（南墙按门洞切两段）", str(walls.size()))
	var seats: Array = d.get("seats", [])
	_ok(seats.size() == 72, "72 个座位（34×2 + 4 个坐垫）", str(seats.size()))
	var side_by_side := 0
	for t in tables:
		var pair: Array = []
		for s in seats:
			if "study_lounge" in String(s.get("id", "")):
				continue
			if float(s["x"]) >= float(t["x"]) and float(s["x"]) + float(s["w"]) <= float(t["x"]) + float(t["w"]) \
					and absf(float(s["y"]) - (float(t["y"]) + 3.0)) < 0.01:
				pair.append(s)
		if pair.size() != 2:
			continue
		if absf(float(pair[0]["y"]) - float(pair[1]["y"])) > 0.01:
			continue
		if absf(float(pair[0]["x"]) - float(pair[1]["x"])) < 0.5:
			continue
		if String(pair[0].get("face", "")) == "up" and String(pair[1].get("face", "")) == "up":
			side_by_side += 1
	_ok(side_by_side == 34, "34 张桌都是桌南侧并排、同朝前的两把椅", str(side_by_side))
	var face_up := 0
	for s in seats:
		if String(s.get("face", "")) == "up":
			face_up += 1
	_ok(face_up == seats.size(), "全部座位统一 face=up（含 4 个讨论角坐垫）", str(face_up))
	var room_seats: Array = room.get("seats") as Array
	_ok(room_seats.size() == 72, "Room 实际建出 72 个可坐点")
	var room_up := 0
	for rs in room_seats:
		if String(rs.get("face", "")) == "up":
			room_up += 1
	_ok(room_up == 72, "Room 里 72 个可坐点全是朝前（椅背落在南沿）", str(room_up))
	var wins := 0
	for p in d.get("props", []):
		if String(p.get("k", "")) == "window":
			wins += 1
	_ok(wins == 8, "北墙 8 扇连续落地窗", str(wins))

	print("[4b] 桌面小物：每桌一套、逐桌不重样")
	var desk_props: Array = []
	var item_kinds := {}
	var item_total := 0
	var sigs := {}
	var dup := 0
	var no_book := 0
	var outside := 0
	for p in d.get("props", []):
		var its: Array = p.get("items", [])
		if its.is_empty():
			continue
		desk_props.append(p)
		var sig := ""
		var has_book := false
		var tw := float(p["w"]) * 8.0
		var th := float(p["h"]) * 8.0
		for it in its:
			var k := String(it.get("k", ""))
			item_kinds[k] = true
			item_total += 1
			if k == "book" or k == "notebook":
				has_book = true
			sig += "%s:%s:%s:%s|" % [k, str(it.get("t", 0)),
				str(it.get("px", 0)), str(it.get("py", 0))]
			var px := float(it.get("px", 0.0))
			var py := float(it.get("py", 0.0))
			if px < 1.0 or px + float(it.get("pw", 0.0)) > tw - 1.0 \
					or py < -7.0 or py + float(it.get("ph", 0.0)) > th - 8.0 + 0.01:
				outside += 1
		if not has_book:
			no_book += 1
		if sigs.has(sig):
			dup += 1
		sigs[sig] = true
	_ok(desk_props.size() >= 34, "34 张自习桌都摆了桌面小物", str(desk_props.size()))
	_ok(item_total >= 34, "桌面小物不少于 34 件", str(item_total))
	_ok(item_kinds.size() == 6, "书/水杯/笔记本/电脑/笔筒/台灯六种齐全", str(item_kinds.size()))
	_ok(dup == 0, "没有两张桌摆得一模一样", str(dup))
	_ok(no_book == 0, "每张桌都至少有一件书类", str(no_book))
	_ok(outside == 0, "桌面小物都落在桌面范围内", str(outside))
	var room_objs: Node2D = room.get("objects") as Node2D
	var drawn := 0
	if room_objs != null:
		for n in room_objs.get_children():
			# Object.get() 只吃一个参数；没有 items 的节点拿到 null 直接跳过
			var av: Variant = n.get("items")
			if av is Array and (av as Array).size() > 0:
				drawn += 1
	_ok(drawn >= 34, "Room 把 items 传给了桌子节点（会真的画出来）", str(drawn))

	print("[5] 自习空间不混进宿舍 / B1 的东西")
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

	print("[5b] 回归：亮色主题只作用于自习空间")
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
	print("[6] 图书馆门口热点（不标牌，只靠近提示）")
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
	_ok(not e.has("sign"), "入口不再挂常驻招牌")
	var objs: Node2D = arena.get("campus").get_node_or_null("Objects") as Node2D
	var signs := 0
	if objs != null:
		for c in objs.get_children():
			if String(c.name) == "StudySign":
				signs += 1
	_ok(signs == 0, "场景里没有 StudySign 节点")
	# 走出去，再站到热点上
	arena.call("leave_room")
	left_once = true
	var me: Node2D = arena.call("_local_avatar") as Node2D
	if me != null:
		me.call("teleport_to", hotspot * 8.0)
		print("  已站到图书馆门口 cell=%s" % hotspot)


func _test_reentry() -> bool:
	print("[7] 站在图书馆门口按 E 进去")
	_ok(left_once, "已从内景走出来")
	_ok(not bool(arena.get("in_room")), "出房后回到校园")
	_ok(String(arena.get("_near_study")) != "", "热点被识别",
		String(arena.get("_near_study")))
	var hint: Button = arena.get("_door_hint")
	_ok(hint != null and hint.text.contains("图书馆"), "靠近时才给提示",
		hint.text if hint != null else "")
	_ok(hint != null and not hint.text.contains("自习空间"), "提示里也不标空间名",
		hint.text if hint != null else "")
	arena.call("_try_interact")
	var room: Node = arena.get("room")
	_ok(bool(arena.get("in_room")), "按 E 后重新进房")
	_ok(room != null and String(room.get("data").get("id", "")) == "study_space",
		"进的是图书馆内景而不是宿舍")
	_ok(int(arena.get("current_floor")) == 7, "楼层号回到 7")
	_ok(not bool((arena.get("_floor_label") as Label).visible), "再进来依旧不挂标签")
	return _finish()
