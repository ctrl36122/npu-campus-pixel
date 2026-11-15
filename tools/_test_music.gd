extends SceneTree
## 背景音乐自测：素材能否加载、天气/场景切换键名、图书馆静音、音量/静音的存档往返。
##
## 用法：
##   APPDATA=<临时目录> godot --headless --path . --script res://tools/_test_music.gd
## 说明：headless 用 Dummy 音频驱动，听不到声，但 playing / volume_db / stream
##       这些属性照常，够验证逻辑。真机出声另跑截图。
##
## 用临时 APPDATA 隔离，是因为这条测试会写 user://audio.cfg。
## ⚠️ --headless --script 下 Godot 仍会挂真的 autoload：Weather 要复用 /root/Weather，
##    再 add_child 一个同名节点会被自动改名 Weather2，改了桩根本不生效。

var _ok := 0
var _bad := 0
var _done := false


class WeatherStub extends Node:
	var kind: int = 0


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("\n[music] %d 项通过, %d 项失败" % [_ok, _bad])
	quit(0 if _bad == 0 else 1)
	return true


func _check(name: String, cond: bool, extra: String = "") -> void:
	if cond:
		_ok += 1
		print("  ok   ", name, (" " + extra) if not extra.is_empty() else "")
	else:
		_bad += 1
		print("  FAIL ", name, "  " + extra)


## 改天气并立刻重算（不等下一帧）
func _weather(m: Node, k: int) -> void:
	var w := root.get_node_or_null("/root/Weather")
	if w != null:
		w.set("kind", k)
	m.call("_refresh")


func _run() -> void:
	if root.get_node_or_null("/root/Weather") == null:
		var stub := WeatherStub.new()
		stub.name = "Weather"
		root.add_child(stub)
		print("  (没挂 Weather autoload，用桩)")
	var m: Node = root.get_node_or_null("Music")
	if m == null:
		m = load("res://net/autoload/Music.gd").new()
		m.name = "Music"
		root.add_child(m)
		print("  (--script 模式没挂 Music autoload，手动实例化)")

	print("[music] 素材与循环")
	_check("六首里至少有一首能加载", bool(m.call("available")))
	# 菜单那首是 wav（要保持无缝循环），其余是转码过的 mp3
	for key in ["menu", "campus_clear", "campus_rain_day", "campus_rain_night",
			"campus_snow", "dorm"]:
		var ext := ".wav" if key == "menu" else ".mp3"
		var path := "res://assets/music/%s%s" % [key, ext]
		if not FileAccess.file_exists(path):
			_check("文件存在 " + key, false, path)
			continue
		var s: AudioStream = load(path)
		_check("  %s 是可播流" % key, s != null, str(s))
		if s is AudioStreamMP3:
			_check("  %s 开了循环" % key, (s as AudioStreamMP3).loop)

	print("[music] 加载/声明页")
	_check("开机默认放菜单曲", str(m.call("current_key")) == "menu", str(m.call("current_key")))
	m.call("set_menu", false)

	print("[music] 校园按天气选曲")
	_weather(m, 0)
	_check("晴 -> campus_clear", str(m.call("current_key")) == "campus_clear",
		str(m.call("current_key")))
	_weather(m, 1)
	_check("阴跟晴天同一首", str(m.call("current_key")) == "campus_clear",
		str(m.call("current_key")))
	_weather(m, 2)
	var rain_key := str(m.call("current_key"))
	_check("雨 -> 校园雨天曲", rain_key == "campus_rain_day" or rain_key == "campus_rain_night",
		rain_key)
	var dn := root.get_node_or_null("/root/DayNight")
	if dn != null:
		var want_day := float(dn.call("daylight")) > 0.35
		_check("  雨天昼夜跟 DayNight 一致", (rain_key == "campus_rain_day") == want_day,
			"daylight=%s" % dn.call("daylight"))
	_weather(m, 3)
	_check("雪 -> campus_snow", str(m.call("current_key")) == "campus_snow",
		str(m.call("current_key")))
	_weather(m, 0)
	_check("回到晴 -> campus_clear", str(m.call("current_key")) == "campus_clear",
		str(m.call("current_key")))

	print("[music] 场景切换")
	m.call("set_room_kind", "dorm")
	_check("宿舍 -> dorm", str(m.call("current_key")) == "dorm", str(m.call("current_key")))
	_check("宿舍曲在播", bool(m.call("playing")))

	m.call("set_room_kind", "study")
	_check("图书馆 -> 静音（没曲目）", str(m.call("current_key")) == "",
		str(m.call("current_key")))
	_check("图书馆不放 BGM", not bool(m.call("playing")))
	_weather(m, 3)
	_check("图书馆里换天气也不冒出 BGM", str(m.call("current_key")) == "",
		str(m.call("current_key")))

	m.call("set_room_kind", "")
	_weather(m, 2)
	var back_key := str(m.call("current_key"))
	_check("出图书馆回雨天校园", back_key == "campus_rain_day" or back_key == "campus_rain_night",
		back_key)
	_weather(m, 0)

	print("[music] 音量 / 静音 / 存档")
	m.call("set_volume", 0.3)
	_check("音量记住", is_equal_approx(float(m.call("volume")), 0.3))
	m.call("set_muted", true)
	_check("静音生效", bool(m.call("muted")))
	var cfg := ConfigFile.new()
	_check("存档写到 user://audio.cfg", cfg.load("user://audio.cfg") == OK)
	_check("  存档音量 = 0.3", is_equal_approx(float(cfg.get_value("audio", "music", -1.0)), 0.3))
	_check("  存档静音 = true", bool(cfg.get_value("audio", "muted", false)))

	m.call("set_muted", false)
	m.call("set_volume", 0.55)
	_check("恢复后不静音", not bool(m.call("muted")))

	# 缺素材时不能抛错：临时指向一个不存在的键名
	m.call("set_room_kind", "no_such_track")
	_check("未知曲目静音收场", str(m.call("current_key")) == "")
	m.call("set_room_kind", "")
