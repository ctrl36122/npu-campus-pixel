extends Node2D
## 校园小动物。
##  mode="ground"：小猫 —— 每只是独立的 Cat.gd 节点，直接播 Oreo Cat 原图帧
##                （见 references/.../Oreo Cat - Aichan_owo/）；参与 y 排序
##  mode="air"   ：飞鸟 —— 掠过校园上空（两帧扇翅 + 地面影子），蝴蝶在锚点附近飘舞
## 鸟/蝴蝶/影子仍是程序绘制。
## 坐标是校园局部像素（campus scale=2 后翻倍显示）。

const CatScript := preload("res://net/scenes/Cat.gd")
const DogScript := preload("res://net/scenes/Dog.gd")
const DuckScript := preload("res://net/scenes/Duck.gd")
const BunnyScript := preload("res://net/scenes/Bunny.gd")

const TS := 8.0   # 格→像素（锚点转换用，与 Arena 里一致）

@export var mode: String = "ground"

const BUTTERFLY_COLORS := [
	Color("e8b34b"), Color("d97fa8"), Color("8fd0ff"),
]
## 猫的花色表在 Cat.gd 的 SKINS 里（同一张原图，运行时 shader 换色，一只一个不重样）
const DOG_COLORS := [
	Color("6b4a2b"),   # 棕
	Color("3a3a3a"),   # 黑
	Color("caa472"),   # 黄
	Color("e8e3da"),   # 白
]
const BUNNY_COLORS := [
	Color("e8e3da"),   # 白
	Color("9a9a9a"),   # 灰
	Color("c98a5a"),   # 棕
]
const DUCK_COLORS := [
	Color("f2f0e8"),   # 白鸭
	Color("d9b44a"),   # 麻鸭
	Color("8a8f55"),   # 绿头鸭（暗羽）
]

var _rng := RandomNumberGenerator.new()
var _anchors: Array = []     # 活动锚点（校园局部像素）
var _t: float = 0.0
var _birds: Array = []       # {pos, vel, phase, col}
var _flies: Array = []       # {anchor, phase, col}
var _bird_cd: float = 1.5
var _bounds := Rect2(0, 0, 3392, 6400)   # 校园局部像素范围（424×800 格 ×8）
var _player: Node2D = null               # 本地玩家（让鸟贴着玩家视野飞）


## anchors: NPC 出生点等「确定可走」的位置 ×8
## water_rects: world.json 的 water 数组（格坐标），给鸭子当活动锚点
func setup(anchors: Array, water_rects: Array = []) -> void:
	_rng.seed = 424242 if mode == "ground" else 909090
	_anchors = anchors.duplicate()
	if _anchors.is_empty() and mode == "ground" and water_rects.is_empty():
		set_process(false)
		return
	if mode == "ground":
		y_sort_enabled = true
		var idx := 0
		var seed := 1000
		# 猫：SKINS 里一条一只（花色/体型/性格都不同，见 Cat.gd 的 SKINS）
		_spawn_cats()
		idx += CatScript.SKINS.size(); seed += 77
		# 狗 4 只
		for i in 4:
			_spawn_animal(DogScript, _anchors, DOG_COLORS, idx, seed)
			idx += 1; seed += 91
		# 兔 4 只
		for i in 4:
			_spawn_animal(BunnyScript, _anchors, BUNNY_COLORS, idx, seed)
			idx += 1; seed += 53
		# 鸭子：沿水缘撒（最多 8 只，避免湖里挤爆）
		var duck_anchors := _water_edge_anchors(water_rects)
		for i in duck_anchors.size():
			var dk := Node2D.new()
			dk.set_script(DuckScript)
			add_child(dk)
			dk.call("setup", duck_anchors[i], DUCK_COLORS[i % DUCK_COLORS.size()], 7000 + i * 131)
	else:
		z_index = 15
		for i in 6:
			_flies.append({
				"anchor": _anchors[i % _anchors.size()]
					+ Vector2(_rng.randf_range(-55, 55), _rng.randf_range(-30, 30)),
				"phase": _rng.randf_range(0.0, TAU),
				"col": BUTTERFLY_COLORS[i % BUTTERFLY_COLORS.size()],
			})
		for i in 2:
			_spawn_bird()


# ---------------------------------------------------------------- 鸟（天空）

# ---------------------------------------------------------------- 地面动物生成

func _spawn_animal(script: Script, anchors: Array, colors: Array, idx: int, seed: int) -> void:
	var a := Node2D.new()
	a.set_script(script)
	add_child(a)
	a.call("setup", anchors[idx % anchors.size()], colors[idx % colors.size()], seed)


