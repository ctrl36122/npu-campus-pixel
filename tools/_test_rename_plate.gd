extends SceneTree
## 改名后宿舍名牌 / 输入框打字不抢全局快捷键 —— 回归测试。
##
## 背景：门牌读的是 room_claims 里「认领那一刻写死的名字快照」，而改昵称只改了
## 在线名单 + 没更新 Net.local_name；存档和重新认领又都用 local_name，于是牌子
## 一直挂着首次进游戏随机生成的昵称。另一个坑是中文输入法组合期按键会穿到
## _unhandled_input，打个 m 就呼出地图。
##
## 用临时 APPDATA 隔离（Net._ready 会读写 user://xgd_uid.cfg）：
##   APPDATA=<临时目录> godot --headless --script res://tools/_test_rename_plate.gd
## 故意不设 XGD_OFFLINE：has_session() 为 false，改名/认领都走纯本地分支，
## 不会真发 RPC，不依赖服务端。

var net: Node = null
var step := 0
var fails: Array[String] = []
var checks := 0
var changed := 0
const UID := "test-uid-rename"


func _initialize() -> void:
	net = root.get_node_or_null("Net")
	if net == null:
		print("结果 FAIL：Net autoload 没加载")
		quit(1)
		return
	net.connect("room_claims_changed", func() -> void: changed += 1)


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _seed() -> void:
	net.local_uid = UID
	net.local_name = "航空同学07"
	net.room_claims = {
		"3:2": {"name": "航空同学07", "uid": UID, "note": "门口公告别丢"},
		"6:0": {"name": "演示队", "uid": UID + "@team"},
		"3:4": {"name": "别的同学", "uid": "other-uid"},
	}
	net.my_room_cache = {"floor": 3, "index": 2, "name": "航空同学07", "note": "门口公告别丢"}
	net.my_team_cache = {"index": 0, "name": "演示队", "note": ""}
	net.void_claim = ""
	changed = 0


func _process(_d: float) -> bool:
	step += 1
	if step == 2:
		_test_rename()
		_test_restore()
		_test_no_claim()
		_test_typing()
	elif step == 4:
		print("---- 汇总 ----")
		if fails.is_empty():
			print("结果 PASS：改名名牌 + 输入焦点 %d 项全过" % checks)
		else:
			print("结果 FAIL：%d 项 —— %s" % [fails.size(), ", ".join(fails)])
		quit(0 if fails.is_empty() else 1)
		return true
	return false


func _test_rename() -> void:
	_seed()
	net.set_my_name("羞羞")
	_ok(net.local_name == "羞羞", "local_name 跟着改名", net.local_name)
	var mine: Dictionary = net.room_claims.get("3:2", {})
	_ok(String(mine.get("name", "")) == "羞羞", "自己门牌的名字快照更新", str(mine.get("name", "")))
	_ok(String(mine.get("note", "")) == "门口公告别丢", "门口公告没被冲掉", str(mine.get("note", "")))
	_ok(String(net.my_room_cache.get("name", "")) == "羞羞", "本地镜像换成新昵称")
	_ok(String(net.room_claims["6:0"]["name"]) == "演示队", "B1 组队板队名不受影响")
	_ok(String(net.room_claims["3:4"]["name"]) == "别的同学", "别人的房没被改")
	_ok(net.claim_of_uid(UID) == "3:2", "认领关系没被搬走")
	_ok(changed >= 1, "room_claims_changed 已广播（门牌会刷新）", "次数=%d" % changed)
	var before := changed
	net.set_my_name("羞羞")
	_ok(changed == before, "同名再设一次不重复发包", "次数=%d→%d" % [before, changed])


func _test_restore() -> void:
	_seed()
	net.set_my_name("羞羞")
	# 模拟服务端广播还挂着旧昵称（旧服务端 / 改名请求没赶上那次快照）
	net.room_claims["3:2"]["name"] = "航空同学07"
	net._restore_cached_claim()
	_ok(String(net.room_claims["3:2"]["name"]) == "羞羞", "重连后旧快照被本地镜像纠正")


func _test_no_claim() -> void:
	net.local_uid = UID
	net.room_claims = {}
	net.my_room_cache = {}
	net.my_team_cache = {}
	net.void_claim = ""
	changed = 0
	net.set_my_name("新名字")
	_ok(net.local_name == "新名字", "没认领房间时改名不炸")
	_ok(net.room_claims.is_empty(), "没认领房间不会凭空造出牌子")
	_ok(changed == 0, "没认领房间时不发无意义的刷新")


func _test_typing() -> void:
	var vp := root
	var le := LineEdit.new()
	vp.add_child(le)
	le.grab_focus()
	_ok(vp.gui_get_focus_owner() == le, "LineEdit 能拿到焦点（前置）")
	_ok(GameTheme.is_typing(vp), "焦点在 LineEdit 时判定为正在打字")
	var te := TextEdit.new()
	vp.add_child(te)
	te.grab_focus()
	_ok(GameTheme.is_typing(vp), "焦点在 TextEdit 时判定为正在打字")
	var btn := Button.new()
	vp.add_child(btn)
	btn.grab_focus()
	_ok(not GameTheme.is_typing(vp), "焦点在普通按钮时快捷键照常")
	# 面板收起后焦点还挂在隐藏输入框上，也不能把整局快捷键锁死
	le.grab_focus()
	le.visible = false
	_ok(not GameTheme.is_typing(vp), "隐藏的输入框不算正在打字")
	le.free()
	te.free()
	btn.free()
