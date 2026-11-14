extends Node
## 背景音乐（全局单例，autoload 名 Music）。
##
## 四首曲子按「当前在哪儿 + 白天黑夜」切换，切换时交叉淡入淡出，不会硬切。
##   menu          启动/加载/声明页（开机默认就放这首，进世界后换掉）
##   campus_day    校园 · 白天
##   campus_night  校园 · 夜晚
##   dorm          宿舍楼里（用户指定：Next to You）
##   study         自习空间 / 图书馆
##
## 素材放在 assets/music/，**不进 git**（第三方音乐，不做二次分发），
## 缺文件时整块静音、不报错，clone 下来的仓库照常能跑。
## 想换曲子只改下面的 TRACKS，键名别动（Arena / 设置面板都按键名调用）。

const TRACKS := {
	"menu": "res://assets/music/menu.wav",
	"campus_day": "res://assets/music/campus_day.mp3",
	"campus_night": "res://assets/music/campus_night.mp3",
	"dorm": "res://assets/music/dorm.mp3",
	"study": "res://assets/music/study.mp3",
}
const FADE := 1.6                 # 交叉淡入淡出时长（秒）
const VOLUME_PATH := "user://audio.cfg"
const DEFAULT_VOLUME := 0.55

var _players: Array[AudioStreamPlayer] = []
var _cur := 0                      # 当前在用的那一路
var _key := ""                     # 正在播的曲目键（"" = 没在播）
var _want := ""                    # 期望的曲目键
var _room_kind := ""               # "" = 校园；"dorm" / "study" = 室内
var _menu := true                  # true = 还在加载/声明页（开机默认就是它）
var _volume := DEFAULT_VOLUME
var _muted := false
var _fade: Tween
var _cache: Dictionary = {}        # key -> AudioStream（只收成功加载的）


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_prefs()
	for i in 2:
		var p := AudioStreamPlayer.new()
		p.name = "Ch%d" % i
		p.bus = "Master"
		p.volume_db = -80.0
		add_child(p)
		_players.append(p)
	set_process(true)
	_refresh()          # 开局就起菜单曲，别等第一帧


func _process(_dt: float) -> void:
	_refresh()


## 加载 / 声明页的循环曲：开机默认就放，进世界时传 false
func set_menu(on: bool) -> void:
	if _menu == on:
		return
	_menu = on
	_refresh()


func in_menu() -> bool:
	return _menu


## 进/出室内：kind = "" 表示回到校园，"dorm" / "study" 表示对应室内曲目
func set_room_kind(kind: String) -> void:
	if kind == _room_kind:
		return
	_room_kind = kind
	_refresh()


func _refresh() -> void:
	var want := _desired()
	if want != _want:
		_want = want
		_apply(want)


func room_kind() -> String:
	return _room_kind


## 0..1
func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.0)
	_push_gain()
	_save_prefs()


func volume() -> float:
	return _volume


func set_muted(m: bool) -> void:
	_muted = m
	_push_gain()
	_save_prefs()


func muted() -> bool:
	return _muted


func current_key() -> String:
	return _key


func playing() -> bool:
	if _key.is_empty():
		return false
	return _players[_cur].playing


## 给调试/自测用：这套素材到底能不能出声
func available() -> bool:
	for k in TRACKS:
		if _stream(str(k)) != null:
			return true
	return false


# ---------------------------------------------------------------- 内部
func _desired() -> String:
	if _menu:
		return "menu"
	if _room_kind != "":
		return _room_kind
	# 白天/夜晚：直接问昼夜系统，不自己算时钟
	var day := true
	var dn := get_node_or_null("/root/DayNight")
	if dn != null:
		day = float(dn.call("daylight")) > 0.35
	return "campus_day" if day else "campus_night"


func _stream(key: String) -> AudioStream:
	if _cache.has(key):
		return _cache[key]
	var p := str(TRACKS.get(key, ""))
	if p.is_empty() or not ResourceLoader.exists(p):
		return null
	var s: AudioStream = load(p)
	if s == null:
		return null
	# 循环在运行时兜一层保险：.import 里没勾 Loop 也一样整首循环
	if s is AudioStreamMP3:
		(s as AudioStreamMP3).loop = true
	elif s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true
	elif s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(round(w.get_length() * float(w.mix_rate)))
	_cache[key] = s
	return s


func _apply(key: String) -> void:
	var s := _stream(key)
	if s == null:
		# 缺素材（或这首没放进来）：静音收掉，不占着一路空播
		_stop_all()
		_key = ""
		return
	var next := 1 - _cur
	var p := _players[next]
	p.stream = s
	p.volume_db = -80.0
	p.play()
	_cur = next
	_key = key
	_fade_to(p, _gain_db(), FADE)
	var old := _players[1 - next]
	if old.playing:
		_fade_out(old, FADE)
	if OS.has_environment("XGD_MUSIC_DEBUG"):
		print("[music] -> ", key, "  ", str(s.get("resource_path")),
			"  ", snappedf(s.get_length(), 0.1), "s  gain ", snappedf(_gain_db(), 0.1), "dB",
			"  playing=", p.playing)


func _fade_to(p: AudioStreamPlayer, db: float, dur: float) -> void:
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_fade = create_tween()
	_fade.tween_property(p, "volume_db", db, dur)


func _fade_out(p: AudioStreamPlayer, dur: float) -> void:
	var t := create_tween()
	t.tween_property(p, "volume_db", -80.0, dur)
	t.tween_callback(func() -> void:
		if p != null and p.volume_db <= -79.0:
			p.stop())


func _gain_db() -> float:
	if _muted or _volume <= 0.001:
		return -80.0
	return linear_to_db(_volume)


func _push_gain() -> void:
	if _key.is_empty():
		return
	var p := _players[_cur]
	var t := create_tween()
	t.tween_property(p, "volume_db", _gain_db(), 0.25)


func _stop_all() -> void:
	for p in _players:
		if p.playing:
			p.stop()
		p.volume_db = -80.0


func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(VOLUME_PATH) != OK:
		return
	_volume = clampf(float(cfg.get_value("audio", "music", DEFAULT_VOLUME)), 0.0, 1.0)
	_muted = bool(cfg.get_value("audio", "muted", false))


func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "music", _volume)
	cfg.set_value("audio", "muted", _muted)
	cfg.save(VOLUME_PATH)
