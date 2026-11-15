extends Node
## 天气系统（全局单例）：拿现实西安的实时天气，驱动画面与 HUD。
##
## 数据源用 wttr.in（免 key、免注册、国内直连约 2~3 秒；Open-Meteo 在国内网络
## 基本连不上，实测 15 秒超时）。返回的是 WWO 天气码 + 温度 + 云量 + 降水。
##
## 三层退化，保证任何情况下都有天气可画：
##   1. 网络成功        → live = true，写缓存
##   2. 网络失败但有缓存 → 用缓存（2 小时内的，过期的也先用着再重试）
##   3. 全都没有        → 按西安气候 + 日期生成一个稳定的模拟天气（live = false）
##
## 天气切换不是硬切：from → to 用 TRANSITION 秒插值，画的参数都是插值结果，
## 所以「小雨转阴」在屏幕上是一段平滑的变化，不会闪一下。
##
## 渲染由谁做：Arena（全屏调色 + 雨雪粒子）、RoomSky（云的浓淡快慢）、
## online_boot（顶部天气条）。本单例只算数值。

enum Kind { CLEAR, CLOUDY, RAIN, SNOW }

const CITY := "西安"
const CITY_EN := "Xian"
const API_URL := "https://wttr.in/Xian?format=j1"
const REFRESH_SEC := 600.0            ## 定时刷新：10 分钟（wttr.in 观测本身约半小时一更）
const RETRY_SEC := 45.0               ## 失败后多久重试
const HTTP_TIMEOUT := 10.0
const CACHE_PATH := "user://weather_cache.json"
const CACHE_TRUST_SEC := 7200.0       ## 缓存 2 小时内可直接当实时用
const TRANSITION := 6.0               ## 天气过渡时长（秒）

## 每种天气的渲染参数。渲染层拿到的是「插值后的结果」，不关心当前是哪种。
##   exposure  亮度乘数（>1 更亮）
##   sat       饱和度
##   contrast  对比（围绕 0.5 中灰）
##   warm      RGB 暖偏移（-0.05 ~ +0.05，加了会让画面偏暖/偏冷）
##   tint      叠色，a 为混合强度
##   cloud     0..1 云量（天空与整体灰度的软参考）
##   rain/snow 降水强度 0..1（粒子数量与速度）
##   sun       阳光权重 0..1（屏幕光晕 + 湖水染蓝都看它）
const PARAMS := {
	Kind.CLEAR: {
		"exposure": 1.038, "sat": 1.075, "contrast": 1.030,
		"warm": Vector3(0.028, 0.015, -0.008),
		"tint": Color(1.0, 0.970, 0.905, 0.050),
		"cloud": 0.20, "rain": 0.0, "snow": 0.0, "sun": 1.0,
	},
	Kind.CLOUDY: {
		"exposure": 0.978, "sat": 0.935, "contrast": 0.988,
		"warm": Vector3(-0.002, 0.000, 0.005),
		"tint": Color(0.82, 0.86, 0.90, 0.090),
		"cloud": 0.80, "rain": 0.0, "snow": 0.0, "sun": 0.10,
	},
	Kind.RAIN: {
		"exposure": 0.930, "sat": 0.800, "contrast": 0.948,
		"warm": Vector3(-0.012, -0.004, 0.009),
		"tint": Color(0.64, 0.71, 0.80, 0.145),
		"cloud": 1.0, "rain": 0.85, "snow": 0.0, "sun": 0.0,
	},
	Kind.SNOW: {
		"exposure": 0.995, "sat": 0.700, "contrast": 1.008,
		"warm": Vector3(-0.010, 0.000, 0.014),
		"tint": Color(0.86, 0.90, 0.96, 0.150),
		"cloud": 1.0, "rain": 0.0, "snow": 0.92, "sun": 0.04,
	},
}

## WWO 天气码 → 游戏四态。码表取自 wttr.in 的 weatherCode 字段。
const WWO_SNOW := [179, 182, 185, 227, 230, 323, 326, 329, 332, 335, 338, 368, 371,
	392, 395]
const WWO_RAIN := [176, 263, 266, 281, 284, 293, 296, 299, 302, 305, 308, 311, 314,
	317, 320, 353, 356, 359, 362, 365, 374, 377, 386, 389]
const WWO_CLEAR := [113]

