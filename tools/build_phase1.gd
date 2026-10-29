extends SceneTree
## Phase 1 沙盒生成器
## 用法：godot --headless --path . --script res://tools/build_phase1.gd
##
## 产物：
##   assets/sandbox/ground_tileset.tres   16px 地形 TileSet（24 格）
##   assets/sandbox/player_frames.tres    down/up/left/right × idle+walk，各 6 帧
##   scenes/sandbox/phase1.tscn           广场 + 一栋楼 + 玩家 + 边界墙
##
## 角色素材：SkyOffice（client/public/assets/character/adam.png）
##   布局 52 帧 × 32×48，单行：idle(right/up/left/down)=0/6/12/18，
##                             run(right/up/left/down)=24/30/36/42

const TS := 16                      # 单格像素（16px 格 + 32×48 角色 = RPG 标准比例）
const MAP_W := 60
const MAP_H := 40

const HeroDB := preload("res://scripts/sandbox/hero_db.gd")

# 地形图块序号（8 列）→ Vector2i(列, 行)
const T_PLAZA := Vector2i(6, 0)
const T_SIDEWALK := Vector2i(3, 1)
const T_ROAD := Vector2i(0, 1)
const T_LINE := Vector2i(2, 1)
const T_CONCRETE := Vector2i(5, 1)
const T_WATER := Vector2i(0, 2)
const T_SHORE := Vector2i(3, 2)

var _root: Node2D


func _initialize() -> void:
	var tile_set := _build_tileset()
	_build_player_frames()
	var d = _load_json("res://assets/world.json")
	var bld := _pick_building(d) if d != null else {}
	_build_scene(tile_set, bld)
	if _root != null:
		_root.free()
	print("[phase1] 完成 scenes/sandbox/phase1.tscn  地形 ", MAP_W, "×", MAP_H, " 格 / ", TS, "px")
	quit(0)


# ---------------------------------------------------------------- TileSet
func _build_tileset() -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TS, TS)
	var src := TileSetAtlasSource.new()
	src.texture = load("res://assets/sandbox/tileset16.png")
	src.texture_region_size = Vector2i(TS, TS)
	for row in 3:
		for col in 8:
			src.create_tile(Vector2i(col, row))
	ts.add_source(src, 0)
	ResourceSaver.save(ts, "res://assets/sandbox/ground_tileset.tres")
	return load("res://assets/sandbox/ground_tileset.tres")


# ---------------------------------------------------------------- 角色帧
func _build_player_frames() -> void:
	## 为每个可选角色生成一份 SpriteFrames：<方向>_idle / <方向>_walk 各 6 帧
	for hero in HeroDB.HEROES:
		var sheet = load(hero["sheet"])
		if sheet == null:
			push_error("[phase1] 角色图集缺失: " + str(hero["sheet"]))
			continue
		var frames := SpriteFrames.new()
		frames.remove_animation(&"default")
		for dir in HeroDB.DIRS:
			_add_anim(frames, sheet, "%s_idle" % dir, int(HeroDB.IDLE_START[dir]), 7.0)
			_add_anim(frames, sheet, "%s_walk" % dir, int(HeroDB.WALK_START[dir]), 10.0)
		ResourceSaver.save(frames, hero["frames"])
		print("[phase1] frames_%s.tres 生成" % hero["id"])


func _add_anim(frames: SpriteFrames, sheet, anim_name: String, start: int, fps: float) -> void:
	var nm := StringName(anim_name)
	frames.add_animation(nm)
	frames.set_animation_speed(nm, fps)
	frames.set_animation_loop(nm, true)
	for i in HeroDB.FRAMES_PER_ANIM:
		var at := AtlasTexture.new()
		at.atlas = sheet
		at.region = Rect2((start + i) * HeroDB.FRAME_W, 0, HeroDB.FRAME_W, HeroDB.FRAME_H)
		frames.add_frame(nm, at)


# ---------------------------------------------------------------- 挑一栋小楼
func _pick_building(d) -> Dictionary:
	if d == null:
		return {}
	var best := {}
	var best_area := 1e20
	for i in range(d["buildings"].size()):
		var b = d["buildings"][i]
		var rw := float(b.get("rw", 0))
		var rh := float(b.get("rh", 0))
		if rw < 80.0 or rh < 120.0 or rw > 280.0:
			continue
		if rw * rh < best_area:
			best_area = rw * rh
			best = {"idx": i, "name": str(b.get("name", "楼")), "rw": rw, "rh": rh,
					"x": float(b.get("x", 0)), "y": float(b.get("y", 0)),
					"baseY": float(b.get("baseY", 0)), "cx": float(b.get("cx", 0)),
					"poly": b.get("poly", [])}
	return best


