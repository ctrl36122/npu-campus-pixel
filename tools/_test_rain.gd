extends SceneTree
## 雨声自测：录音素材 / 循环接缝 / 程序合成回退 / 音量链路常量。
##
## 用法：
##   APPDATA=<临时目录> godot --headless --path . --script res://tools/_test_rain.gd
## 真机链路（雨强、静音、进屋）另用环境变量核：
##   XGD_WEATHER=rain XGD_RAIN_DEBUG=1 XGD_OFFLINE=1 XGD_NOHOME=1

const SAMPLE := "res://assets/ambience/rain.ogg"

var _ok := 0
var _bad := 0
var _done := false


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("\n[rain] %d 项通过, %d 项失败" % [_ok, _bad])
	quit(0 if _bad == 0 else 1)
	return true


func _check(name: String, cond: bool, extra: String = "") -> void:
	if cond:
		_ok += 1
		print("  ok   ", name, (" " + extra) if not extra.is_empty() else "")
	else:
		_bad += 1
		print("  FAIL ", name, "  " + extra)


func _run() -> void:
	print("[rain] 素材")
	_check("rain.ogg 存在", ResourceLoader.exists(SAMPLE))
	var s: AudioStream = load(SAMPLE) if ResourceLoader.exists(SAMPLE) else null
	_check("能加载成 AudioStream", s != null)
	if s != null:
		_check("是 Ogg Vorbis（无缝循环格式）", s is AudioStreamOggVorbis)
		var dur := s.get_length()
		_check("时长约 4.6 分钟", dur > 270.0 and dur < 290.0, "%.1fs" % dur)
		if s is AudioStreamOggVorbis:
			_check("  .import 已开循环", (s as AudioStreamOggVorbis).loop)
			_check("  .import 循环点跳过渐强段", is_equal_approx(
				(s as AudioStreamOggVorbis).loop_offset, 24.0))

	print("[rain] RainAudio 节点")
	var n := Node.new()
	n.name = "RainAudioTest"
	n.set_script(load("res://net/scripts/rain_audio.gd"))
	root.add_child(n)                 # _ready() 会调 _pick_stream()
	_check("有录音时 using_sample() = true", bool(n.call("using_sample")))
	var p: AudioStreamPlayer = n.get("_player")
	_check("播放器建好", p != null)
	if p != null and p.stream != null:
		_check("播放器挂的是录音", p.stream is AudioStreamOggVorbis)
		if p.stream is AudioStreamOggVorbis:
			var o := p.stream as AudioStreamOggVorbis
			_check("运行时兜底 loop = true", o.loop)
			_check("运行时兜底 loop_offset = 24s", is_equal_approx(o.loop_offset, 24.0),
				"%.1f" % o.loop_offset)
			_check("循环点落在录音之内", o.loop_offset < o.get_length())

	print("[rain] 缺素材时的合成回退")
	var w: AudioStreamWAV = n.call("_make_loop")
	_check("合成流能生成", w != null)
	if w != null:
		_check("  16bit / 单声道 / 22050Hz",
			w.format == AudioStreamWAV.FORMAT_16_BITS and not w.stereo and w.mix_rate == 22050)
		_check("  开了 LOOP_FORWARD", w.loop_mode == AudioStreamWAV.LOOP_FORWARD)
		_check("  长度 3 秒", is_equal_approx(float(w.data.size() / 2) / 22050.0, 3.0),
			"%.2fs" % (float(w.data.size() / 2) / 22050.0))
		# 首尾都要接近 0，否则循环点会「咔」一声
		var head := 0.0
		var tail := 0.0
		for i in 200:
			head = maxf(head, absf(float(w.data.decode_s16(i * 2)) / 32768.0))
			tail = maxf(tail, absf(float(w.data.decode_s16(w.data.size() - 2 - i * 2)) / 32768.0))
		_check("  接缝首尾都很轻", head < 0.05 and tail < 0.05,
			"head=%.3f tail=%.3f" % [head, tail])

	print("[rain] 音量参数")
	var scr = load("res://net/scripts/rain_audio.gd")
	var c: Dictionary = scr.get_script_constant_map()
	_check("录音电平补偿为正", float(c.get("SAMPLE_GAIN", 0.0)) > 0.0,
		str(c.get("SAMPLE_GAIN", 0.0)))
	_check("补偿不超过 12dB", float(c.get("SAMPLE_GAIN", 0.0)) <= 12.0)
	_check("LOOP_OFFSET 在 1~30s 之间", float(c.get("LOOP_OFFSET", 0.0)) > 1.0 and
		float(c.get("LOOP_OFFSET", 0.0)) < 30.0)