## WWO 天气码 → 中文短语（HUD 上显示）
const WWO_TEXT := {
	113: "晴", 116: "多云", 119: "多云", 122: "阴", 143: "薄雾", 248: "雾", 260: "冻雾",
	176: "零星小雨", 263: "毛毛雨", 266: "毛毛雨", 281: "冻毛毛雨", 284: "冻毛毛雨",
	293: "小雨", 296: "小雨", 299: "中雨", 302: "中雨", 305: "大雨", 308: "暴雨",
	311: "冻雨", 314: "冻雨", 317: "雨夹雪", 320: "雨夹雪",
	353: "阵雨", 356: "阵雨", 359: "暴雨", 362: "阵雨夹雪", 365: "阵雨夹雪",
	374: "冰粒", 377: "冰粒", 386: "雷阵雨", 389: "雷阵雨",
	179: "阵雪", 182: "阵雪", 185: "冻毛毛雨", 227: "吹雪", 230: "暴风雪",
	323: "小雪", 326: "小雪", 329: "中雪", 332: "中雪", 335: "大雪", 338: "大雪",
	368: "阵雪", 371: "阵雪", 392: "雷雪", 395: "雷雪",
}

## 当前态 / 过渡起点 / 过渡进度
var kind: int = Kind.CLEAR
var _from_kind: int = Kind.CLEAR
var _from_params: Dictionary = PARAMS[Kind.CLEAR]
var _to_params: Dictionary = PARAMS[Kind.CLEAR]
var _blend: float = 1.0

## 实时数值
var temp_c: int = 0
var desc: String = ""            ## 中文短语，如「小雨」
var humidity: int = 0
var precip_mm: float = 0.0
var cloud_cover: float = 0.3     ## 0..1
var live: bool = false           ## 是否来自真实观测（false = 缓存过期/模拟）
var updated_label: String = ""   ## 「11:40」或「离线模拟」
var _manual: int = -1            ## >=0 时锁定该天气（调试/手动），-1 跟随现实

var _http: HTTPRequest
var _wait: float = REFRESH_SEC      ## 距离下次拉取的秒数
var _busy: bool = false
var _forced: bool = false        ## XGD_WEATHER 指定了天气（截图验收用）
var _refreshed: bool = false     ## 至少成功拉过一次


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if OS.has_environment("XGD_WEATHER"):
		_forced = _apply_env_weather(OS.get_environment("XGD_WEATHER"))
	if _forced:
		return
	# 先用缓存（或模拟）把画面点亮，再去拉网络 —— 不让首屏空着等 3 秒
	var cached := _load_cache()
	if not cached:
		_apply_simulated()
	_fetch()


func _process(delta: float) -> void:
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta / TRANSITION)
	if _forced or _manual >= 0 or _busy:
		return
	_wait -= delta
	if _wait <= 0.0:
		_fetch()


# ---------------------------------------------------------------- 对外：渲染参数
## 当前插值后的渲染参数（渲染层每帧读它，不关心 from/to）
func tone() -> Dictionary:
	var a := _from_params
	var b := _to_params
	var k := _blend
	if k >= 1.0:
		return b
	var wa: Vector3 = a["warm"]
	var wb: Vector3 = b["warm"]
	var ta: Color = a["tint"]
	var tb: Color = b["tint"]
	return {
		"exposure": lerpf(float(a["exposure"]), float(b["exposure"]), k),
		"sat": lerpf(float(a["sat"]), float(b["sat"]), k),
		"contrast": lerpf(float(a["contrast"]), float(b["contrast"]), k),
		"warm": wa.lerp(wb, k),
		"tint": Color(lerpf(ta.r, tb.r, k), lerpf(ta.g, tb.g, k),
			lerpf(ta.b, tb.b, k), lerpf(ta.a, tb.a, k)),
		"cloud": lerpf(float(a["cloud"]), float(b["cloud"]), k),
		"rain": lerpf(float(a["rain"]), float(b["rain"]), k),
		"snow": lerpf(float(a["snow"]), float(b["snow"]), k),
		"sun": lerpf(float(a["sun"]), float(b["sun"]), k),
	}


## 降水强度：天气码里雨量很小的（毛毛雨）不该下暴雨，所以按 precip 再收一道
func rain_strength() -> float:
	var t := tone()
	var v := float(t["rain"])
	if v <= 0.001:
		return 0.0
	# 0.2mm 以下是毛毛雨 → 0.45 倍；2mm 以上按满额
	var k := clampf(0.45 + precip_mm * 0.35, 0.45, 1.15)
	return clampf(v * k, 0.0, 1.0)