# ---------------------------------------------------------------- 场景
func _build_scene(tile_set: TileSet, bld: Dictionary) -> void:
	_root = Node2D.new()
	_root.name = "Phase1"

	var ground := TileMapLayer.new()
	ground.name = "Ground"
	ground.tile_set = tile_set
	_attach(_root, ground)
	_paint(ground)

	var walls := StaticBody2D.new()
	walls.name = "Walls"
	walls.collision_layer = 1
	walls.collision_mask = 0
	_attach(_root, walls)

	var world_px := Vector2(MAP_W * TS, MAP_H * TS)
	_add_rect_shape(walls, "BorderN", Vector2(world_px.x * 0.5, -TS * 0.5), Vector2(world_px.x, TS))
	_add_rect_shape(walls, "BorderS", Vector2(world_px.x * 0.5, world_px.y + TS * 0.5), Vector2(world_px.x, TS))
	_add_rect_shape(walls, "BorderW", Vector2(-TS * 0.5, world_px.y * 0.5), Vector2(TS, world_px.y))
	_add_rect_shape(walls, "BorderE", Vector2(world_px.x + TS * 0.5, world_px.y * 0.5), Vector2(TS, world_px.y))

	# ---- 建筑（脚线中心放在格 (31, 26)）----
	if not bld.is_empty():
		var feet := Vector2(31 * TS, 26 * TS)
		var body := StaticBody2D.new()
		body.name = "Building"
		body.position = feet
		body.collision_layer = 1
		body.collision_mask = 0
		_attach(walls, body)

		var spr := Sprite2D.new()
		spr.name = "Sprite"
		spr.texture = load("res://assets/buildings/b%d.png" % int(bld["idx"]))
		spr.centered = false
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		# 建筑贴图是按 8px/格 烘的，16px 世界里整体放大 2 倍才和角色/地形同比例
		const BSCALE := 2.0
		spr.scale = Vector2(BSCALE, BSCALE)
		spr.position = Vector2(-float(bld["rw"]) * BSCALE * 0.5,
				-(float(bld["baseY"]) - float(bld["y"])) * 8.0 * BSCALE)
		_attach(body, spr)

		var poly: Array = bld["poly"]
		if poly.size() >= 3:
			var cp := CollisionPolygon2D.new()
			cp.name = "Collision"
			var pts := PackedVector2Array()
			for p in poly:
				pts.append((Vector2(float(p[0]), float(p[1])) - Vector2(float(bld["cx"]), float(bld["baseY"]))) * 8.0 * BSCALE)
			cp.polygon = pts
			_attach(body, cp)

	# ---- 玩家 ----
	var pscn = load("res://scenes/sandbox/player_anim.tscn")
	var player = pscn.instantiate()
	player.name = "Player"
	player.position = Vector2(31 * TS, 32 * TS)
	player.level_bounds = Rect2(0, 0, world_px.x, world_px.y)
	_attach(_root, player)

	# ---- HUD ----
	var hud := CanvasLayer.new()
	hud.name = "HUD"
	hud.set_script(load("res://scripts/sandbox/hud.gd"))
	hud.set("tile_size", TS)
	_attach(_root, hud)

	# ---- 角色创建（模态弹窗，启动时显示，确认后消失）----
	var sel := CanvasLayer.new()
	sel.name = "CharCreate"
	sel.set_script(load("res://scripts/sandbox/char_create.gd"))
	_attach(_root, sel)

	var ps := PackedScene.new()
	var err := ps.pack(_root)
	if err != OK:
		push_error("[phase1] pack 失败 " + str(err))
		return
	ResourceSaver.save(ps, "res://scenes/sandbox/phase1.tscn")


func _add_rect_shape(parent: Node, nm: String, center: Vector2, size_px: Vector2) -> void:
	var cs := CollisionShape2D.new()
	cs.name = nm
	var rect := RectangleShape2D.new()
	rect.size = size_px
	cs.shape = rect
	cs.position = center
	_attach(parent, cs)


# ---------------------------------------------------------------- 画地形
func _paint(layer: TileMapLayer) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261026
	for y in MAP_H:
		for x in MAP_W:
			layer.set_cell(Vector2i(x, y), 0, Vector2i(rng.randi_range(0, 3), 0))

	_rect(layer, 16, 10, 30, 20, T_PLAZA)
	_ring(layer, 16, 10, 30, 20, T_SIDEWALK)
	_rect(layer, 22, 24, 18, 4, T_CONCRETE)

	_rect(layer, 0, 44, MAP_W, 3, T_ROAD)
	for x in MAP_W:
		if x % 3 != 0:
			layer.set_cell(Vector2i(x, 45), 0, T_LINE)

	# 小水塘
	var cx := 9
	var cy := 7
	var r := 5
	for y in range(cy - r - 1, cy + r + 2):
		for x in range(cx - r - 1, cx + r + 2):
			if x < 0 or y < 0 or x >= MAP_W or y >= MAP_H:
				continue
			var dd := Vector2(x - cx, y - cy).length()
			if dd <= r - 1.0:
				layer.set_cell(Vector2i(x, y), 0, T_WATER)
			elif dd <= r + 0.6:
				layer.set_cell(Vector2i(x, y), 0, T_SHORE)


func _rect(layer: TileMapLayer, x0: int, y0: int, w: int, h: int, atlas: Vector2i) -> void:
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if x >= 0 and y >= 0 and x < MAP_W and y < MAP_H:
				layer.set_cell(Vector2i(x, y), 0, atlas)


func _ring(layer: TileMapLayer, x0: int, y0: int, w: int, h: int, atlas: Vector2i) -> void:
	for x in range(x0, x0 + w):
		for y in [y0, y0 + h - 1]:
			if x >= 0 and y >= 0 and x < MAP_W and y < MAP_H:
				layer.set_cell(Vector2i(x, y), 0, atlas)
	for y in range(y0, y0 + h):
		for x in [x0, x0 + w - 1]:
			if x >= 0 and y >= 0 and x < MAP_W and y < MAP_H:
				layer.set_cell(Vector2i(x, y), 0, atlas)


# ---------------------------------------------------------------- 工具
func _attach(parent: Node, child: Node) -> void:
	parent.add_child(child)
	child.owner = _root


func _load_json(path: String) -> Variant:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var v = JSON.parse_string(f.get_as_text())
	return v if typeof(v) == TYPE_DICTIONARY else null
