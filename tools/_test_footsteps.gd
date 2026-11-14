extends SceneTree
## 脚步声自测：材质判定、四种音色的差异、室内外切换、音量/静音存档，外加导出试听。
##
## 用法：
##   APPDATA=<临时目录> godot --headless --path . --script res://tools/_test_footsteps.gd
## 产物：
##   build/_step_<材质>.wav —— 每种材质 4 个变体各响一次，留 0.25s 间隔，直接播来听。

const SAMPLE_RATE := 22050
const KINDS := ["grass", "asphalt", "stone", "wood"]

var _ok := 0
var _bad := 0
var _done := false


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("\n[steps] %d 项通过, %d 项失败" % [_ok, _bad])
	quit(0 if _bad == 0 else 1)
	return true


func _check(name: String, cond: bool, extra: String = "") -> void:
	if cond:
		_ok += 1
		print("  ok   ", name, (" " + extra) if not extra.is_empty() else "")
	else:
		_bad += 1
		print("  FAIL ", name, "  " + extra)


func _node(script_path: String, node_name: String) -> Node:
	var n: Node = root.get_node_or_null(node_name)
	if n == null:
		n = load(script_path).new()
		n.name = node_name
		root.add_child(n)
		print("  (--script 模式没挂 autoload，手动实例化 ", node_name, ")")
	return n


func _samples(w: AudioStreamWAV) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var n := w.data.size() / 2
	out.resize(n)
	for i in n:
		out[i] = float(w.data.decode_s16(i * 2)) / 32768.0
	return out


func _peak(a: PackedFloat32Array, from: int, to: int) -> float:
	var m := 0.0
	for i in range(maxi(from, 0), mini(to, a.size())):
		m = maxf(m, absf(a[i]))
	return m


## 过零率：低通的噪声里，越亮的音色过零越频繁，拿来当「音色明暗」的客观指标
func _zcr(a: PackedFloat32Array) -> float:
	var n := 0
	for i in range(1, a.size()):
		if (a[i] >= 0.0) != (a[i - 1] >= 0.0):
			n += 1
	return float(n) / float(maxi(a.size(), 1))


func _run() -> void:
	var ground := _node("res://net/autoload/Ground.gd", "Ground")
	var sfx := _node("res://net/autoload/Sfx.gd", "Sfx")

	print("[steps] 地面材质图")
	_check("材质图加载成功", bool(ground.call("available")))
	# 抽查：停车场=沥青、中央海天苑院落=石板、普通草坪=草
	var cases := [
		["停车场(124,84)", Vector2i(124, 84), "asphalt"],
		["停车场(110,362)", Vector2i(110, 362), "asphalt"],
		["海天苑院落(220,500)", Vector2i(220, 500), "stone"],
		["草坪(150,650)", Vector2i(150, 650), "grass"],
	]
	for c in cases:
		var tile: Vector2i = c[1]
		var pos := Vector2(tile.x * 8 + 4, tile.y * 8 + 4)
		var k := str(ground.call("kind_at", pos))
		_check("%s -> %s" % [c[0], c[2]], k == str(c[2]), "实际 " + k)

	print("[steps] 四种音色")
	var bright := {}
	var peaks := {}
	for kind in KINDS:
		var list: Array = sfx.call("_streams", kind)
		_check("%s 有 4 个变体" % kind, list.size() == 4, str(list.size()))
		var w: AudioStreamWAV = list[0]
		var a := _samples(w)
		_check("  %s 格式正确" % kind,
			w.format == AudioStreamWAV.FORMAT_16_BITS and not w.stereo and w.mix_rate == SAMPLE_RATE)
		var pk := _peak(a, 0, a.size())
		_check("  %s 有声音不削波" % kind, pk > 0.3 and pk <= 0.95, "peak=%.2f" % pk)
		var head := _peak(a, 0, a.size() / 5)
		var tail := _peak(a, a.size() * 4 / 5, a.size())
		_check("  %s 响一下后衰减" % kind, tail < head * 0.4, "head=%.2f tail=%.2f" % [head, tail])
		_check("  %s 首样本接近 0（不爆音）" % kind, absf(a[0]) < 0.05, "%.3f" % a[0])
		bright[kind] = _zcr(a)
		peaks[kind] = pk

	print("  明暗（过零率）", bright)
	_check("草地比沥青闷", float(bright["grass"]) < float(bright["asphalt"]),
		"%.3f vs %.3f" % [bright["grass"], bright["asphalt"]])
	_check("沥青比石板闷", float(bright["asphalt"]) < float(bright["stone"]),
		"%.3f vs %.3f" % [bright["asphalt"], bright["stone"]])
	_check("草地比石板轻", float(peaks["grass"]) < float(peaks["stone"]),
		"%.2f vs %.2f" % [peaks["grass"], peaks["stone"]])

	print("[steps] 室内外")
	sfx.call("set_indoor", true)
	_check("进楼 -> 室内", bool(sfx.call("indoor")))
	sfx.call("set_indoor", false)
	_check("出楼 -> 室外", not bool(sfx.call("indoor")))

	print("[steps] 音量 / 静音 / 存档")
	sfx.call("set_volume", 0.35)
	_check("音量记住", is_equal_approx(float(sfx.call("volume")), 0.35))
	sfx.call("set_muted", true)
	_check("静音生效", bool(sfx.call("muted")))
	var cfg := ConfigFile.new()
	_check("存档写入 user://audio.cfg", cfg.load("user://audio.cfg") == OK)
	_check("  存档音效音量 = 0.35", is_equal_approx(float(cfg.get_value("audio", "sfx", -1.0)), 0.35))
	_check("  存档音效静音 = true", bool(cfg.get_value("audio", "sfx_muted", false)))
	sfx.call("set_muted", false)
	sfx.call("set_volume", 0.7)

	for i in 12:
		sfx.call("footstep", Vector2(1000, 700))
	_check("连按 12 次不报错", true)

	print("[steps] 导出试听")
	for kind in KINDS:
		var list: Array = sfx.call("_streams", kind)
		var gap := int(SAMPLE_RATE * 0.25)
		var total := 0
		for w in list:
			total += (w as AudioStreamWAV).data.size() / 2 + gap
		var pcm := PackedByteArray()
		pcm.resize(total * 2)                       # 全 0，间隔自然是静音
		var pos := 0
		for w in list:
			var d: PackedByteArray = (w as AudioStreamWAV).data
			var frames_n: int = d.size() / 2
			for i in frames_n:
				pcm.encode_s16((pos + i) * 2, d.decode_s16(i * 2))
			pos += frames_n + gap
		var path := "res://build/_step_%s.wav" % kind
		_check("  写出 " + path, _write_wav(path, pcm, total))
	print("       试听文件在 ", ProjectSettings.globalize_path("res://build/"))


## 手写 16bit 单声道 WAV（Godot 没有「把任意 PCM 存成 wav」的现成接口）
func _write_wav(path: String, pcm: PackedByteArray, frames: int) -> bool:
	var h := StreamPeerBuffer.new()
	h.put_data("RIFF".to_utf8_buffer())
	h.put_32(36 + pcm.size())
	h.put_data("WAVEfmt ".to_utf8_buffer())
	h.put_32(16)
	h.put_16(1)                       # PCM
	h.put_16(1)                       # mono
	h.put_32(SAMPLE_RATE)
	h.put_32(SAMPLE_RATE * 2)         # byte rate
	h.put_16(2)                       # block align
	h.put_16(16)                      # bits
	h.put_data("data".to_utf8_buffer())
	h.put_32(pcm.size())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(h.data_array)
	f.store_buffer(pcm)
	f.close()
	return frames > 0