func snow_strength() -> float:
	var t := tone()
	return clampf(float(t["snow"]), 0.0, 1.0)


func cloud() -> float:
	return clampf(float(tone()["cloud"]), 0.0, 1.0)


## 晴天权重 0..1（云越少越晴）—— 天空层用它决定云飘得快不快
func cleanness() -> float:
	return clampf(1.0 - cloud() * 1.15, 0.0, 1.0)


func kind_name(k: int = -1) -> String:
	var v := kind if k < 0 else k
	match v:
		Kind.CLEAR: return "晴"
		Kind.CLOUDY: return "阴"
		Kind.RAIN: return "雨"
		Kind.SNOW: return "雪"
	return "晴"


## 画面上的天气是不是「可信的」：真实观测，或被环境变量强制指定。
## false 时 HUD 标「离线」—— 那是缓存过期或按气候模拟出来的，别让人以为是真的。
func is_live() -> bool:
	return live or _forced


## HUD 一行：`西安 小雨 10°C`
func short_text() -> String:
	var d := desc if desc != "" else kind_name()
	return "%s %s %d°C" % [CITY, d, temp_c]


## 手动锁定天气：传 Kind，或 -1 跟随现实
func set_manual(k: int) -> void:
	_manual = k
	if k < 0:
		_wait = 0.0               # 下一帧立刻去拉一次
		return
	_set_kind(k)


# ---------------------------------------------------------------- 内部：状态切换
func _set_kind(k: int, instant: bool = false) -> void:
	if k == kind and _blend >= 1.0:
		return
	_from_kind = kind
	_from_params = tone() if _blend < 1.0 else PARAMS[kind]
	_to_params = PARAMS[k]
	kind = k
	_blend = 1.0 if instant else 0.0


func _apply_env_weather(v: String) -> bool:
	match v.to_lower():
		"clear", "sun", "sunny", "0":
			_set_kind(Kind.CLEAR, true)
			desc = "晴"
			temp_c = 18
			cloud_cover = 0.1
		"cloudy", "overcast", "1":
			_set_kind(Kind.CLOUDY, true)
			desc = "阴"
			temp_c = 14
			cloud_cover = 0.9
		"rain", "2":
			_set_kind(Kind.RAIN, true)
			desc = "小雨"
			temp_c = 12
			cloud_cover = 1.0
			precip_mm = 1.6
		"snow", "3":
			_set_kind(Kind.SNOW, true)
			desc = "小雪"
			temp_c = -2
			cloud_cover = 1.0
			precip_mm = 1.0
		_:
			return false
	updated_label = "强制"
	return true


# ---------------------------------------------------------------- 内部：天气码
func _kind_of(code: int) -> int:
	if code in WWO_SNOW:
		return Kind.SNOW
	if code in WWO_RAIN:
		return Kind.RAIN
	if code in WWO_CLEAR:
		return Kind.CLEAR
	return Kind.CLOUDY


func _text_of(code: int) -> String:
	return String(WWO_TEXT.get(code, ""))


# ---------------------------------------------------------------- 内部：网络
func _fetch() -> void:
	if _busy:
		return
	_busy = true
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = HTTP_TIMEOUT
		_http.use_threads = true
		add_child(_http)
	var err := _http.request(API_URL, PackedStringArray([
		"User-Agent: curl/8.4.0",     # wttr.in 对陌生 UA 会返回 HTML 提示页
		"Accept: application/json",
	]), HTTPClient.METHOD_GET)
	if err != OK:
		_busy = false
		_wait = RETRY_SEC
		return
	if not _http.request_completed.is_connected(_on_http_done):
		_http.request_completed.connect(_on_http_done)


