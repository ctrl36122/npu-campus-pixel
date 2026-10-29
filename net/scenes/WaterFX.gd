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


## water: world.json 里的 water 数组（格坐标 {x,y,w,h}）
func setup(water: Array) -> void:
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


func _process(delta: float) -> void:
	_t += delta
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
