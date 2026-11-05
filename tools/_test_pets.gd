extends SceneTree
## 宠物表（服务端权威领养存档）单元测试 —— 只碰 Net 层 + Arena 的读写函数。
##
## 为什么必须有 APPDATA 隔离：这个测试会写 user://pets.json 和
## user://adopted_cats.json，直接跑会把玩家真存档覆盖掉（真出过事）。
##   APPDATA=<临时目录> XGD_OFFLINE=1 godot --headless --script res://tools/_test_pets.gd

var net: Node = null
var step := 0
var fails: Array[String] = []
var changed := 0
var checks := 0
var msgs := 0
var last_msg := ""


func _initialize() -> void:
	net = root.get_node_or_null("Net")
	if net == null:
		print("结果 FAIL：Net autoload 没加载")
		quit(1)
		return
	net.connect("pets_changed", func() -> void: changed += 1)
	net.connect("message_received", func(_who: String, what: String) -> void:
		msgs += 1
		last_msg = what)


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _process(_d: float) -> bool:
	step += 1
	if step == 2:
		_test_sanitize()
		_test_reject()
		_test_apply()
	elif step == 4:
		_test_host()
	elif step == 8:
		_test_push()
	elif step == 12:
		_test_file()
	elif step == 14:
		_test_long()
	elif step == 18:
		_test_reread()
	elif step == 19:
		_test_degrade()
	elif step == 20:
		_test_pack()
	elif step == 24:
		_test_migrate()
	elif step == 28:
		print("---- 汇总 ----")
		if fails.is_empty():
			print("结果 PASS：宠物表 %d 项全过" % checks)
		else:
			print("结果 FAIL：%d 项 —— %s" % [fails.size(), ", ".join(fails)])
		quit(0 if fails.is_empty() else 1)
		return true
	return false


# ---------------------------------------------------------------- 清洗
func _test_sanitize() -> void:
	print("[1] _sanitize_pets 清洗")
	var raw := [
		{"name": "ABCDEFGHIJKLMNOPQRST", "skin": 999, "pets": -5, "walk": true, "hack": "x"},
		{"name": "  小煤球  ", "skin": 7, "pets": 12},
		{"name": "第三只应该被砍掉", "skin": 1, "pets": 1},
		"不是字典",
	]
	var out: Array = net.call("_sanitize_pets", raw)
	_ok(out.size() == 2, "3 只 + 1 条脏数据 → 留 2 只", "实际 %d" % out.size())
	var a: Dictionary = out[0]
	_ok(a["name"].length() == 12, "名字卡 12 字", "实际 %d 字「%s」" % [a["name"].length(), a["name"]])
	_ok(int(a["skin"]) == 63, "skin 999 → 63", "实际 %d" % int(a["skin"]))
	_ok(int(a["pets"]) == 0, "pets -5 → 0", "实际 %d" % int(a["pets"]))
	_ok(bool(a.get("walk", false)) == true, "walk 透传")
	_ok(not a.has("hack"), "未知字段被丢掉")
	var b: Dictionary = out[1]
	_ok(str(b["name"]) == "小煤球", "名字去空白", "实际「%s」" % str(b["name"]))
	_ok(int(b["skin"]) == 7 and int(b["pets"]) == 12, "正常值原样保留")
	_ok(not b.has("walk"), "没牵绳就不写 walk 字段")
	# 空名字兜底
	var e: Array = net.call("_sanitize_pets", [{"name": "   "}])
	_ok(e.size() == 1 and str(e[0]["name"]) == "猫咪", "空名字兜底成「猫咪」")


# ---------------------------------------------------------------- 旧服务端话术
func _test_reject() -> void:
	print("[2] 旧服务端拒绝话术")
	_ok(net.call("_is_pet_reject", "没有这个命令：/pets（/help 查看）") == true, "「没有这个命令：/pets」识别为拒绝")
	_ok(net.call("_is_pet_reject", "没有这个命令：/dm") == false, "别的命令不误判")
	_ok(net.call("_is_pet_reject", "你好呀 /pets") == false, "普通聊天不误判")


# ---------------------------------------------------------------- 回包解析
func _test_apply() -> void:
	print("[3] _apply_pets 回包解析")
	_ok(bool(net.call("_apply_pets", "普通聊天")) == false, "非宠物串返回 false")
	_ok(net.get("pets_synced") == false, "还没同步过")
	var before := changed
	var got: bool = net.call("_apply_pets", '@PETS|[{"name":"小煤球","skin":5,"pets":12,"walk":true}]')
	_ok(got == true, "@PETS| 前缀被认下")
	_ok(changed == before + 1, "发了 pets_changed 信号")
	_ok(net.get("pets_synced") == true, "pets_synced 置 true")
	var mp: Array = net.get("my_pets")
	_ok(mp.size() == 1 and str(mp[0]["name"]) == "小煤球", "my_pets 解析正确", str(mp))
	# 坏 JSON 不能崩
	_ok(bool(net.call("_apply_pets", "@PETS|{坏掉的")) == true, "坏 JSON 也当宠物回包吞掉")
	_ok(net.get("my_pets") is Array, "坏 JSON 后 my_pets 仍是数组")


