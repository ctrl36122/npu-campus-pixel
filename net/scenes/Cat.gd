extends Node2D
## 一只像素猫：随机漫步 + 蹲坐。走路时腿交替、尾巴慢摆。origin = 脚底中点。
## 由 Wildlife（ground 模式）生成，挂进 Objects 参与 y 排序（走到楼后会被挡住）。

const WALK_SPEED := 14.0      # 局部像素/秒（campus scale=2 后翻倍显示）
const HOME_RADIUS := 90.0     # 别离家太远

var home := Vector2.ZERO
var pos := Vector2.ZERO
var target := Vector2.ZERO
var wait := 1.0
var face := 1.0
var color := Color("d9822b")

var _rng := RandomNumberGenerator.new()
var _t := 0.0


func setup(anchor: Vector2, col: Color, seed_val: int) -> void:
	home = anchor
	pos = anchor + Vector2(randf_range(-40.0, 40.0), randf_range(-24.0, 24.0))
	color = col
	_rng.seed = seed_val
	wait = _rng.randf_range(0.5, 3.0)
	position = pos


func _process(delta: float) -> void:
	_t += delta
	if wait > 0.0:
		wait -= delta                             # 原地蹲坐（舔爪/看鸟）
		if wait <= 0.0:
			var t := pos + Vector2(_rng.randf_range(-55.0, 55.0), _rng.randf_range(-35.0, 35.0))
			if t.distance_to(home) > HOME_RADIUS:
				t = home + (t - home).limit_length(60.0)
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
	# 尾巴（身体后侧，慢悠悠地摆）
	var sway := sin(_t * 2.6 + pos.x * 0.1)
	draw_rect(Rect2(Vector2(-5.0 * f - 1.0, -6.0 + sway), Vector2(2, 1.5)), color)
	# 四条腿（走路时前后交替）
	for i in 2:
		var lx := -3.0 + float(i) * 5.0
		var lift := maxf(0.0, sin(_t * 11.0 + float(i) * PI)) if walking else 0.0
		draw_rect(Rect2(Vector2(lx * f, -2.0 - lift), Vector2(1.5, 2.0)), dark)
	# 身体 + 头
	draw_rect(Rect2(Vector2(-4.0, -6.0), Vector2(8, 4.5)), color)
	draw_rect(Rect2(Vector2(f * 2.5 - 2.5, -10.5), Vector2(5, 5)), color)
	# 耳朵
	draw_rect(Rect2(Vector2(f * 2.5 - 2.5, -12.0), Vector2(1.2, 2.0)), color)
	draw_rect(Rect2(Vector2(f * 2.5 + 1.3, -12.0), Vector2(1.2, 2.0)), color)
	# 眼睛
	draw_rect(Rect2(Vector2(f * 3.6 - 0.5, -9.0), Vector2(1, 1)), Color(0.12, 0.1, 0.1))
