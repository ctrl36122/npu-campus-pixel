extends SceneTree
## 背景音乐自测：素材能否加载、场景切换键名、循环开关、音量/静音的存档往返。
##
## 用法：
##   APPDATA=<临时目录> godot --headless --path . --script res://tools/_test_music.gd
## 说明：headless 用 Dummy 音频驱动，听不到声，但 playing / volume_db / stream
##       这些属性照常，够验证逻辑。真机出声另跑截图。
##
## 用临时 APPDATA 隔离，是因为这条测试会写 user://audio.cfg。

var _ok := 0
var _bad := 0
var _done := false


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


## 场景里真的有 autoload 就用它，否则手动建一个（脚本逻辑完全一样）
func _music() -> Node:
	var m: Node = root.get_node_or_null("Music")
	if m == null:
		m = load("res://net/autoload/Music.gd").new()
		m.name = "Music"
		root.add_child(m)
		print("  (--script 模式没挂 autoload，手动实例化)")
	return m


func _run() -> void:
	var m := _music()

	print("[music] 素材与循环")
	_check("五首里至少有一首能加载", bool(m.call("available")))
	# 菜单那首是 wav（要保持无缝循环），其余是转码过的 mp3
	for key in ["menu", "campus_day", "campus_night", "dorm", "study"]:
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

	print("[music] 场景切换")
	m.call("set_room_kind", "dorm")
	_check("宿舍 -> dorm", str(m.call("current_key")) == "dorm", str(m.call("current_key")))
	_check("宿舍曲在播", bool(m.call("playing")))

	m.call("set_room_kind", "study")
	_check("自习空间 -> study", str(m.call("current_key")) == "study", str(m.call("current_key")))

	m.call("set_room_kind", "")
	var campus := str(m.call("current_key"))
	_check("回校园按昼夜选曲", campus == "campus_day" or campus == "campus_night", campus)

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