# ---------------------------------------------------------------- 当主机
func _test_host() -> void:
	print("[4] 起本地房（7656）")
	net.call("host_game", 7656)
	_ok(net.call("is_server") == true, "自己成了主机")


func _test_push() -> void:
	print("[5] 主机 pet_push 落盘")
	var before := changed
	net.call("pet_push", [{"name": "奶糖", "skin": 9, "pets": 7}])
	_ok(changed > before, "push 后有回包（pets_changed 触发）")
	var mp: Array = net.get("my_pets")
	_ok(mp.size() == 1 and str(mp[0]["name"]) == "奶糖", "my_pets 换成奶糖", str(mp))
	var ps: Dictionary = net.get("_pets")
	var uid: String = str(net.get("local_uid"))
	_ok(ps.has(uid), "服务端表里有自己的 uid", uid)
	var rec: Array = ps.get(uid, [])
	_ok(rec.size() == 1 and int(rec[0]["skin"]) == 9, "服务端存的是清洗后的记录")
	# pets 累加后 push 也要保存
	net.call("pet_push", [{"name": "奶糖", "skin": 9, "pets": 8, "walk": true}])
	var rec2: Array = (net.get("_pets") as Dictionary).get(uid, [])
	_ok(rec2.size() == 1 and int(rec2[0]["pets"]) == 8 and bool(rec2[0].get("walk", false)),
		"再存一次覆盖成功（pets=8, walk=true）")


func _test_file() -> void:
	print("[6] user://pets.json 落盘")
	var path := "user://pets.json"
	_ok(FileAccess.file_exists(path), "文件已生成", ProjectSettings.globalize_path(path))
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	_ok(parsed is Dictionary, "内容是 JSON 对象")
	var uid: String = str(net.get("local_uid"))
	if parsed is Dictionary:
		_ok((parsed as Dictionary).has(uid), "文件里有自己的 uid")
		var rec: Array = (parsed as Dictionary).get(uid, [])
		_ok(rec.size() == 1 and str(rec[0]["name"]) == "奶糖", "文件里是奶糖")


func _test_long() -> void:
	print("[7] 超长存档不发（防截断）")
	# 直接调 pet_push 前构造两条超长名字的数据，看会不会被 clean 压到 12 字（正常压得住）
	var uids_before := (net.get("_pets") as Dictionary).size()
	net.call("pet_push", [
		{"name": "一二三四五六七八九十一二三四五六", "skin": 3, "pets": 1},
		{"name": "第二只猫也是一个很长的名字啊啊", "skin": 4, "pets": 2},
	])
	var rec: Array = (net.get("_pets") as Dictionary).get(str(net.get("local_uid")), [])
	_ok(rec.size() == 2, "两只都存下（名字被压到 12 字）", "实际 %d" % rec.size())
	if rec.size() == 2:
		_ok(str(rec[0]["name"]).length() == 12, "第一只名字 12 字")
		_ok(str(rec[1]["name"]).length() == 12, "第二只名字 12 字")


# ---------------------------------------------------------------- 重进（模拟重开客户端）
func _test_reread() -> void:
	print("[8] 重进：从磁盘读回")
	# 清掉内存里的服务端表，模拟进程重启后再载入
	net.set("_pets", {})
	net.set("_pets_loaded", false)
	net.set("my_pets", [])
	net.set("pets_synced", false)
	net.call("_load_pets")
	var ps: Dictionary = net.get("_pets")
	var uid: String = str(net.get("local_uid"))
	_ok(ps.has(uid), "磁盘读回后仍有自己的 uid")
	net.call("pet_refresh")
	var mp: Array = net.get("my_pets")
	_ok(net.get("pets_synced") == true, "refresh 后 pets_synced=true")
	_ok(mp.size() == 2, "拿回 2 只猫", str(mp))
	if mp.size() == 2:
		_ok(str(mp[0]["name"]).length() == 12 and int(mp[1]["skin"]) == 4, "内容与落盘一致")


# ---------------------------------------------------------------- 旧服务端降级
func _test_degrade() -> void:
	print("[9] 旧服务端降级：回包不进聊天框")
	var before := msgs
	net.call("_relay_message", "[系统]", "没有这个命令：/pets（/help 查看）")
	_ok(msgs == before, "「没有这个命令：/pets」没进聊天框")
	_ok(net.get("pets_synced") == true, "pets_synced 不被这句改回去")
	# 宠物回包也不进聊天框
	before = msgs
	net.call("_relay_message", "[系统]", '@PETS|[]')
	_ok(msgs == before, "@PETS| 回包没进聊天框")
	_ok((net.get("my_pets") as Array).is_empty(), "空表也照实换成空（真没猫）")
	# PET_ERR 要给用户看到（存档没存上是真问题）
	before = msgs
	net.call("_relay_message", "[系统]", "@PETERR|存档格式不对")
	_ok(msgs == before + 1, "PET_ERR 提示进了一条")
	_ok(last_msg.begins_with("宠物存档没存上"), "提示文案对", "「%s」" % last_msg)
	# 普通聊天照常
	before = msgs
	net.call("_relay_message", "小明", "图书馆门口等你")
	_ok(msgs == before + 1 and last_msg == "图书馆门口等你", "普通聊天不受影响")


