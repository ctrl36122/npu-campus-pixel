extends Node
## 音效（autoload 名 Sfx）。目前只有脚步声。
##
## 脚步声按**踩到的地面材质**换音色（材质由图集 assets/ground_kind.png 决定，
## 见 Ground.gd / tools/bake_ground_kind.py）：
##   grass    草地：闷、软、长一点（沙沙）
##   asphalt  沥青/水泥：中等偏硬，带一点低频「踏」
##   stone    石板广场：最脆，带一下高频「嗒」的余韵
##   wood     室内（宿舍/自习空间木地板、瓷砖）
##   water 等极少见的情况归到草地（湖面本身走不上去）
##
## 素材策略沿用项目里「缺素材就程序补」的习惯：
##   1. 先找 assets/steps/<材质>_*.wav（真录音，丢进去就用）；
##   2. 找不到就**现场合成**（噪声爆发 + 低频冲击 + 可选的高频「嗒」）。
## 每次播放随机挑一个变体 + 轻微随机音高/音量，避免连续几步像复读机。
##
## 只给**本地玩家**出声：远端玩家的脚步要靠位置同步 + 距离衰减才有意义，
## 现在没有那套东西，硬放会在联机时变成一片乱响。

const RATE := 22050
const VOICES := 4                 # 每种材质合成多少个变体
const POOL := 4                   # 同时最多几路脚步声叠在一起
const CFG_PATH := "user://audio.cfg"
const DEFAULT_VOLUME := 0.7
## 每种材质一组合成参数（见下面的 _synth），键名要和 Ground.KINDS 对得上
const TIMBRE := {
	# cutoff 低通截止 / poles 阶数 / decay 主体衰减 / thump_* 低频「踏」/ tick_* 高频「嗒」
	"grass": {"cut": 700.0, "poles": 3, "gain": 6.2, "decay": 22.0,
			  "thump_f": 70.0, "thump_a": 0.45, "thump_d": 44.0,
			  "tick_f": 0.0, "tick_a": 0.0, "tick_d": 90.0, "dur": 0.16, "level": 0.72},
	"asphalt": {"cut": 1500.0, "poles": 3, "gain": 5.5, "decay": 36.0,
				"thump_f": 95.0, "thump_a": 0.5, "thump_d": 50.0,
				"tick_f": 0.0, "tick_a": 0.0, "tick_d": 90.0, "dur": 0.12, "level": 0.85},
	"stone": {"cut": 2600.0, "poles": 3, "gain": 4.6, "decay": 48.0,
			  "thump_f": 130.0, "thump_a": 0.28, "thump_d": 70.0,
			  "tick_f": 780.0, "tick_a": 0.30, "tick_d": 95.0, "dur": 0.09, "level": 0.95},
	"wood": {"cut": 2000.0, "poles": 3, "gain": 4.8, "decay": 44.0,
			 "thump_f": 110.0, "thump_a": 0.34, "thump_d": 66.0,
			 "tick_f": 620.0, "tick_a": 0.22, "tick_d": 80.0, "dur": 0.10, "level": 0.90},
}
## 每种材质给一个随机种子偏移，避免四种材质的「变体 1」其实是同一串噪声
const KINDS_SEED := {"grass": 0, "asphalt": 1000, "stone": 2000, "wood": 3000}

var _indoor := false
var _volume := DEFAULT_VOLUME
var _muted := false
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _cache: Dictionary = {}       # 材质名 -> Array[AudioStream]
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.seed = 20261114
	_load_prefs()
	for i in POOL:
		var p := AudioStreamPlayer.new()
		p.name = "Step%d" % i
		p.bus = "Master"
		add_child(p)
		_players.append(p)


# ---------------------------------------------------------------- 对外接口
## 进/出室内：换一套音色（由 Arena 在进房/出房时调用）
func set_indoor(on: bool) -> void:
	_indoor = on


func indoor() -> bool:
	return _indoor


## 走一步。由本地玩家按「走过的距离」触发，频率不用调用方管。
## at：校园层局部坐标（= 地面贴图像素），用来查脚下是什么材质。
func footstep(at: Vector2) -> void:
	if _muted or _volume <= 0.001:
		return
	var kind := "wood" if _indoor else Ground.kind_at(at)
	# 湖面本身走不上去，岸边偶尔判到 water 就当草地，别突然「哗」一下
	if not TIMBRE.has(kind):
		kind = "grass"
	var list := _streams(kind)
	if list.is_empty():
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = list[_rng.randi() % list.size()]
	p.volume_db = linear_to_db(_volume * _rng.randf_range(0.82, 1.0))
	# 音高抖一点，连续几步才不会像复读机
	p.pitch_scale = _rng.randf_range(0.93, 1.08)
	p.play()
	if OS.has_environment("XGD_SFX_DEBUG"):
		print("[sfx] step ", kind, "  pitch ", snappedf(p.pitch_scale, 0.01),
			"  vol ", snappedf(p.volume_db, 0.1), "dB")


