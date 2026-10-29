extends Node2D
## 建筑内景（房间）—— 从宿舍/图书馆这类建筑进去后传送到的独立空间。
##
## 数据来自 assets/rooms/*.json，由 tools/import_skyoffice_room.py 生成
## （布局坐标取自 SkyOffice 的 Tiled 地图，美术全部程序化重画，不含第三方图集）。
##
## 结构与校园保持一致：本节点 scale=2，内部一律「8px/格」的局部坐标，
## 玩家 reparent 进 Objects（y_sort_enabled）后就能和家具逐个体比较深度，
## 走到桌子后面会被挡住，而不是永远浮在上面。

const RoomProp := preload("res://net/scripts/room_prop.gd")
const RoomGlow := preload("res://net/scripts/room_glow.gd")

const TS := 8.0
const ROOM_SCALE := 2.0
## 边界墙厚度（局部像素）。玩家撞到就停，防止走进地板外的虚空。
const EDGE_T := 24.0

## 本节点在父空间里的缩放。独立跑（调试）时是 2.0；挂进 campus/Objects
## （那里已经是 8px/格 的局部空间）时要设 1.0，否则整个房间会被放大一倍。
var node_scale := ROOM_SCALE

var data: Dictionary = {}
var objects: Node2D          ## 家具与玩家的共同容器（y 排序）
var glow: Node2D             ## 发光层（additive，画在家具之上）
var solids: StaticBody2D     ## 家具/边界的碰撞
var spawn_px := Vector2.ZERO
var size_px := Vector2.ZERO
## 小地图底图（4px/格），右上角那块面板直接用它
var minimap_tex: Texture2D


