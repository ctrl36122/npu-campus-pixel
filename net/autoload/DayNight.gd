extends Node
## 昼夜系统（全局单例）。
##
## 时间以「真实系统时间」为准：现实白天=游戏白天，现实黑夜=游戏黑夜（北京时间）。
##   t ∈ [0,1)：0.00 = 午夜 00:00，0.25 = 日出 06:00，0.50 = 正午 12:00，0.75 = 日落 18:00。
##
## 本单例只算「数值」，不做任何渲染——渲染由 Arena（夜幕叠加 + 建筑夜灯）
## 和 online_boot（顶部时钟 HUD）各自读取这些数值完成。

const MAX_DARK := 0.68             # 午夜时夜幕叠加的最大不透明度

var t: float = 0.30


func _ready() -> void:
	_sync_now()


func _process(_delta: float) -> void:
	_sync_now()


## 从系统时钟取当前时刻（北京时间），换算成一天中的比例
func _sync_now() -> void:
	# 调试用：XGD_HOUR=22.5 可把游戏内时刻钉在任意点（白天也能核对夜景），env-gated、正常玩无效
	if OS.has_environment("XGD_HOUR"):
		t = clampf(float(OS.get_environment("XGD_HOUR")) / 24.0, 0.0, 1.0)
		return
	var now := Time.get_time_dict_from_system()
	t = (float(now.hour) + float(now.minute) / 60.0 + float(now.second) / 3600.0) / 24.0


## 太阳高度角（近似正弦）：0.25 日出=0，0.5 正午=+1，0.75 日落=0，午夜=-1
func _sun() -> float:
	return sin((t - 0.25) * TAU)


## 日照强度 0..1（含暮光过渡）：正午=1，深夜=0。
## 在太阳高度 -0.18（刚入夜）到 +0.20（全亮）之间平滑过渡，留一道暮光带。
func daylight() -> float:
	var s := _sun()
	return clampf((s + 0.18) / 0.38, 0.0, 1.0)


## 昼夜阶段名（顶部时钟用）
func phase_name() -> String:
	var d := daylight()
	if d > 0.85:
		return "白天"
	if d > 0.4:
		return "清晨" if t < 0.5 else "黄昏"
	if d > 0.1:
		return "清晨" if t < 0.5 else "黄昏"
	return "夜晚"


## 夜幕叠加层的不透明度：白天 0，午夜 MAX_DARK
func overlay_alpha() -> float:
	return (1.0 - daylight()) * MAX_DARK


## 夜幕叠加层的颜色（深夜偏冷的蓝黑）
func overlay_color() -> Color:
	return Color(0.03, 0.05, 0.12)


## 窗户夜灯强度 0..1：傍晚开始亮起，深夜最亮。
## 用 (0.4 - 日照)/0.4，所以日照降到 0.4（约下午/清晨偏暗、入夜）时灯就渐亮。
func glow_strength() -> float:
	var d := daylight()
	return clampf((0.4 - d) / 0.4, 0.0, 1.0)


## 当前游戏内时钟，格式 HH:MM
func time_string() -> String:
	var total := t * 24.0
	var hh := int(floor(total)) % 24
	var mm := int(floor((total - floor(total)) * 60.0))
	return "%02d:%02d" % [hh, mm]