# ---------------------------------------------------------------- 缓存格式 / 迁移
func _arena() -> Node:
	for n in root.find_children("*", "Node2D", true, false):
		if n.has_method("pet_info") and n.has_method("_read_adopted_pack"):
			return n
	return null


func _write_raw(path: String, txt: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(txt)
	f.close()


func _test_pack() -> void:
	print("[10] 本地缓存格式（新老两种都要认）")
	var a := _arena()
	_ok(a != null, "找到 Arena 节点")
	if a == null:
		return
	# 老格式：裸数组
	_write_raw("user://adopted_cats.json", '[{"name":"老猫","skin":2,"pets":9}]')
	var p: Dictionary = a.call("_read_adopted_pack")
	_ok((p["cats"] as Array).size() == 1 and str((p["cats"] as Array)[0]["name"]) == "老猫",
		"老格式（裸数组）读得出猫")
	_ok(p["synced"] == false, "老格式判定为「从没同步过」")
	# 新格式
	_write_raw("user://adopted_cats.json",
		'{"cats":[{"name":"新猫","skin":3,"pets":1}],"synced":true}')
	p = a.call("_read_adopted_pack")
	_ok((p["cats"] as Array).size() == 1 and str((p["cats"] as Array)[0]["name"]) == "新猫",
		"新格式读得出猫")
	_ok(p["synced"] == true, "新格式 synced=true 认得出")
	# 坏文件
	_write_raw("user://adopted_cats.json", "{不是 JSON")
	p = a.call("_read_adopted_pack")
	_ok((p["cats"] as Array).is_empty() and p["synced"] == true, "坏文件不炸、也不反复迁移")
	_ok(a.call("_read_adopted_file") is Array, "兼容老接口 _read_adopted_file")


func _test_migrate() -> void:
	print("[11] 迁移规则：没同步过的老存档才推，synced 的不回灌")
	var a := _arena()
	if a == null:
		_ok(false, "Arena 不在，迁移测不了")
		return
	var uid: String = str(net.get("local_uid"))

	# (a) 老格式 + 服务端空 → 应该把本地猫推上去
	_write_raw("user://adopted_cats.json", '[{"name":"老猫","skin":2,"pets":9}]')
	(net.get("_pets") as Dictionary).erase(uid)
	net.set("my_pets", [])
	net.set("pets_synced", true)
	a.set("_adopt_loaded", false)
	a.set("_pet_migrated", false)
	a.set("_adopted", [])
	a.call("_on_pets_changed")
	var rec: Array = (net.get("_pets") as Dictionary).get(uid, [])
	_ok(rec.size() == 1 and str(rec[0]["name"]) == "老猫", "老玩家的猫被推上服务端", str(rec))

	# 推完之后服务端回包 → my_pets 有两只是上一轮留下的，这里手动造一次回包
	net.call("_apply_pets", "@PETS|" + JSON.stringify(rec))
	_ok((a.get("_adopted") as Array).size() == 1, "回包后 Arena 换成服务端那份")

	# 「已迁移」标记要能挡住重复推送：服务端还说空、本地还是老格式，但不再推
	_write_raw("user://adopted_cats.json", '[{"name":"老猫","skin":2,"pets":9}]')
	(net.get("_pets") as Dictionary).erase(uid)
	net.set("my_pets", [])
	a.set("_pet_migrated", true)
	a.call("_on_pets_changed")
	_ok(not (net.get("_pets") as Dictionary).has(uid), "_pet_migrated 挡住重复推送")
	a.set("_pet_migrated", false)

	# (b) synced=true 的缓存 + 服务端空 → 不许回灌
	_write_raw("user://adopted_cats.json",
		'{"cats":[{"name":"过期猫","skin":4,"pets":3}],"synced":true}')
	(net.get("_pets") as Dictionary).erase(uid)
	net.set("my_pets", [])
	a.set("_adopt_loaded", false)
	a.set("_pet_migrated", false)
	a.set("_adopted", [])
	a.call("_on_pets_changed")
	_ok(not (net.get("_pets") as Dictionary).has(uid),
		"synced 的过期缓存没有回灌到服务端")
	_ok((a.get("_adopted") as Array).is_empty(), "Arena 跟着服务端变空（你在别处删了猫）")

	# (c) 服务端有数据时一律以服务端为准
	net.call("_apply_pets", '@PETS|[{"name":"服务端的猫","skin":6,"pets":2}]')
	_ok((a.get("_adopted") as Array).size() == 1
		and str((a.get("_adopted") as Array)[0]["name"]) == "服务端的猫",
		"服务端有猫时用服务端那份")
	var pack: Dictionary = a.call("_read_adopted_pack")
	_ok(pack["synced"] == true, "回写缓存时 synced=true")
	_ok((pack["cats"] as Array).size() == 1, "磁盘缓存也更新了")
