extends SceneTree
## 禁言 / 分级处置端到端：在离线本地主机上直接调 post_message，
## 验证 Lv3 拦截、Lv1/Lv2 等长打码、白名单、刷屏窗口与复读、/muted 名单、/mute /unmute。
## 写 user://chat_log.json 会落到临时 APPDATA，必须用隔离目录跑：
##   APPDATA=<临时目录> XGD_OFFLINE=1 XGD_NOHOME=1 godot --headless --script res://tools/_test_chat_mod_e2e.gd

const ChatGuard := preload("res://net/chat_guard.gd")

var checks := 0
var fails: Array[String] = []
var boot
var net
var seen: Array[String] = []
var frames := 0
var finished := false


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _on_msg(_speaker: String, text: String) -> void:
	seen.append(text)


func _initialize() -> void:
	boot = load("res://scenes/online_boot.tscn").instantiate()
	root.add_child(boot)
	net = root.get_node_or_null("Net")
	if net == null:
		print("结果 FAIL：Net autoload 没找到")
		finished = true
		quit(1)
		return
	net.message_received.connect(_on_msg)


func _process(_d: float) -> bool:
	if finished:
		return true
	frames += 1
	# 等 online_boot 把本地主机会话建起来（peers 里有自己）
	if net.peers.size() == 0 or not net.is_server():
		if frames > 6000:
			print("结果 FAIL：等不到本地会话（peers=%d）" % net.peers.size())
			finished = true
			quit(1)
		return false
	_run()
	finished = true
	if fails.is_empty():
		print("结果 PASS：禁言 / 分级处置 %d 项全过" % checks)
		quit(0)
	else:
		print("结果 FAIL：%s" % ", ".join(fails))
		quit(1)
	return true


func _reset() -> void:
	seen.clear()
	net._muted = {}
	net._msg_history = {}
	net._text_history = {}
	# 别去读/污染真实聊天存档：把内存里的日志当成一份干净的空表
	net._chat_loaded = true
	net._chat_log = []


func _post(t: String) -> void:
	net.call("post_message", t)


func _has(sub: String) -> bool:
	for s in seen:
		if s.find(sub) >= 0:
			return true
	return false


func _last_log() -> String:
	if (net._chat_log as Array).is_empty():
		return ""
	return String((net._chat_log as Array)[(net._chat_log as Array).size() - 1].get("m", ""))


func _run() -> void:
	var uid := String(net.peers[net.my_id()].get("uid", ""))
	var myname := String(net.peers[net.my_id()].get("name", ""))
	var now := Time.get_ticks_msec()

	print("[1] Lv3 严重违规：整条不转发")
	_reset()
	_post("一起赌博吧")
	_ok((net._chat_log as Array).is_empty(), "Lv3 不落盘")
	_ok(not seen.has("一起赌博吧"), "Lv3 原文不进聊天框")
	_ok(_has("严重违规"), "发送者收到 BLOCK 原因")

	print("[2] Lv2 / Lv1 等长打码后照发")
	_reset()
	_post("你这个傻逼")
	_ok(seen.has("你这个**"), "Lv2 打码后广播", _last_log())
	_ok(not _has("傻逼"), "原文没漏出去")
	_ok(_last_log() == "你这个**", "落盘的也是打码文本")
	_reset()
	_post("代练吗")
	_ok(seen.has("**吗"), "Lv1 引流也打码", _last_log())
	_reset()
	_post("明天操场见")
	_ok(seen.has("明天操场见"), "白名单/正常句子原样发送")

	print("[3] 超长截断（服务端兜底）")
	_reset()
	_post("a".repeat(400))
	_ok(_last_log().length() == ChatGuard.MAX_TEXT_LENGTH,
		"落盘截到 %d 字" % ChatGuard.MAX_TEXT_LENGTH, str(_last_log().length()))

	print("[4] 刷屏：间隔 / 窗口 / 复读")
	_reset()
	_post("第一条")
	_post("第二条")
	_ok(not seen.has("第二条"), "间隔过短的第二条被拦")
	_ok(_has("放慢语速"), "给了刷屏原因")
	_reset()
	var window: Array = []
	for i in range(ChatGuard.MAX_MSG_PER_WINDOW):
		window.append(now - 10000 + i * 100)
	net._msg_history[uid] = window
	_post("窗口满了")
	_ok(not seen.has("窗口满了"), "60s 窗口内条数满了会拦")
	_reset()
	net._msg_history[uid] = [now - 5000]
	net._text_history[uid] = ["复读", "复读", "复读"]
	_post("复读")
	_ok(not seen.has("复读"), "连续重复内容被拦")
	_ok(_has("重复"), "给了复读原因")

	print("[5] 禁言名单 / 手动禁言")
	_reset()
	_post("/muted")
	_ok(_has("没有禁言中的玩家"), "/muted 空名单提示")
	_post("/mute " + myname)
	_ok((net._muted as Dictionary).has(uid), "/mute 按 uid 记禁言", uid)
	seen.clear()
	net._msg_history = {}
	net._text_history = {}
	_post("禁言后还能说话吗")
	_ok((net._chat_log as Array).is_empty(), "禁言后消息不落盘")
	_ok(_has("@MUTED"), "收到 @MUTED 回执")
	seen.clear()
	_post("/muted")
	_ok(_has("禁言中 1 人"), "/muted 能列出被禁言的人")
	_post("/unmute " + myname)
	_ok(not (net._muted as Dictionary).has(uid), "/unmute 解除禁言")
	seen.clear()
	net._msg_history = {}
	net._text_history = {}
	_post("解禁了")
	_ok(seen.has("解禁了"), "解禁后能正常发言")

	print("[6] 前后兼容：私信与表情通道没被误伤")
	_reset()
	_post("@DM|u1|u2|你好")
	_ok(not seen.has("@DM|u1|u2|你好"), "私信原文不进公屏")
	_ok((net._chat_log as Array).is_empty(), "私信不落公共聊天记录")
