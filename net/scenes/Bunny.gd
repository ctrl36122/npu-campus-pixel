extends Node2D
## 一只像素兔/松鼠：草地上蹦跳着溜达，长耳朵、短尾。origin = 脚底中点。
## 由 Wildlife（ground 模式）生成，挂进 Objects 参与 y 排序。

const HOP_SPEED := 22.0     # 蹦跳移动速度（比猫快、一蹦一蹦）
const HOME_RADIUS := 80.0

var home := Vector2.ZERO
var pos := Vector2.ZERO
var target := Vector2.ZERO
var wait := 1.0
var face := 1.0
var color := Color("e8e3da")  # 白兔

var _rng := RandomNumberGenerator.new()
var _t := 0.0
var _hop := 0.0               # 当前竖直弹跳量（绘制时抬高身体）


func setup(anchor: Vector2, col: Color, seed_val: int) -> void:
	_rng.seed = seed_val
	home = anchor
	pos = anchor + Vector2(_rng.randf_range(-35.0, 35.0), _rng.randf_range(-20.0, 20.0))
	color = col
	wait = _rng.randf_range(0.6, 2.5)
	position = pos


func _process(delta: float) -> void:
	_t += delta
	if wait > 0.0:
		wait -= delta
		_hop = 0.0
		if wait <= 0.0:
			var t := pos + Vector2(_rng.randf_range(-50.0, 50.0), _rng.randf_range(-30.0, 30.0))
			if t.distance_to(home) > HOME_RADIUS:
				t = home + (t - home).limit_length(65.0)
			target = t
	else:
		var to := target - pos
		if to.length() < 2.0:
			wait = _rng.randf_range(1.2, 4.0)
			_hop = 0.0
		else:
			var step := to.normalized() * HOP_SPEED * delta
			pos += step
			if absf(step.x) > 0.01:
				face = 1.0 if step.x > 0.0 else -1.0
			# 蹦跳：连续小抛物线，频率随移动
			_hop = absf(sin(_t * 12.0)) * 3.5
	position = pos
	queue_redraw()


func _draw() -> void:
	var f := face
	var dark := color.darkened(0.3)
	var h := _hop
	# 影子（落地时明显，跳起时缩小）
	draw_rect(Rect2(Vector2(-3.0, 0.5), Vector2(6.0, 1.4)), Color(0, 0, 0, 0.12 - h * 0.02))
	# 身体（略圆）
	draw_circle(Vector2(0.0, -5.0 - h), 4.0, color)
	# 头
	draw_circle(Vector2(f * 2.5, -9.0 - h), 2.8, color)
	# 长耳
	draw_rect(Rect2(Vector2(f * 2.0 - 1.0, -14.0 - h), Vector2(1.4, 5.0)), color)
	draw_rect(Rect2(Vector2(f * 3.4 - 1.0, -14.0 - h), Vector2(1.4, 5.0)), color)
	# 眼
	draw_rect(Rect2(Vector2(f * 3.3 - 0.5, -9.5 - h), Vector2(1, 1)), Color(0.12, 0.1, 0.1))
	# 后腿（蹦跳时蹬）
	var leg := 1.5 + h * 0.3
	draw_rect(Rect2(Vector2(-3.0, -2.0 - h + leg), Vector2(2.0, 2.5 - leg)), dark)
	draw_rect(Rect2(Vector2(1.0, -2.0 - h + leg), Vector2(2.0, 2.5 - leg)), dark)
	# 短尾（身后白点）
	draw_circle(Vector2(-4.0 * f, -4.0 - h), 1.4, Color(1, 1, 1, 0.9))
