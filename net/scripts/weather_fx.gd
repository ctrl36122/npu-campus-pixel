extends Node2D
## 雨 / 雪粒子（屏幕空间，跟天气强度走）。
##
## 用 Node2D 而不是 Control：Control 的绘制会被自身 rect 限制，粒子铺满全屏时
## 边缘容易被裁，而且还得跟着窗口尺寸改 size。Node2D 挂在 CanvasLayer 下，
## 坐标就是屏幕像素，画多少都不裁。
##
## 像素风的做法：雨是 1px 宽的短斜线，雪是 2×2 的白点 —— 不用贴图、不抗锯齿，
## 一屏两百来根线，比 GPUParticles 省事且不会有半像素糊边。
##
## 粒子始终按上限存在并一直运动，只按当前强度决定「画前几个」，
## 所以天气从雨转晴时雨丝是一根根减少，不是整片突然消失。
##
## 房间内不该下雨（人在屋里），由 Arena 在进出房时把这一层藏起来。

const MAX_DROPS := 420
const MAX_FLAKES := 300
const WIND_X := -190.0          ## 雨的横向漂移（px/s），负值往西斜

var _dx := PackedFloat32Array()
var _dy := PackedFloat32Array()
var _dv := PackedFloat32Array()
var _dl := PackedFloat32Array()
var _dp := PackedFloat32Array()

var _fx := PackedFloat32Array()
var _fy := PackedFloat32Array()
var _fv := PackedFloat32Array()
var _fp := PackedFloat32Array()

var _rng := RandomNumberGenerator.new()
var _need_repaint := true


func _ready() -> void:
	_rng.seed = 20261115
	z_index = 0
	_build()


func _build() -> void:
	var s := _area()
	_dx.resize(MAX_DROPS)
	_dy.resize(MAX_DROPS)
	_dv.resize(MAX_DROPS)
	_dl.resize(MAX_DROPS)
	_dp.resize(MAX_DROPS)
	for i in MAX_DROPS:
		_seed_drop(i, s, true)
	_fx.resize(MAX_FLAKES)
	_fy.resize(MAX_FLAKES)
	_fv.resize(MAX_FLAKES)
	_fp.resize(MAX_FLAKES)
	for i in MAX_FLAKES:
		_seed_flake(i, s, true)


func _area() -> Vector2:
	var s := get_viewport_rect().size
	if s.x < 8.0 or s.y < 8.0:
		s = Vector2(1280.0, 720.0)
	return s


func _seed_drop(i: int, s: Vector2, anywhere: bool) -> void:
	_dx[i] = _rng.randf_range(-20.0, s.x + 40.0)
	_dy[i] = _rng.randf_range(0.0, s.y) if anywhere else _rng.randf_range(-120.0, -8.0)
	_dv[i] = _rng.randf_range(880.0, 1380.0)
	_dl[i] = _rng.randf_range(26.0, 56.0)
	_dp[i] = _rng.randf_range(0.60, 1.0)


func _seed_flake(i: int, s: Vector2, anywhere: bool) -> void:
	_fx[i] = _rng.randf_range(-20.0, s.x + 40.0)
	_fy[i] = _rng.randf_range(0.0, s.y) if anywhere else _rng.randf_range(-60.0, -6.0)
	_fv[i] = _rng.randf_range(26.0, 62.0)
	_fp[i] = _rng.randf_range(0.0, TAU)


func _process(delta: float) -> void:
	var s := _area()
	var rain := Weather.rain_strength()
	var snow := Weather.snow_strength()
	var n_drop := int(round(rain * MAX_DROPS))
	var n_flake := int(round(snow * MAX_FLAKES))
	if n_drop == 0 and n_flake == 0:
		if _need_repaint:
			_need_repaint = false
			queue_redraw()
		return
	_need_repaint = true

	# 雨：竖直下落 + 横向风。风随强度稍增，小雨时更直
	var wind := WIND_X * (0.55 + 0.45 * rain)
	for i in n_drop:
		_dy[i] += _dv[i] * delta
		_dx[i] += wind * delta
		if _dy[i] - _dl[i] > s.y or _dx[i] < -30.0:
			_seed_drop(i, s, false)
			_dx[i] = _rng.randf_range(s.x * 0.4, s.x + 30.0) if wind < 0.0 \
				else _rng.randf_range(-20.0, s.x + 20.0)

	# 雪：慢，左右摆
	for i in n_flake:
		_fy[i] += _fv[i] * delta
		_fp[i] += delta * 1.7
		_fx[i] += sin(_fp[i]) * 22.0 * delta + wind * 0.18 * delta
		if _fy[i] > s.y + 4.0 or _fx[i] < -20.0:
			_seed_flake(i, s, false)

	queue_redraw()


func _draw() -> void:
	var s := _area()
	var rain := Weather.rain_strength()
	var snow := Weather.snow_strength()
	var n_drop := int(round(rain * MAX_DROPS))
	var n_flake := int(round(snow * MAX_FLAKES))
	if n_drop == 0 and n_flake == 0:
		return
	# 雨丝：一根 1px 斜线，越往下越实（尾端淡、头端亮），落下来才有速度感
	var wind := WIND_X * (0.55 + 0.45 * rain)
	var k_rain := 0.62 + 0.38 * rain
	for i in n_drop:
		var ln := _dl[i]
		var x := roundf(_dx[i])
		var y := roundf(_dy[i])
		# 倾斜量 = 横向风速 × 这根雨丝下落需要的时间。用每滴自己的速度算，
		# 快了就直、慢了就斜 —— 之前写死一个系数，算出来的横移是实际值的十倍，
		# 雨丝被拉成接近水平的淡线，在缩略图上根本看不出来。
		var dx := -wind * ln / maxf(1.0, _dv[i])
		var ax := roundf(x + dx)
		var ay := roundf(y - ln)
		draw_line(Vector2(ax, ay), Vector2(x, y),
			Color(0.88, 0.94, 1.0, 0.62 * _dp[i] * k_rain), 2.0)
		# 头端 45% 再描一遍，等于给雨滴加了个亮尖
		draw_line(Vector2(roundf(x + dx * 0.45), roundf(y - ln * 0.45)),
			Vector2(x, y), Color(0.98, 1.0, 1.0, 0.95 * _dp[i] * k_rain), 2.0)
	# 雪：3×3 白点 + 一圈更淡的光晕，落在亮处也看得见
	for i in n_flake:
		var x2 := roundf(_fx[i])
		var y2 := roundf(_fy[i])
		draw_rect(Rect2(x2 - 2.0, y2 - 2.0, 6.0, 6.0),
			Color(1.0, 1.0, 1.0, 0.16 * _dp[i]))
		draw_rect(Rect2(x2, y2, 3.0, 3.0), Color(1.0, 1.0, 1.0, 0.94 * _dp[i]))
