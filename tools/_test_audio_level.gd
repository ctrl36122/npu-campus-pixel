extends SceneTree
## 全局响度校准自测：三条链路（音乐 / 脚步 / 雨声）是否都按同一个系数降了，
## 以及 audio.cfg 的四个键在两边各自写盘时不会互相冲掉。
##
## 用法：
##   APPDATA=<临时目录> godot --headless --path . --script res://tools/_test_audio_level.gd
## 真机响度另用环境变量看实际 dB：
##   XGD_MUSIC_DEBUG=1 XGD_SFX_DEBUG=1 XGD_WEATHER=rain XGD_RAIN_DEBUG=1

const CFG := "user://audio.cfg"

var _ok := 0
var _bad := 0
var _done := false


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	print("\n[level] %d 项通过, %d 项失败" % [_ok, _bad])
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
	return n


func _text(path: String) -> String:
	return FileAccess.get_file_as_string(path)


func _run() -> void:
	print("[level] 校准常量")
	var master := float(AudioLevel.MASTER)
	_check("MASTER 在 0..1 之间", master > 0.0 and master <= 1.0, "%.3f" % master)
	_check("MASTER 约等于 0.6", is_equal_approx(master, 0.6), "%.3f" % master)
	var trim := float(AudioLevel.trim_db())
	_check("trim_db 与 MASTER 一致", is_equal_approx(trim, linear_to_db(master)),
		"%.2fdB" % trim)
	_check("校准确实在降音量", trim < -1.0, "%.2fdB" % trim)
	_check("降幅不超过 10dB", trim > -10.0, "%.2fdB" % trim)

	print("[level] 三条链路都引用同一个常量")
	var refs := {
		"音乐": "res://net/autoload/Music.gd",
		"脚步": "res://net/autoload/Sfx.gd",
		"雨声": "res://net/scripts/rain_audio.gd",
	}
	for name in refs:
		var t := _text(str(refs[name]))
		_check("  %s 用了 AudioLevel" % name, t.contains("AudioLevel."))

	print("[level] 音乐实际增益")
	var m := _node("res://net/autoload/Music.gd", "Music")
	m.call("set_muted", false)
	m.call("set_volume", 0.55)
	var gain := float(m.call("_gain_db"))
	var want := linear_to_db(0.55 * master)
	_check("0.55 滑杆 -> %.2fdB" % want, is_equal_approx(gain, want), "实际 %.2fdB" % gain)
	_check("比校准前低了 trim_db", is_equal_approx(linear_to_db(0.55) - gain, -trim),
		"差 %.2fdB" % (linear_to_db(0.55) - gain))
	m.call("set_muted", true)
	_check("静音仍是 -80dB", is_equal_approx(float(m.call("_gain_db")), -80.0))
	m.call("set_muted", false)
	m.call("set_volume", 0.55)

	print("[level] 脚步实际增益")
	var sfx := _node("res://net/autoload/Sfx.gd", "Sfx")
	sfx.call("set_muted", false)
	sfx.call("set_volume", 0.7)
	sfx.call("set_indoor", true)        # 固定 wood，避开 Ground 材质判定
	sfx.call("footstep", Vector2(0, 0))
	var players: Array = sfx.get("_players")
	var nxt: int = int(sfx.get("_next"))
	var played: AudioStreamPlayer = players[(nxt - 1 + players.size()) % players.size()]
	var db := float(played.volume_db)
	# 真录音归一后还要乘 TIMBRE.level，合成音在 _synth 里已乘过
	var lvl := 0.90 if bool(sfx.call("using_samples", "wood")) else 1.0
	var hi := linear_to_db(0.7 * master * 1.0 * lvl)
	var lo := linear_to_db(0.7 * master * 0.86 * lvl)
	_check("脚步音量落在校准后的区间", db >= lo - 0.05 and db <= hi + 0.05,
		"实际 %.2fdB，期望 %.2f~%.2fdB" % [db, lo, hi])
	_check("脚步没有用未校准的音量", db < linear_to_db(0.7 * 0.86 * lvl) - 1.0,
		"实际 %.2fdB" % db)
	_check("确实播出了声音", played.playing)

	print("[level] 存档四栏互不覆盖")
	sfx.call("set_volume", 0.4)
	sfx.call("set_muted", false)
	m.call("set_volume", 0.35)          # Music 写盘后不该把 sfx 两栏冲掉
	m.call("set_muted", false)
	var cfg := ConfigFile.new()
	_check("audio.cfg 可读", cfg.load(CFG) == OK)
	_check("  音乐音量还在", is_equal_approx(float(cfg.get_value("audio", "music", -1.0)), 0.35))
	_check("  音效音量还在", is_equal_approx(float(cfg.get_value("audio", "sfx", -1.0)), 0.4),
		str(cfg.get_value("audio", "sfx", "缺失")))
	_check("  音效静音键还在", cfg.has_section_key("audio", "sfx_muted"))
	# 放回常态值，别把测试存档留成奇怪的数
	m.call("set_volume", 0.55)
	sfx.call("set_volume", 0.7)
