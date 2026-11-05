extends SceneTree
## 宠物存档端到端（三个进程轮流跑）：**存档真的躺在服务端**，不是靠客户端缓存蒙过去的。
##
## 三个进程轮流跑（同一台机器，用不同 APPDATA 隔开）：
##   1. XGD_PET_ROLE=host      → 开房 7656，一直等
##   2. XGD_PET_ROLE=client_a  → 加入，领养两只猫并推给服务端，然后退出
##   3. XGD_PET_ROLE=client_b  → **同一个 APPDATA（同一个 uid），但 adopted_cats.json 已被删掉**
##                               加入 → /pets → 应该原样拿回两只猫
##
## 只要第 3 步拿得回来，就说明猫不在本地文件里，在服务端。

const PORT := 7656

var net: Node = null
var role := ""
var t0 := 0
var done := false
var fails: Array[String] = []
var sent := false
var started := false
var checks := 0
var dumped := false
var t_push := 0


## 注意：_initialize() 跑在 autoload 的 _ready() **之前**，那时候 Net 还没进树，
## multiplayer 是 null，host_game/join_game 会直接报错。所以开房/加入都推迟到第一帧。
func _initialize() -> void:
	t0 = Time.get_ticks_msec()
	net = root.get_node_or_null("Net")
	role = OS.get_environment("XGD_PET_ROLE")
	if net == null or role.is_empty():
		print("结果 FAIL：缺 Net 或 XGD_PET_ROLE")
		quit(1)


func _start() -> void:
	started = true
	print("[%s] uid=%s" % [role, str(net.get("local_uid"))])
	match role:
		"host":
			var e: int = net.call("host_game", PORT)
			print("[host] host_game(%d) → %d" % [PORT, e])
		"client_a", "client_b":
			var e2: int = net.call("join_game", "127.0.0.1", PORT)
			print("[%s] join_game → %d" % [role, e2])


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _ms() -> int:
	return Time.get_ticks_msec() - t0


func _finish() -> bool:
	done = true
	if checks == 0 and role != "host":
		print("[%s] 结果 FAIL：一项都没验到，测试没跑起来" % role)
		quit(1)
		return true
	if fails.is_empty():
		print("[%s] 结果 PASS（%d 项）" % [role, checks])
		quit(0)
	else:
		print("[%s] 结果 FAIL：%s" % [role, ", ".join(fails)])
		quit(1)
	return true


func _process(_d: float) -> bool:
	if done:
		return true
	if not started:
		_start()
		return false
	if _ms() > 40000:
		print("[%s] 超时" % role)
		_finish()
		return true
	match role:
		"host":
			return _tick_host()
		"client_a":
			return _tick_a()
		"client_b":
			return _tick_b()
	return false


func _tick_host() -> bool:
	if _ms() % 5000 < 20:
		print("[host] 在线 %d 人" % (net.get("peers") as Dictionary).size())
	if not sent and _ms() > 600:
		sent = true
		_ok(net.call("is_server") == true, "自己成了主机")
		var ps: Dictionary = net.get("peers")
		var mine := false
		for id in ps:
			if str(ps[id].get("uid", "")) == str(net.get("local_uid")):
				mine = true
		_ok(mine, "名单里有自己", "人数 %d" % ps.size())
	# 30 秒时把落盘文件打出来，肉眼核对服务端到底存了什么
	if _ms() > 30000 and not dumped:
		dumped = true
		print("[host] 服务端宠物表 %s" % str(net.get("_pets")))
		if FileAccess.file_exists("user://pets.json"):
			var f := FileAccess.open("user://pets.json", FileAccess.READ)
			print("[host] user://pets.json = %s" % f.get_as_text())
			f.close()
			_ok(true, "pets.json 已落盘")
		else:
			_ok(false, "pets.json 已落盘")
		return _finish()
	return false


func _tick_a() -> bool:
	if not net.call("has_session"):
		return false
	if not sent:
		# 等名单里出现自己 —— 服务端要收到 _register 才知道这个 peer 是谁，
		# 早一步推存档会因为没有 uid 被静默丢掉，测试就会误判成「同步失败」。
		var me_uid := str(net.get("local_uid"))
		var known := false
		for id in (net.get("peers") as Dictionary):
			if str((net.get("peers") as Dictionary)[id].get("uid", "")) == me_uid:
				known = true
				break
		if not known and _ms() < 4000:
			return false
		sent = true
		print("[client_a] 服务端已登记（耗时 %d ms），推送两只猫" % _ms())
		t_push = _ms()
		net.call("pet_push", [
			{"name": "小煤球", "skin": 5, "pets": 12, "walk": true},
			{"name": "奶糖", "skin": 9, "pets": 7},
		])
		return false
	# Arena._ready 也会发一次 /pets，它的回包可能是推送**之前**的空表。
	# 两者顺序不保证，所以这里等到真正拿到 2 只（或 5 秒超时）再断言，
	# 否则测的是回包到达顺序，不是存档功能本身。
	if (net.get("my_pets") as Array).is_empty() and _ms() - t_push < 5000:
		return false
	if net.get("pets_synced") == true:
		var mp: Array = net.get("my_pets")
		_ok(mp.size() == 2, "服务端确认收到 2 只", str(mp))
		if mp.size() == 2:
			_ok(str(mp[0]["name"]) == "小煤球" and int(mp[1]["pets"]) == 7, "内容不变")
			_ok(bool(mp[0].get("walk", false)) == true, "牵绳状态一起存了")
		return _finish()
	return false


func _tick_b() -> bool:
	# 先确认本地缓存确实被删干净了（否则测的不是服务端）
	if not sent:
		if not net.call("has_session"):
			return false
		var me_uid := str(net.get("local_uid"))
		var known := false
		for id in (net.get("peers") as Dictionary):
			if str((net.get("peers") as Dictionary)[id].get("uid", "")) == me_uid:
				known = true
				break
		if not known and _ms() < 4000:
			return false
		sent = true
		_ok(not FileAccess.file_exists("user://adopted_cats.json"),
			"本地 adopted_cats.json 不存在（模拟重装/换机）")
		print("[client_b] 本地没有存档，向服务端要")
		t_push = _ms()
		net.call("pet_refresh")
		return false
	if (net.get("my_pets") as Array).is_empty() and _ms() - t_push < 5000:
		return false
	if net.get("pets_synced") == true:
		var mp: Array = net.get("my_pets")
		_ok(mp.size() == 2, "从服务端拿回 2 只猫", str(mp))
		if mp.size() == 2:
			_ok(str(mp[0]["name"]) == "小煤球", "第一只叫小煤球", str(mp[0]))
			_ok(int(mp[0]["skin"]) == 5 and int(mp[0]["pets"]) == 12, "花色/亲密都对")
			_ok(bool(mp[0].get("walk", false)) == true, "牵绳状态还在")
			_ok(str(mp[1]["name"]) == "奶糖" and int(mp[1]["skin"]) == 9, "第二只叫奶糖")
		return _finish()
	return false
