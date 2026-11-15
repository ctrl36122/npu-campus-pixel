extends Node
## 雨声（只在 RAIN 态响）。优先播放真实雨夜环境录音，缺素材才退回程序合成。
##
## 录音：assets/ambience/rain.ogg —— 用户指定的 Dark Rainy Night (ambience)，
##   44.1kHz 立体声 Vorbis，278.8s（4.6 分钟循环一次）。Vorbis 是无缝格式，
##   不像 MP3 会在首尾补静音，所以**原样拷贝、不重编码**。
##   ⚠️ 源文件开头 0.5s 全静音、前 20 多秒是很轻的渐强，结尾却是满电平雨声。
##   直接从头循环会每 4.6 分钟静音一秒 —— 用 LOOP_OFFSET=24s 跳到雨声已起来的
##   平稳段，首次起播也从 24s 开始；接缝电平差约 6dB（听感像雨势缓了一下），
##   循环体仍有 4.2 分钟，不会听出重复。
##
## 回退：白噪过两级低通做「哗」的底 + 更闷的低频雨幕 + 慢速幅度起伏
##   （恒定音量的白噪听着像电流，会动的才是雨）。零素材、clone 后照样有雨声。
##
## 音量跟 Weather.rain_strength() 走；进屋（Sfx.indoor）压低一截；
## 遵守设置里的音效音量与静音。

const SAMPLE := "res://assets/ambience/rain.ogg"
const LOOP_OFFSET := 24.0     # 秒：跳过源文件开头的静音 + 渐强段，落到平稳雨声
## 录音主体 RMS ≈ -28dBFS，合成噪声 ≈ -17dBFS，录音轻约 11dB。
## 少衰减 8dB 补回来，让它和原来的合成雨声听感差不多响。
const SAMPLE_GAIN := 8.0

const RATE := 22050
const SECONDS := 3.0          # 合成回退的循环体长度；噪声本身无缝，随便接

var _player: AudioStreamPlayer
var _db := -80.0
var _using_sample := false
var _dbg_t := 0.0


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "RainLoop"
	_player.stream = _pick_stream()
	_player.bus = "Master"
	_player.volume_db = _db
	add_child(_player)


## 录音优先。ogg 的循环参数在运行时兜一层，.import 里勾没勾都不影响。
func _pick_stream() -> AudioStream:
	if ResourceLoader.exists(SAMPLE):
		var s: AudioStream = load(SAMPLE)
		if s != null:
			if s is AudioStreamOggVorbis:
				(s as AudioStreamOggVorbis).loop = true
				(s as AudioStreamOggVorbis).loop_offset = LOOP_OFFSET
			elif s is AudioStreamMP3:
				(s as AudioStreamMP3).loop = true
			_using_sample = true
			return s
	return _make_loop()


func using_sample() -> bool:
	return _using_sample


## 没有录音时合成一段 3 秒的无缝雨声（保留原实现，一个字节都没改）。
func _make_loop() -> AudioStreamWAV:
	var n := int(RATE * SECONDS)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261115
	var data := PackedByteArray()
	data.resize(n * 2)
	# 两级低通：a1 出「哗啦」（切 ~1400Hz），a2 出「沙沙」底（切 ~420Hz）
	var a1 := 1.0 - exp(-TAU * 1400.0 / RATE)
	var a2 := 1.0 - exp(-TAU * 420.0 / RATE)
	var lp1 := 0.0
	var lp2 := 0.0
	# 慢速幅度起伏：两个错频正弦叠出来就够，不用真噪声
	for i in n:
		var t := float(i) / RATE
		var x := rng.randf_range(-1.0, 1.0)
		lp1 += (x - lp1) * a1
		lp2 += (x - lp2) * a2
		# 循环接缝要平滑：最后 0.2s 线性淡出、开头淡入，叠在起伏包络里
		var seam := clampf(t / 0.2, 0.0, 1.0) * clampf((SECONDS - t) / 0.2, 0.0, 1.0)
		var wob := 0.72 + 0.28 * sin(TAU * t / 2.7) * sin(TAU * t / 5.3 + 1.1)
		var s := (lp1 * 0.62 + lp2 * 0.55) * wob * seam
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 26000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	w.data = data
	return w


func _process(delta: float) -> void:
	var rain := Weather.rain_strength()
	var target := -80.0
	if rain > 0.02:
		# 小雨 -34dB 起，大雨 -14dB 封顶；别盖过 BGM 和脚步
		target = lerpf(-34.0, -14.0, clampf(rain * 1.15, 0.0, 1.0))
		if _using_sample:
			target += SAMPLE_GAIN
		# 用户在设置里关了音效/拉了音量，得认
		if Sfx.muted():
			target = -80.0
		else:
			target += linear_to_db(clampf(Sfx.volume(), 0.05, 1.0))
		if Sfx.indoor():
			target -= 15.0        # 在屋里，隔窗听雨
	# 音量滑动过渡，雨强变化时不会一格格跳
	_db = lerpf(_db, target, clampf(delta * 2.5, 0.0, 1.0))
	if _db < -78.0:
		if _player.playing:
			_player.stop()
	else:
		if not _player.playing:
			# 从循环点起播，跳过录音开头的静音渐强
			_player.play(LOOP_OFFSET if _using_sample else 0.0)
		_player.volume_db = _db
	if OS.has_environment("XGD_RAIN_DEBUG"):
		_dbg_t += delta
		if _dbg_t >= 1.0:
			_dbg_t = 0.0
			print("[rain] ", "录音" if _using_sample else "合成",
				"  rain=", snappedf(rain, 0.01),
				"  target=", snappedf(target, 0.1), "dB",
				"  now=", snappedf(_db, 0.1), "dB",
				"  playing=", str(_player.playing),
				"  at=", snappedf(_player.get_playback_position(), 0.1), "s")