func set_volume(v: float) -> void:
	_volume = clampf(v, 0.0, 1.0)
	_save_prefs()


func volume() -> float:
	return _volume


func set_muted(m: bool) -> void:
	_muted = m
	_save_prefs()


func muted() -> bool:
	return _muted


## 现在用的是真素材还是合成音（设置面板/自测用）
func using_samples(kind: String) -> bool:
	var dir := "res://assets/steps"
	if not DirAccess.dir_exists_absolute(dir):
		return false
	for f in DirAccess.get_files_at(dir):
		if f.begins_with(kind + "_") and not f.ends_with(".import"):
			return true
	return false


# ---------------------------------------------------------------- 取音源
func _streams(kind: String) -> Array:
	if _cache.has(kind):
		return _cache[kind]
	var out: Array = []
	# 1) 真素材优先
	var dir := "res://assets/steps"
	if DirAccess.dir_exists_absolute(dir):
		var files := DirAccess.get_files_at(dir)
		files.sort()
		for f in files:
			if not f.begins_with(kind + "_"):
				continue
			var path := "%s/%s" % [dir, f]
			if ResourceLoader.exists(path):
				var s: AudioStream = load(path)
				if s != null:
					out.append(s)
	# 2) 没有就合成
	if out.is_empty():
		for i in VOICES:
			out.append(_synth(kind, i))
	_cache[kind] = out
	return out


## 按材质合成一次脚步：
##   噪声过 N 级低通（决定「软/脆」）+ 指数包络，再叠低频「踏」和可选的高频「嗒」。
##   草地：低通低、衰减慢 → 闷闷的沙沙声
##   沥青：中频、带一点低频冲击 → 「踏」
##   石板：低通高 + 780Hz 的「嗒」→ 脆
##   木地板：介于沥青和石板之间，620Hz 的木质感更钝
func _synth(kind: String, variant: int) -> AudioStreamWAV:
	var cfg: Dictionary = TIMBRE.get(kind, TIMBRE["grass"])
	var rng := RandomNumberGenerator.new()
	rng.seed = 7331 + variant * 97 + KINDS_SEED.get(kind, 0)

	var dur := float(cfg["dur"])
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)

	# 多级低通：一阶滚降太缓（-6dB/oct），高频剩一堆「嘶」，听着像撕纸不像踩地
	var a := 1.0 - exp(-TAU * float(cfg["cut"]) / float(RATE))
	var poles: int = int(cfg["poles"])
	var decay := float(cfg["decay"])
	var thump_f := float(cfg["thump_f"])
	var thump_a := float(cfg["thump_a"])
	var thump_d := float(cfg["thump_d"])
	var tick_f := float(cfg["tick_f"])
	var tick_a := float(cfg["tick_a"])
	var tick_d := float(cfg["tick_d"])
	var gain_in := float(cfg["gain"])

	var lp := PackedFloat32Array()
	lp.resize(poles)
	var phase := 0.0
	var tick_phase := 0.0
	var peak := 0.0
	var buf := PackedFloat32Array()
	buf.resize(n)

	for i in n:
		var t := float(i) / float(RATE)
		var env := exp(-t * decay)
		# 起手 0.8ms 的淡入，免得第一个采样就跳变出「咔」
		var attack := clampf(t / 0.0008, 0.0, 1.0)
		var x := rng.randf_range(-1.0, 1.0)
		for k in poles:
			lp[k] += (x - lp[k]) * a
			x = lp[k]
		phase += TAU * thump_f / float(RATE)
		var s := x * env * attack * gain_in
		s += sin(phase) * exp(-t * thump_d) * attack * thump_a
		if tick_a > 0.0:
			tick_phase += TAU * tick_f / float(RATE)
			s += sin(tick_phase) * exp(-t * tick_d) * attack * tick_a
		buf[i] = s
		peak = maxf(peak, absf(s))

	# 先归一化（各变体音量一致），再按材质乘一个整体响度
	# （草地本来就该比石板轻，不然后者一走起来像打快板）
	var norm := 0.82 * float(cfg["level"]) / maxf(peak, 0.0001)
	for i in n:
		data.encode_s16(i * 2, int(clampf(buf[i] * norm, -1.0, 1.0) * 32000.0))

	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


# ---------------------------------------------------------------- 存档
func _load_prefs() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	_volume = clampf(float(cfg.get_value("audio", "sfx", DEFAULT_VOLUME)), 0.0, 1.0)
	_muted = bool(cfg.get_value("audio", "sfx_muted", false))


func _save_prefs() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)          # 别把音乐那两栏冲掉
	cfg.set_value("audio", "sfx", _volume)
	cfg.set_value("audio", "sfx_muted", _muted)
	cfg.save(CFG_PATH)