## 读一份房间数据并搭好场景。失败返回 false，调用方决定怎么兜底。
func load_room(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[room] 打不开房间数据：%s" % path)
		return false
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[room] 房间数据不是 JSON 对象：%s" % path)
		return false
	data = parsed
	_build()
	return true


## 玩家应该挂到哪个节点下
func anchor() -> Node2D:
	return objects


func title() -> String:
	return String(data.get("name", "房间"))


# ---------------------------------------------------------------- 搭建

func _build() -> void:
	name = String(data.get("id", "room"))
	scale = Vector2(node_scale, node_scale)
	size_px = Vector2(float(data["W"]) * TS, float(data["H"]) * TS)

	var floor_spr := Sprite2D.new()
	floor_spr.name = "Floor"
	floor_spr.centered = false
	floor_spr.texture = ImageTexture.create_from_image(_bake_floor())
	floor_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	floor_spr.z_index = -100
	add_child(floor_spr)

	objects = Node2D.new()
	objects.name = "Objects"
	objects.y_sort_enabled = true
	add_child(objects)

	solids = StaticBody2D.new()
	solids.name = "Solids"
	add_child(solids)

	for w in data.get("walls", []):
		var wd: Dictionary = w
		_add_prop("wall", wd)
		_add_solid(wd)

	for item in data.get("props", []):
		var p: Dictionary = item
		_add_prop(String(p.get("k", "table")), p)
		if bool(p.get("solid", false)):
			_add_solid(p)

	for item in data.get("seats", []):
		_add_prop("chair", item)

	minimap_tex = _bake_minimap()
	_setup_glow()
	_add_bounds()

	var sp: Dictionary = data.get("spawn", {})
	spawn_px = Vector2(float(sp.get("x", 0.0)), float(sp.get("y", 0.0))) * TS


func _add_prop(kind: String, r: Dictionary) -> void:
	if objects == null:
		return
	var n := RoomProp.new()
	n.name = "%s_%d" % [kind, objects.get_child_count()]
	objects.add_child(n)
	n.call("setup", kind, Rect2(float(r["x"]), float(r["y"]), float(r["w"]), float(r["h"])))


## 一个左上角 + 尺寸的矩形碰撞
func _rect_body(pos: Vector2, size: Vector2) -> void:
	if size.x < 0.5 or size.y < 0.5:
		return
	var shape := RectangleShape2D.new()
	shape.size = size
	var cs := CollisionShape2D.new()
	cs.shape = shape
	cs.position = pos + size * 0.5
	solids.add_child(cs)


func _add_solid(r: Dictionary) -> void:
	_rect_body(
		Vector2(float(r["x"]), float(r["y"])) * TS,
		Vector2(float(r["w"]), float(r["h"])) * TS
	)


## 四面封边。房间外是虚空，不封人就走没了。
func _add_bounds() -> void:
	_rect_body(Vector2(-EDGE_T, -EDGE_T), Vector2(size_px.x + EDGE_T * 2.0, EDGE_T))
	_rect_body(Vector2(-EDGE_T, size_px.y), Vector2(size_px.x + EDGE_T * 2.0, EDGE_T))
	_rect_body(Vector2(-EDGE_T, 0.0), Vector2(EDGE_T, size_px.y))
	_rect_body(Vector2(size_px.x, 0.0), Vector2(EDGE_T, size_px.y))


## 屏幕 / 贩卖机 / 白板各给一点光，暗室里才有「有设备在运行」的感觉
func _setup_glow() -> void:
	glow = RoomGlow.new()
	glow.name = "Glow"
	glow.z_index = 80
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = mat
	add_child(glow)

	var spots: Array = []
	for item in data.get("props", []):
		var p: Dictionary = item
		var kind := String(p.get("k", ""))
		var cx := (float(p["x"]) + float(p["w"]) * 0.5) * TS
		match kind:
			"desk":
				# 屏幕中心：桌面靠后那一带
				spots.append({
					"pos": Vector2(cx, float(p["y"]) * TS + 5.0),
					"r": 54.0,
					"color": Color(0.48, 0.86, 1.0, 0.95),
				})
			"vending":
				spots.append({
					"pos": Vector2(cx, (float(p["y"]) + float(p["h"]) * 0.35) * TS),
					"r": 34.0,
					"color": Color(0.82, 0.55, 1.0, 0.34),
				})
			"board":
				spots.append({
					"pos": Vector2(cx, (float(p["y"]) + float(p["h"]) * 0.3) * TS),
					"r": 30.0,
					"color": Color(0.86, 0.93, 1.0, 0.18),
				})
	glow.call("setup", spots)


# ---------------------------------------------------------------- 地板

## 整块地砖烘成一张图。房间是静态的，一次画好之后每帧只是一个 Sprite2D，
## 比逐格 _draw 省得多（校园地图也是这个路子）。
##
## 地板是整个房间里面积最大的东西，纹理尺度定得好不好直接决定观感：
## 8px 一格的小方砖在缩远看时就是一地噪点，所以这里用 16×48 的长条木板，
## 对比度压得很低（亮暗只差几个色阶），靠拼缝而不是靠色差来形成纹理。
func _bake_floor() -> Image:
	var w := int(round(size_px.x))
	var h := int(round(size_px.y))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color("1e1812"))

	# ── 木板：12px 高 × 96px 长，横向铺、错缝 ──
	# 每块板自己微调明度（±1 个色阶），而不是靠两种色块交替 ——
	# 后者在大面积上会形成「砖墙」，前者才是木地板。
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261029
	var base := Color("2a221a")
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var d := rng.randf_range(-0.014, 0.014)
			var c := base.lightened(d) if d > 0.0 else base.darkened(-d)
			img.fill_rect(Rect2i(x, y, 96, 12), c)
			x += 96
		y += 12

	# ── 拼缝：横缝带一道高光，竖缝按行错开半块 ──
	y = 0
	var row := 0
	while y < h:
		img.fill_rect(Rect2i(0, y, w, 1), Color(0, 0, 0, 0.24))
		img.fill_rect(Rect2i(0, y + 1, w, 1), Color(1, 1, 1, 0.028))
		var vx := 48 if row % 2 == 1 else 0
		while vx < w:
			img.fill_rect(Rect2i(vx, y, 1, 12), Color(0, 0, 0, 0.22))
			vx += 96
		y += 12
		row += 1

	# ── 工位区地毯：把五个机位圈成一块区域，房间才不会显得空 ──
	var desk_box := Rect2()
	for item in data.get("props", []):
		var p: Dictionary = item
		if String(p.get("k", "")) != "desk":
			continue
		var r := Rect2(float(p["x"]), float(p["y"]), float(p["w"]), float(p["h"]))
		desk_box = r if desk_box.size == Vector2.ZERO else desk_box.merge(r)
	if desk_box.size != Vector2.ZERO:
		var pad := 6.0          # 留够空间把椅子也圈进来
		_paint_rug(img, Rect2(
			(desk_box.position.x - pad) * TS,
			(desk_box.position.y - pad) * TS,
			(desk_box.size.x + pad * 2.0) * TS,
			(desk_box.size.y + pad * 2.0) * TS
		))

	# ── 边缘压暗：让地板嵌在暗处，而不是一块浮空的板 ──
	var edge := 26
	for i in range(edge):
		var t := 1.0 - float(i) / float(edge)
		var a := 0.62 * t * t
		img.fill_rect(Rect2i(0, i, w, 1), Color(0, 0, 0, a))
		img.fill_rect(Rect2i(0, h - 1 - i, w, 1), Color(0, 0, 0, a))
		img.fill_rect(Rect2i(i, 0, 1, h), Color(0, 0, 0, a))
		img.fill_rect(Rect2i(w - 1 - i, 0, 1, h), Color(0, 0, 0, a))

	# ── 出入口地垫 ──
	var e: Dictionary = data.get("exit", {})
	if not e.is_empty():
		var ex := int(float(e["x"]) * TS)
		var ey := int(float(e["y"]) * TS)
		var ew := int(float(e["w"]) * TS)
		var eh := int(float(e["h"]) * TS)
		img.fill_rect(Rect2i(ex, ey, ew, eh), Color("262c34"))
		img.fill_rect(Rect2i(ex, ey, ew, 3), Color("5f574c"))
		img.fill_rect(Rect2i(ex, ey + eh - 3, ew, 3), Color("5f574c"))
		img.fill_rect(Rect2i(ex, ey, 3, eh), Color("5f574c"))
		img.fill_rect(Rect2i(ex + ew - 3, ey, 3, eh), Color("5f574c"))
		# 垫子里的斜纹
		for i in range(1, 6):
			var ly := ey + int(float(eh) * float(i) / 6.0)
			img.fill_rect(Rect2i(ex + 3, ly, ew - 6, 1), Color(1, 1, 1, 0.05))

	return img


