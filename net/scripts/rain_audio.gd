extends Node
## 雨声：程序合成的循环噪声，不接任何音频素材。
##
## 配方：白噪过低通当「哗」的底，再叠一层更闷的低频噪声当远处的雨幕，
## 幅度用慢速噪声起伏 —— 恒定音量的白噪听着像电流，会动的才是雨。
## 音量跟 Weather.rain_strength() 走，进屋（Sfx.indoor）压低一截，
## 遵守设置里的音效音量与静音。

const RATE := 22050
const SECONDS := 3.0        # 循环体长度；噪声本身无缝，随便接

var _player: AudioStreamPlayer
var _db := -80.0


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "RainLoop"
	_player.stream = _make_loop()
	_player.bus = "Master"
	_player.volume_db = _db
	add_child(_player)


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
			_player.play()
		_player.volume_db = _db
