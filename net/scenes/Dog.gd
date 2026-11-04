extends Node2D
## 一只像素狗：随机漫步 + 蹲坐。走路时腿交替、尾巴慢摇。origin = 脚底中点。
## 由 Wildlife（ground 模式）生成，挂进 Objects 参与 y 排序（走到楼后会被挡住）。

const WALK_SPEED := 16.0      # 局部像素/秒
const HOME_RADIUS := 95.0     # 别离家太远

var home := Vector2.ZERO
var pos := Vector2.ZERO
var target := Vector2.ZERO
var wait := 1.0
var face := 1.0
var color := Color("6b4a2b")

var _rng := RandomNumberGenerator.new()
var _t := 0.0


func setup(anchor: Vector2, col: Color, seed_val: int) -> void:
	home = anchor
	pos = anchor + Vector2(_rng.randf_range(-40.0, 40.0), _rng.randf_range(-24.0, 24.0))
	# 注意：先 seed 再 randf，否则上面的 anchor 偏移每次都一样
	_rng.seed = seed_val
	pos = anchor + Vector2(_rng.randf_range(-40.0, 40.0), _rng.randf_range(-24.0, 24.0))
	color = col
	wait = _rng.randf_range(0.5, 3.0)
	position = pos


func _process(delta: float) -> void:
	_t += delta
	if wait > 0.0:
		wait -= delta
		if wait <= 0.0:
			var t := pos + Vector2(_rng.randf_range(-60.0, 60.0), _rng.randf_range(-40.0, 40.0))
			if t.distance_to(home) > HOME_RADIUS:
				t = home + (t - home).limit_length(70.0)
			target = t
	else:
		var to := target - pos
		if to.length() < 2.0:
			wait = _rng.randf_range(1.5, 5.0)
		else:
			var step := to.normalized() * WALK_SPEED * delta
			pos += step
			if absf(step.x) > 0.01:
				face = 1.0 if step.x > 0.0 else -1.0
	position = pos
	queue_redraw()


func _draw() -> void:
	var f := face
	var walking := wait <= 0.0
	var dark := color.darkened(0.35)
	var sway := sin(_t * 4.0 + pos.x * 0.1)
	# 尾巴（身体后侧，慢悠悠地摇）
	draw_rect(Rect2(Vector2(-7.0 * f - 1.0, -7.0 + sway * 1.5), Vector2(2, 2)), color)
	# 四条腿（走路时前后交替）
	for i in 2:
		var lx := -4.0 + float(i) * 7.0
		var lift := maxf(0.0, sin(_t * 10.0 + float(i) * PI)) if walking else 0.0
		draw_rect(Rect2(Vector2(lx * f, -2.0 - lift), Vector2(2, 2.0)), dark)
	# 身体
	draw_rect(Rect2(Vector2(-5.0, -8.0), Vector2(10, 6)), color)
	# 头（朝前）
	draw_rect(Rect2(Vector2(f * 3.5 - 3.0, -13.0), Vector2(6, 6)), color)
	# 垂耳
	draw_rect(Rect2(Vector2(f * 3.5 - 3.0, -13.0), Vector2(1.6, 4.0)), dark)
	draw_rect(Rect2(Vector2(f * 3.5 + 1.4, -13.0), Vector2(1.6, 4.0)), dark)
	# 鼻子 + 眼
	draw_rect(Rect2(Vector2(f * 8.4 - 1.0, -10.5), Vector2(1.6, 1.6)), Color(0.12, 0.1, 0.1))
	draw_rect(Rect2(Vector2(f * 5.0 - 0.5, -11.5), Vector2(1, 1)), Color(0.12, 0.1, 0.1))