## 小地图：4px/格，比地板图（8px/格）低一半分辨率，跟校园小地图同规格。
## 不直接缩地板图 —— 家具是独立节点、不在图里，缩出来只有一块空地。
## 这里按类型重新铺一遍色块，读图的人一眼能认出机位区、会议区和白板。
func _bake_minimap() -> Texture2D:
	var px := 4.0
	var w := int(round(size_px.x / TS * px))
	var h := int(round(size_px.y / TS * px))
	if w < 8 or h < 8:
		return null
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	# 小地图是「示意图」不是「截图」：底色抬到中等亮度，家具用饱和色块，
	# 200px 宽的面板上一眼能分出机位区 / 会议区 / 白板。照搬地板的深棕只会糊成一团黑。
	img.fill(Color("463e34"))

	var k := px                # 格 → 小地图像素（data 里全是格坐标，直接乘 4）
	var COL := {
		"wall": Color("74839b"),
		"table": Color("9a7a52"),
		"desk": Color("5d93cc"),
		"board": Color("eef4fa"),
		"vending": Color("a463b4"),
		"block": Color("866c4a"),
		"deco": Color("5e7a58"),
		"pit": Color("232830"),
	}

	# 工位区地毯先铺一层，跟大地图对得上
	var desk_box := Rect2()
	for item in data.get("props", []):
		var p: Dictionary = item
		if String(p.get("k", "")) != "desk":
			continue
		var r := Rect2(float(p["x"]), float(p["y"]), float(p["w"]), float(p["h"]))
		desk_box = r if desk_box.size == Vector2.ZERO else desk_box.merge(r)
	if desk_box.size != Vector2.ZERO:
		_fill_cells(img, desk_box.grow(6.0), k, Color("34414f"))

	for item in data.get("walls", []):
		var p: Dictionary = item
		_fill_cells(img, Rect2(float(p["x"]), float(p["y"]), float(p["w"]), float(p["h"])), k, COL["wall"])
	for item in data.get("props", []):
		var p: Dictionary = item
		var kind := String(p.get("k", ""))
		var rect := Rect2(float(p["x"]), float(p["y"]), float(p["w"]), float(p["h"]))
		_fill_cells(img, rect, k, COL.get(kind, Color("888888")))
		if kind == "desk":
			# 屏幕画个亮点，小地图上也看得出哪几个机位
				_fill_cells(img, Rect2(rect.position.x + rect.size.x * 0.26, rect.position.y + 0.8,
				rect.size.x * 0.48, 1.6), k, Color("b8f0ff"))
	for item in data.get("seats", []):
		var s: Dictionary = item
		_fill_cells(img, Rect2(float(s["x"]) + 0.6, float(s["y"]) + 3.0, 2.1, 2.6), k, Color("cf9a5c"))

	# 出入口
	var e: Dictionary = data.get("exit", {})
	if not e.is_empty():
		_fill_cells(img, Rect2(float(e["x"]), float(e["y"]), float(e["w"]), float(e["h"])), k, Color("9fb3c6"))

	return ImageTexture.create_from_image(img)


func _fill_cells(img: Image, r: Rect2, k: float, col: Color) -> void:
	var x0 := int(floor(r.position.x * k))
	var y0 := int(floor(r.position.y * k))
	var x1 := int(ceil(r.end.x * k))
	var y1 := int(ceil(r.end.y * k))
	x0 = maxi(0, x0)
	y0 = maxi(0, y0)
	x1 = mini(img.get_width(), x1)
	y1 = mini(img.get_height(), y1)
	if x1 <= x0 or y1 <= y0:
		return
	img.fill_rect(Rect2i(x0, y0, x1 - x0, y1 - y0), col)


## 一块地毯：深色底 + 一圈包边 + 细织纹
func _paint_rug(img: Image, r: Rect2) -> void:
	var x0 := maxi(0, int(r.position.x))
	var y0 := maxi(0, int(r.position.y))
	var x1 := mini(img.get_width(), int(r.end.x))
	var y1 := mini(img.get_height(), int(r.end.y))
	if x1 - x0 < 8 or y1 - y0 < 8:
		return
	img.fill_rect(Rect2i(x0, y0, x1 - x0, y1 - y0), Color("1d242c"))
	img.fill_rect(Rect2i(x0, y0, x1 - x0, 3), Color("2b343f"))
	img.fill_rect(Rect2i(x0, y1 - 3, x1 - x0, 3), Color("2b343f"))
	img.fill_rect(Rect2i(x0, y0, 3, y1 - y0), Color("2b343f"))
	img.fill_rect(Rect2i(x1 - 3, y0, 3, y1 - y0), Color("2b343f"))
	var yy := y0 + 7
	while yy < y1 - 6:
		img.fill_rect(Rect2i(x0 + 6, yy, x1 - x0 - 12, 1), Color(1, 1, 1, 0.018))
		yy += 5
