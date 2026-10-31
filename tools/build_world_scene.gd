extends SceneTree
## 把 assets/world.json + 烘焙贴图 生成成一个【可编辑的 Godot 关卡场景】res://scenes/world.tscn
##
## 用法：
##   godot --headless --path . --script res://tools/build_world_scene.gd            # 已存在则跳过
##   godot --headless --path . --script res://tools/build_world_scene.gd -- --force # 强制重建（会覆盖手工修改）
##
## 生成后的层级（都能在编辑器里直接拖）：
##   World
##   ├── Ground     28 张地面分块（Sprite2D）
##   ├── Objects    开 y_sort；建筑 = StaticBody2D(含 Sprite + CollisionPolygon2D)，装饰 = Sprite2D
##   └── Water      StaticBody2D + 448 个矩形碰撞

const CELL := 8.0
const OUT := "res://scenes/world.tscn"
const NEAREST := CanvasItem.TEXTURE_FILTER_NEAREST

var _root: Node2D


func _initialize() -> void:
	var force := false
	for a in OS.get_cmdline_user_args():
		if a == "--force":
			force = true
	if FileAccess.file_exists(OUT) and not force:
		print("[build_world_scene] 已存在 ", OUT, "，跳过（要覆盖请加 --  --force）")
		quit(0)
		return

	var d = _load_json("res://assets/world.json")
	if d == null:
		quit(1)
		return

	var t0 := Time.get_ticks_msec()
	_root = Node2D.new()
	_root.name = "World"

	_build_ground(d)
	_build_objects(d)
	_build_props(d)
	_build_water(d)

	var ps := PackedScene.new()
	var err := ps.pack(_root)
	if err != OK:
		push_error("[build_world_scene] pack 失败: " + str(err))
		quit(1)
		return
	err = ResourceSaver.save(ps, OUT)
	if err != OK:
		push_error("[build_world_scene] 保存失败: " + str(err))
		quit(1)
		return

	print("[build_world_scene] 已生成 ", OUT, "  用时 ", Time.get_ticks_msec() - t0, "ms")
	_root.free()
	quit(0)


# ---------------------------------------------------------------- 工具
func _load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[build_world_scene] 找不到 " + path)
		return null
	var v = JSON.parse_string(f.get_as_text())
	if typeof(v) != TYPE_DICTIONARY:
		push_error("[build_world_scene] JSON 解析失败")
		return null
	return v


## add_child + 指定 owner（owner 必须是场景根，否则不会被写进 tscn）
func _attach(parent: Node, child: Node) -> void:
	parent.add_child(child)
	child.owner = _root


## 节点名不能含这些字符
func _safe(nm: String, fallback: String) -> String:
	var s := nm.strip_edges()
	if s == "":
		s = fallback
	for ch in [".", "/", ":", "@", "\"", "%", "*"]:
		s = s.replace(ch, "_")
	return s


# ---------------------------------------------------------------- 地面
func _build_ground(d) -> void:
	var g = d["ground"]
	var chunk: float = float(g.get("chunk", 1024))
	var holder := Node2D.new()
	holder.name = "Ground"
	_attach(_root, holder)
	for cy in int(g.get("rows", 0)):
		for cx in int(g.get("cols", 0)):
			var path := "res://assets/ground/g%d_%d.png" % [cx, cy]
			if not ResourceLoader.exists(path):
				continue
			var s := Sprite2D.new()
			s.name = "g%d_%d" % [cx, cy]
			s.texture = load(path)
			s.centered = false
			s.texture_filter = NEAREST
			s.position = Vector2(cx * chunk, cy * chunk)
			_attach(holder, s)

	# 海天苑大楼中央庭院（草地 + 步道）：放在 Ground 层，楼体的投影/墙面自然盖住边缘
	var lawn_path := "res://assets/haitian_courtyard.png"
	if ResourceLoader.exists(lawn_path):
		var lawn := Sprite2D.new()
		lawn.name = "haitian_courtyard"
		lawn.texture = load(lawn_path)
		lawn.centered = false
		lawn.texture_filter = NEAREST
		lawn.position = Vector2(199, 471) * CELL
		_attach(holder, lawn)


