extends Node2D
## 校园小动物 v2（全部程序绘制，零素材）。
##  mode="ground"：小猫 —— 每只是独立的 Cat.gd 节点，参与 y 排序（会被楼挡住）
##  mode="air"   ：飞鸟 —— 掠过校园上空（两帧扇翅 + 地面影子），蝴蝶在锚点附近飘舞
## 坐标是校园局部像素（campus scale=2 后翻倍显示）。

const CatScript := preload("res://net/scenes/Cat.gd")

@export var mode: String = "ground"

const BUTTERFLY_COLORS := [
	Color("e8b34b"), Color("d97fa8"), Color("8fd0ff"),
]
const CAT_COLORS := [
	Color("d9822b"),   # 橘猫
	Color("9a9a9a"),   # 灰猫
	Color("e8e3da"),   # 白猫
	Color("4a3826"),   # 深棕
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
func setup(anchors: Array) -> void:
	_rng.seed = 424242 if mode == "ground" else 909090
	_anchors = anchors.duplicate()
	if _anchors.is_empty():
		set_process(false)
		return
	if mode == "ground":
		y_sort_enabled = true
		for i in 6:
			var cat := Node2D.new()
			cat.set_script(CatScript)
			add_child(cat)
			cat.call("setup", _anchors[i % _anchors.size()],
				CAT_COLORS[i % CAT_COLORS.size()], 1000 + i * 77)
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