## 猫：花色表里一条一只，绕着活动锚点撒开（同一锚点的两只按 180° 错开，别叠一起）
func _spawn_cats() -> void:
	var skins: Array = CatScript.SKINS
	if _anchors.is_empty():
		return
	# 第三方素材可能没随仓库分发，缺了就跳过猫，别让整个场景报错
	if not ResourceLoader.exists("res://assets/cats/oreo_cat_sheet.png"):
		push_warning("[Wildlife] 缺 assets/cats/oreo_cat_sheet.png，跳过猫咪")
		return
	for i in skins.size():
		var cat := Node2D.new()
		cat.set_script(CatScript)
		cat.name = "Cat%d" % i
		add_child(cat)
		var base: Vector2 = _anchors[i % _anchors.size()]
		var ang := TAU * float(i) / float(skins.size())
		var spot := base + Vector2(cos(ang), sin(ang) * 0.55) * 46.0
		cat.call("setup", spot, skins[i], 2000 + i * 137)


## 从 water 矩形（格坐标）取四边贴边点作为鸭子活动锚点（×TS 转像素），最多 8 只
func _water_edge_anchors(water_rects: Array) -> Array:
	var out: Array = []
	for r in water_rects:
		var x0 := float(r.get("x", 0.0))
		var y0 := float(r.get("y", 0.0))
		var w := float(r.get("w", 0.0))
		var h := float(r.get("h", 0.0))
		if w < 2.0 or h < 2.0:
			continue
		out.append(Vector2((x0 + w * 0.25) * TS, (y0 + 1.0) * TS))
		out.append(Vector2((x0 + w * 0.75) * TS, (y0 + 1.0) * TS))
		out.append(Vector2((x0 + 1.0) * TS, (y0 + h * 0.5) * TS))
		out.append(Vector2((x0 + w - 1.0) * TS, (y0 + h * 0.5) * TS))
	out.shuffle()
	if out.size() > 8:
		out = out.slice(0, 8)
	return out


func _spawn_bird() -> void:
	# 优先在本地玩家附近屏幕外生成，这样鸟总是从玩家眼前掠过
	var px := _bounds.size.x * 0.5
	var py := _bounds.size.y * 0.5
	if _player != null and is_instance_valid(_player):
		px = _player.position.x
		py = _player.position.y
	var from_left := _rng.randf() < 0.5
	var side := 1.0 if from_left else -1.0
	_birds.append({
		"pos": Vector2(px + side * _rng.randf_range(330.0, 430.0),
			py + _rng.randf_range(-150.0, 150.0)),
		"vel": Vector2(55.0 * _rng.randf_range(0.8, 1.3) * -side, _rng.randf_range(-8.0, 8.0)),
		"phase": _rng.randf_range(0.0, TAU),
		"col": Color(0.25, 0.27, 0.3) if _rng.randf() < 0.7 else Color(0.92, 0.92, 0.9),
	})


func _tick_birds(delta: float) -> void:
	_bird_cd -= delta
	if _bird_cd <= 0.0 and _birds.size() < 5:
		_bird_cd = _rng.randf_range(3.0, 9.0)
		_spawn_bird()
	for i in range(_birds.size() - 1, -1, -1):
		var b: Dictionary = _birds[i]
		b["pos"] = (b["pos"] as Vector2) + (b["vel"] as Vector2) * delta
		var p := b["pos"] as Vector2
		if p.x < -60.0 or p.x > _bounds.size.x + 60.0:
			_birds.remove_at(i)


# ---------------------------------------------------------------- 公共

func _process(delta: float) -> void:
	_t += delta
	if mode == "air":
		if _player == null:
			_player = get_tree().get_first_node_in_group("players")
		_tick_birds(delta)
		queue_redraw()


## air 模式：鸟 + 蝴蝶都画在本节点（z_index=15，永远在人/楼上面）
func _draw() -> void:
	if mode != "air":
		return
	for b in _birds:
		var p: Vector2 = b["pos"]
		var col: Color = b["col"]
		var flap := sin(_t * 9.0 + float(b["phase"]))     # -1..1
		var wy := -2.5 * flap
		# 翅膀两笔（V 字开合），身体一个小方块
		draw_line(p + Vector2(-4.0, wy * 0.7), p, col, 1.2)
		draw_line(p, p + Vector2(4.0, wy * 0.7), col, 1.2)
		draw_rect(Rect2(p + Vector2(-1.0, -1.5), Vector2(2, 2.5)), col)
		# 地面影子：跟随鸟的 x
		draw_rect(Rect2(Vector2(p.x - 1.5, p.y + 24.0 + flap * 1.5), Vector2(3.5, 1.2)), Color(0, 0, 0, 0.10))
	for fl in _flies:
		var anchor: Vector2 = fl["anchor"]
		var ph: float = fl["phase"]
		var p := anchor + Vector2(sin(_t * 0.7 + ph) * 18.0, sin(_t * 1.35 + ph * 2.0) * 10.0)
		var sx := absf(sin(_t * 13.0 + ph))                # 翅膀开合
		var col: Color = fl["col"]
		draw_rect(Rect2(p + Vector2(-1.8 * sx - 0.4, -2.2), Vector2(1.8 * sx + 0.4, 2.8)), col)
		draw_rect(Rect2(p + Vector2(0.4, -2.2), Vector2(1.8 * sx + 0.4, 2.8)), col)
		draw_rect(Rect2(p + Vector2(-0.4, -2.6), Vector2(0.8, 3.4)), Color(0.2, 0.18, 0.16))