func _on_http_done(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	_busy = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_wait = RETRY_SEC
		_after_failure()
		return
	var txt := body.get_string_from_utf8()
	var data: Variant = JSON.parse_string(txt)
	if typeof(data) != TYPE_DICTIONARY or not (data as Dictionary).has("current_condition"):
		_wait = RETRY_SEC
		_after_failure()
		return
	var cc: Dictionary = (data as Dictionary)["current_condition"][0]
	var wcode := int(str(cc.get("weatherCode", "116")))
	temp_c = int(str(cc.get("temp_C", "0")))
	humidity = int(str(cc.get("humidity", "0")))
	precip_mm = float(str(cc.get("precipMM", "0")))
	cloud_cover = clampf(float(str(cc.get("cloudcover", "50"))) / 100.0, 0.0, 1.0)
	var d: Variant = cc.get("weatherDesc", [])
	if typeof(d) == TYPE_ARRAY and (d as Array).size() > 0:
		# 英文描述只当日志兜底用，显示一律走中文码表
		pass
	desc = _text_of(wcode)
	if desc == "":
		desc = kind_name(_kind_of(wcode))
	live = true
	_refreshed = true
	updated_label = DayNight.time_string()
	_wait = REFRESH_SEC
	_set_kind(_kind_of(wcode))
	_save_cache(wcode)


## 失败时：有缓存就用缓存（live=false，但至少是西安真实观测），没有就模拟
func _after_failure() -> void:
	if not _load_cache(true):
		if not live:
			_apply_simulated()


# ---------------------------------------------------------------- 内部：缓存
func _save_cache(wcode: int) -> void:
	var f := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"ts": int(Time.get_unix_time_from_system()),
		"code": wcode,
		"temp": temp_c,
		"hum": humidity,
		"precip": precip_mm,
		"cloud": cloud_cover,
		"label": updated_label,
	}))
	f.close()


## 读缓存并应用。stale_ok=true 时过期也用（网络挂了总比没有好）。
func _load_cache(stale_ok: bool = false) -> bool:
	if not FileAccess.file_exists(CACHE_PATH):
		return false
	var f := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return false
	var txt := f.get_as_text()
	f.close()
	var d: Variant = JSON.parse_string(txt)
	if typeof(d) != TYPE_DICTIONARY:
		return false
	var dict := d as Dictionary
	var age := float(Time.get_unix_time_from_system()) - float(dict.get("ts", 0))
	if age > CACHE_TRUST_SEC and not stale_ok:
		return false
	var wcode := int(dict.get("code", 116))
	temp_c = int(dict.get("temp", 0))
	humidity = int(dict.get("hum", 0))
	precip_mm = float(dict.get("precip", 0.0))
	cloud_cover = clampf(float(dict.get("cloud", 0.5)), 0.0, 1.0)
	desc = _text_of(wcode)
	if desc == "":
		desc = kind_name(_kind_of(wcode))
	var lbl := String(dict.get("label", ""))
	updated_label = lbl if lbl != "" else "缓存"
	live = age <= CACHE_TRUST_SEC
	_set_kind(_kind_of(wcode), true)
	return true


# ---------------------------------------------------------------- 内部：模拟
## 完全离线时的兜底：按月份 + 日期给一个稳定的「西安大概会是什么天」。
## 同一天反复启动结果一致（用日期做种子），不会每次开游戏都变。
func _apply_simulated() -> void:
	var now := Time.get_datetime_dict_from_system()
	var seed_v := int(now.year) * 10000 + int(now.month) * 100 + int(now.day)
	var r := _rand01(seed_v + int(now.hour) / 6)   # 每 6 小时换一档
	var m := int(now.month)
	var p_snow := 0.0
	var p_rain := 0.35
	var p_cloud := 0.30
	if m == 12 or m <= 2:
		p_snow = 0.18
		p_rain = 0.05
	elif m >= 7 and m <= 9:
		p_rain = 0.42
	elif m in [3, 4, 5]:
		p_rain = 0.24
	if r < p_snow:
		kind = Kind.SNOW
		desc = "小雪"
		temp_c = -1
		precip_mm = 1.2
	elif r < p_snow + p_rain:
		kind = Kind.RAIN
		desc = "小雨"
		temp_c = 14 if m in [6, 7, 8] else 11
		precip_mm = 1.4
	elif r < p_snow + p_rain + p_cloud:
		kind = Kind.CLOUDY
		desc = "多云"
		temp_c = 16
		precip_mm = 0.0
	else:
		kind = Kind.CLEAR
		desc = "晴"
		temp_c = 24 if m in [6, 7, 8] else 17
		precip_mm = 0.0
	cloud_cover = {"晴": 0.15, "多云": 0.75, "小雨": 1.0, "小雪": 1.0}.get(desc, 0.5)
	live = false
	updated_label = "离线模拟"
	_set_kind(kind, true)


## 稳定的 0..1 伪随机（同一 seed 永远同值）
func _rand01(s: int) -> float:
	var h := (s * 374761393 + 668265263) & 0x7FFFFFFF
	h = ((h ^ (h >> 13)) * 1274126177) & 0x7FFFFFFF
	return float(h % 10007) / 10007.0
