extends Node2D
## 一只像素鸭：在湖边/水面上游荡，扁嘴、蹼脚、偶尔梳理羽毛。origin = 脚底（水面）中点。
## 由 Wildlife 用「水缘锚点」生成，挂在 Objects 下（贴水面，y 排序让它被岸边的楼挡住）。

const WALK_SPEED := 11.0      # 局部像素/秒（水里划得慢）
const HOME_RADIUS := 120.0    # 别漂太远，基本在自家湖里

var home := Vector2.ZERO
var pos := Vector2.ZERO
var target := Vector2.ZERO
var wait := 1.0
var face := 1.0
var color := Color("f2f0e8")  # 白鸭

var _rng := RandomNumberGenerator.new()
var _t := 0.0


func setup(anchor: Vector2, col: Color, seed_val: int) -> void:
	_rng.seed = seed_val
	home = anchor
	pos = anchor + Vector2(_rng.randf_range(-30.0, 30.0), _rng.randf_range(-15.0, 15.0))
	color = col
	wait = _rng.randf_range(1.0, 4.0)
	position = pos


func _process(delta: float) -> void:
	_t += delta
	if wait > 0.0:
		wait -= delta
		if wait <= 0.0:
			var t := pos + Vector2(_rng.randf_range(-70.0, 70.0), _rng.randf_range(-40.0, 40.0))
			if t.distance_to(home) > HOME_RADIUS:
				t = home + (t - home).limit_length(90.0)
			target = t
	else:
		var to := target - pos
		if to.length() < 2.0:
			wait = _rng.randf_range(2.0, 6.0)
		else:
			var step := to.normalized() * WALK_SPEED * delta
			pos += step
			if absf(step.x) > 0.01:
				face = 1.0 if step.x > 0.0 else -1.0
	position = pos
	queue_redraw()


func _draw() -> void:
	var f := face
	var dark := color.darkened(0.25)
	var bob := sin(_t * 3.0 + pos.x * 0.05) * 0.8
	# 水面倒影/阴影（半透明，贴脚下）
	draw_ellipse_shape(Rect2(Vector2(-5.0, 1.5), Vector2(10.0, 3.0)), Color(0.1, 0.2, 0.3, 0.18))
	# 身体
	draw_ellipse_shape(Rect2(Vector2(-5.0, -7.0 + bob), Vector2(10.0, 6.0)), color)
	# 翅膀（侧边一抹暗色，随游动微动）
	draw_ellipse_shape(Rect2(Vector2(-2.0 * f - 3.0, -6.0 + bob), Vector2(6.0, 4.0)), dark)
	# 头
	draw_circle(Vector2(f * 5.0, -9.0 + bob), 3.0, color)
	# 扁嘴（黄）
	draw_rect(Rect2(Vector2(f * 7.0 - (1.5 if f > 0 else 0.0), -9.5 + bob), Vector2(3.0 * f, 1.8)), Color(0.95, 0.7, 0.15))
	# 眼
	draw_rect(Rect2(Vector2(f * 5.6 - 0.5, -10.0 + bob), Vector2(1, 1)), Color(0.12, 0.1, 0.1))
	# 小尾（身后翘起）
	draw_rect(Rect2(Vector2(-5.5 * f, -6.0 + bob), Vector2(2.0, 2.0)), dark)


func draw_ellipse_shape(rect: Rect2, col: Color) -> void:
	# CanvasItem 4.7 已自带 draw_ellipse（签名不同），这里用别的名避免冲突
	var cx := rect.get_center().x
	var cy := rect.get_center().y
	var rx := rect.size.x * 0.5
	var ry := rect.size.y * 0.5
	var pts: PackedVector2Array = []
	for i in 16:
		var a := TAU * float(i) / 16.0
		pts.append(Vector2(cx + cos(a) * rx, cy + sin(a) * ry))
	draw_polygon(pts, [col])
