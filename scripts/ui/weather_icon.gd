extends Control
## 顶部天气条的小图标：12×12 逻辑像素，纯 draw_rect 拼出来的像素画。
##
## 不用 emoji / 贴图 —— 项目里所有图标都是画出来的，这样字体会变但图标不糊。
## 晴天按当前是白天还是夜里换太阳 / 月亮。

var kind: int = 0          ## Weather.Kind
var night: bool = false

const SUN := Color("ffd166")
const SUN_EDGE := Color("f0a93c")
const MOON := Color("e8e2c8")
const CLOUD := Color("c9d3dd")
const CLOUD_HI := Color("e2e9f0")
const RAIN := Color("9fc0d8")
const SNOW := Color("e6eefa")
const BOLT := Color("ffd166")

const GRID := 12.0


func _ready() -> void:
	custom_minimum_size = Vector2(12.0, 12.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_state(k: int, is_night: bool) -> void:
	if k == kind and is_night == night:
		return
	kind = k
	night = is_night
	queue_redraw()


## 画一个逻辑像素块（按控件实际尺寸等比缩放，触屏放大也清）
func _px(x: float, y: float, w: float, h: float, c: Color) -> void:
	var u := minf(size.x, size.y) / GRID
	draw_rect(Rect2(x * u, y * u, w * u, h * u), c)


func _draw() -> void:
	match kind:
		0:  # CLEAR
			if night:
				_moon()
			else:
				_sun()
		1:  # CLOUDY
			_cloud()
		2:  # RAIN
			_cloud()
			_rain()
		3:  # SNOW
			_cloud()
			_snow()


func _sun() -> void:
	_px(4, 4, 4, 4, SUN)
	_px(3, 5, 1, 2, SUN)
	_px(8, 5, 1, 2, SUN)
	_px(5, 3, 2, 1, SUN)
	_px(5, 8, 2, 1, SUN)
	# 四根射线
	_px(5, 1, 2, 1, SUN_EDGE)
	_px(5, 10, 2, 1, SUN_EDGE)
	_px(1, 5, 1, 2, SUN_EDGE)
	_px(10, 5, 1, 2, SUN_EDGE)
	# 斜角点
	_px(2, 2, 1, 1, SUN_EDGE)
	_px(9, 2, 1, 1, SUN_EDGE)
	_px(2, 9, 1, 1, SUN_EDGE)
	_px(9, 9, 1, 1, SUN_EDGE)


func _moon() -> void:
	# 朝右开口的月牙：逐行画，右边自然缺一块（透明笔刷挖不出形状，只能少画）
	_px(5, 2, 3, 1, MOON)
	_px(4, 3, 2, 1, MOON)
	_px(3, 4, 2, 1, MOON)
	_px(2, 5, 2, 2, MOON)
	_px(3, 7, 2, 1, MOON)
	_px(4, 8, 2, 1, MOON)
	_px(5, 9, 3, 1, MOON)


func _cloud() -> void:
	_px(2, 6, 8, 3, CLOUD)
	_px(4, 4, 4, 2, CLOUD_HI)
	_px(3, 5, 1, 1, CLOUD_HI)
	_px(2, 8, 8, 1, CLOUD.darkened(0.18))


func _rain() -> void:
	_px(4, 9, 1, 2, RAIN)
	_px(3, 10, 1, 1, RAIN)
	_px(7, 9, 1, 2, RAIN)
	_px(6, 10, 1, 1, RAIN)


func _snow() -> void:
	_px(4, 9, 2, 2, SNOW)
	_px(7, 10, 1, 1, SNOW)
	_px(9, 9, 1, 1, SNOW)