# ---------------------------------------------------------------- 建筑 + 装饰
func _build_objects(d) -> void:
	var objs := Node2D.new()
	objs.name = "Objects"
	objs.y_sort_enabled = true            # 建筑 / 树 / 玩家 统一按脚底 y 排序
	_attach(_root, objs)

	# ---- 建筑：StaticBody2D 本体放在「脚线」，碰撞多边形相对它换算 ----
	var arr = d["buildings"]
	for i in range(arr.size()):
		var b = arr[i]
		var path := "res://assets/buildings/b%d.png" % i
		if not ResourceLoader.exists(path):
			continue
		var base := Vector2(float(b.get("x", 0.0)), float(b.get("baseY", 0.0))) * CELL
		var body := StaticBody2D.new()
		body.name = _safe(str(b.get("name", "")), "building_%d" % i)
		body.position = base
		_attach(objs, body)

		var spr := Sprite2D.new()
		spr.name = "Sprite"
		spr.texture = load(path)
		spr.centered = false
		spr.texture_filter = NEAREST
		spr.offset = Vector2(0.0, -(float(b.get("baseY", 0.0)) - float(b.get("y", 0.0))) * CELL)
		_attach(body, spr)

		var poly = b.get("poly", [])
		if poly.size() >= 3:
			var cp := CollisionPolygon2D.new()
			cp.name = "Collision"
			var pts := PackedVector2Array()
			for p in poly:
				pts.append(Vector2(float(p[0]), float(p[1])) * CELL - base)
			cp.polygon = pts
			_attach(body, cp)

	# ---- 装饰：共用 11 张图集切片 ----
	var atlas_path := "res://assets/decor_0.png"
	if ResourceLoader.exists(atlas_path):
		var atlas_tex = load(atlas_path)
		var defs = d["decor"]
		var atlases: Array[AtlasTexture] = []
		for dd in defs:
			var at := AtlasTexture.new()
			at.atlas = atlas_tex
			at.region = Rect2(float(dd.get("rx", 0)), float(dd.get("ry", 0)),
					float(dd.get("w", 1)), float(dd.get("h", 1)))
			at.filter_clip = true
			atlases.append(at)

		var inst = d["instances"]
		# 建筑轮廓：落在楼内的树/装饰不生成（新补的海天苑大楼那块地原本有零星树）
		var bpolys: Array = []
		for b in d["buildings"]:
			var bp = b.get("poly", [])
			if bp.size() >= 3:
				var pv := PackedVector2Array()
				for p in bp:
					pv.append(Vector2(float(p[0]), float(p[1])))
				bpolys.append(pv)
		# 铺装类道具（球场、广场）上的树也不生成，否则从场地中间长出来
		for p in d.get("props", []):
			var pp = p.get("poly", [])
			if pp.size() >= 3:
				var pv3 := PackedVector2Array()
				for q in pp:
					pv3.append(Vector2(float(q[0]), float(q[1])))
				bpolys.append(pv3)
		var seq := 0
		for it in inst:
			var si := int(it.get("sp", -1))
			if si < 0 or si >= atlases.size():
				continue
			var ix := float(it.get("x", 0.0))
			var iy := float(it.get("y", 0.0))
			if _in_any(Vector2(ix, iy), bpolys):
				continue
			var dd = defs[si]
			var s := Sprite2D.new()
			seq += 1
			s.name = "%s_%04d" % [str(it.get("k", "decor")), seq]
			s.texture = atlases[si]
			s.centered = false
			s.texture_filter = NEAREST
			s.position = Vector2(ix, iy) * CELL
			s.offset = Vector2(-float(dd.get("ax", 0)) * CELL, -float(dd.get("ay", 0)) * CELL)
			_attach(objs, s)


# ---------------------------------------------------------------- 点-in-多边形
func _in_any(pt: Vector2, polys: Array) -> bool:
	for poly in polys:
		if _in_poly(pt, poly):
			return true
	return false


func _in_poly(pt: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var pi: Vector2 = poly[i]
		var pj: Vector2 = poly[j]
		if ((pi.y > pt.y) != (pj.y > pt.y)) and \
				(pt.x < (pj.x - pi.x) * (pt.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
	return inside


# ---------------------------------------------------------------- 小物件 / 广场
## props：通用精灵物件（校门、旗杆、长椅、路灯、喷泉、广场铺装……）
##   sprite  精灵路径
##   x/baseY 地面锚点（格）：精灵左边 / 底边
##   bottom  精灵底部留白像素（默认 0）
##   layer   "objects"（默认，参与 y 排序+碰撞）或 "ground"（铺在楼下面，无碰撞）
##   collide 可选，碰撞多边形数组（绝对格坐标）
func _build_props(d) -> void:
	var props = d.get("props", [])
	if props == null or props.is_empty():
		return
	var objs := _root.get_node_or_null("Objects")
	var ground := _root.get_node_or_null("Ground")
	for p in props:
		var sp := str(p.get("sprite", ""))
		if sp.is_empty() or not ResourceLoader.exists(sp):
			continue
		var tex: Texture2D = load(sp)
		if tex == null:
			continue
		var x := float(p.get("x", 0.0))
		var base_y := float(p.get("baseY", 0.0))
		var bottom := float(p.get("bottom", 0.0))
		var top := base_y * CELL - (tex.get_height() - bottom)
		if str(p.get("layer", "objects")) == "ground":
			if ground == null:
				continue
			var gs := Sprite2D.new()
			gs.name = _safe(str(p.get("name", "prop")), "prop")
			gs.texture = tex
			gs.centered = false
			gs.texture_filter = NEAREST
			gs.position = Vector2(x * CELL, top)
			_attach(ground, gs)
			continue
		if objs == null:
			continue
		var body := StaticBody2D.new()
		body.name = _safe(str(p.get("name", "prop")), "prop")
		body.add_to_group("props")
		body.position = Vector2(x * CELL, base_y * CELL)
		_attach(objs, body)
		var s := Sprite2D.new()
		s.name = "Sprite"
		s.texture = tex
		s.centered = false
		s.texture_filter = NEAREST
		s.offset = Vector2(0, -(tex.get_height() - bottom))
		_attach(body, s)
		for poly in p.get("collide", []):
			if poly.size() < 3:
				continue
			var cp := CollisionPolygon2D.new()
			cp.name = "Collision"
			var pts := PackedVector2Array()
			for pt in poly:
				pts.append(Vector2(float(pt[0]) - x, float(pt[1]) - base_y) * CELL)
			cp.polygon = pts
			_attach(body, cp)


# ---------------------------------------------------------------- 水域碰撞
func _build_water(d) -> void:
	var water = d.get("water", [])
	if water.is_empty():
		return
	var body := StaticBody2D.new()
	body.name = "Water"
	_attach(_root, body)
	for w in water:
		var rect := RectangleShape2D.new()
		rect.size = Vector2(float(w.get("w", 1)), float(w.get("h", 1))) * CELL
		var cs := CollisionShape2D.new()
		cs.name = "w"
		cs.shape = rect
		cs.position = Vector2(
			(float(w.get("x", 0)) + float(w.get("w", 1)) * 0.5) * CELL,
			(float(w.get("y", 0)) + float(w.get("h", 1)) * 0.5) * CELL)
		_attach(body, cs)
