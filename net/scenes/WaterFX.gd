extends Node2D
## 水面动效：在烘焙好的静态水面贴图上叠加「波光粼粼」。
## 波光点按固定种子撒在大块水域内，各自按相位正弦闪烁、横向缓慢漂移。
## 全程序生成，零素材；挂在 campus 下、Objects 之前（水上、人物楼底下）。

const CELL := 8.0            # world.json 的格边长（校园局部像素）
const MIN_AREA := 4.0        # 细河条也给波光（≥4 格）
const MAX_SPARKS := 380      # 波光点总量上限

var _sparkles: Array = []    # {x, y, phase, speed, len}
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()
## 晴天色：按 water_mask 铺满整张地面的加法层，晴天让湖水更蓝更清。
## 阴雨天强度归零 —— 那时候水本来就该浑一点，加蓝反而假。
var _sun_tint: Sprite2D
var _sun_mat: ShaderMaterial
var _sun_now: float = -1.0


## water: world.json 里的 water 数组（格坐标 {x,y,w,h}）
func setup(water: Array) -> void:
	_build_sun_tint()
	_rng.seed = 20261028
	for r in water:
		if _sparkles.size() >= MAX_SPARKS:
			break
		var rw := float(r.get("w", 0))
		var rh := float(r.get("h", 0))
		if rw * rh < MIN_AREA:
			continue
		var n := clampi(int(rw * rh / 70.0), 1, 4)
		for i in n:
			_sparkles.append({
				"x": (float(r.get("x", 0)) + _rng.randf_range(0.12, 0.88) * rw) * CELL,
				"y": (float(r.get("y", 0)) + _rng.randf_range(0.12, 0.88) * rh) * CELL,
				"phase": _rng.randf_range(0.0, TAU),
				"speed": _rng.randf_range(1.1, 2.3),
				"len": _rng.randf_range(2.0, 5.0),
			})


## 水体染色的底图：water_mask.png 一格一像素，放大 8 倍正好盖住整张地面
func _build_sun_tint() -> void:
	if _sun_tint != null:
		return
	var tex: Texture2D = null
	if ResourceLoader.exists("res://assets/water_mask.png"):
		tex = load("res://assets/water_mask.png") as Texture2D
	if tex == null:
		return
	var sh := load("res://net/shaders/water_sun.gdshader") as Shader
	if sh == null:
		return
	_sun_mat = ShaderMaterial.new()
	_sun_mat.shader = sh
	_sun_mat.set_shader_parameter("strength", 0.0)
	_sun_tint = Sprite2D.new()
	_sun_tint.name = "SunTint"
	_sun_tint.texture = tex
	_sun_tint.centered = false
	_sun_tint.scale = Vector2(CELL, CELL)
	_sun_tint.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sun_tint.material = _sun_mat
	add_child(_sun_tint)


## 晴天的染色强度：晴 ~0.9，阴 ~0.12，雨雪 0。
## 只在变化超过 0.01 时才写 shader 参数，避免每帧推一个常量。
func _sync_sun() -> void:
	if _sun_mat == null:
		return
	var k := 0.0
	match Weather.kind:
		Weather.Kind.CLEAR:
			k = 0.74
		Weather.Kind.CLOUDY:
			k = 0.12
		_:
			k = 0.0
	# 天气过渡期间按 cloud 再收一道，晴天权重低的时候水也不该突然变蓝
	k *= clampf(1.0 - Weather.cloud() * 0.85, 0.0, 1.0) * 1.35
	k = clampf(k, 0.0, 1.0)
	if absf(k - _sun_now) < 0.01:
		return
	_sun_now = k
	_sun_mat.set_shader_parameter("strength", k)


func _process(delta: float) -> void:
	_t += delta
	_sync_sun()
	queue_redraw()


func _draw() -> void:
	for s in _sparkles:
		var a := 0.5 + 0.5 * sin(_t * float(s["speed"]) + float(s["phase"]))
		a *= a                                   # 大部分时间比较淡，偶尔亮一下
		if a < 0.05:
			continue
		var dx := sin(_t * 0.55 + float(s["phase"])) * 1.6
		var col := Color(1.0, 1.0, 1.0, 0.18 + 0.42 * a)
		var ln: float = float(s["len"]) * 1.6
		draw_rect(Rect2(float(s["x"]) + dx, float(s["y"]), ln, 1.2), col)
		# 波光下方拖一条更淡的短尾，让涟漪感更强
		draw_rect(Rect2(float(s["x"]) + dx - 2.0, float(s["y"]), ln * 0.5, 1.0),
			Color(1.0, 1.0, 1.0, 0.06 + 0.14 * a))
