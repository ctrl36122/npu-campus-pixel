extends SceneTree
## 「走在路上忽然卡死动不了」回归测试。
##
## 三条独立的成因，都和碰撞无关：
##   1. PlayerInput.sample 只判断焦点控件是不是 LineEdit/TextEdit，不看可见性。
##      面板收起后焦点仍挂在隐藏输入框上 → 方向恒为零。
##   2. chat / online_boot 各自直接写 PlayerAvatar.ui_blocked 一个 bool，
##      多个面板互相覆盖，或某个置 true 的分支漏了置 false → 永久冻结。
##   3. 校园分支拿 `buffer.entries.size() < CAPACITY` 当采样闸门：服务端确认
##      停更约 2 秒后缓冲塞满，连输入都不再采样，本地预测也停 → 人定住。
##
## 用临时 APPDATA 隔离（Net._ready 会读写 user://xgd_uid.cfg），故意**不设**
## XGD_OFFLINE：has_session() 为 false，_on_tick 只跑「本地采样 + 预测」这条路径，
## 不联网、不依赖服务端。
##
##   APPDATA=<临时目录> godot --headless --script res://tools/_test_move_stall.gd

const GameThemeScript := preload("res://scripts/ui/theme.gd")
const PlayerInputScript := preload("res://net/scripts/player/PlayerInput.gd")
const InputBufferScript := preload("res://net/scripts/player/InputBuffer.gd")

## Player.tscn 里的 PlayerAvatar.gd 直接引用 Net / NetTick / GameState 这些 autoload。
## --script 模式在脚本解析阶段还没把 autoload 注册成全局标识符，preload 会编译失败
## （Identifier not found: Net），所以必须等第一帧、autoload 就绪后再 load()。
class FakeAvatar extends Node2D:
	var round_id: int = 0

var checks := 0
var fails: Array[String] = []
var done := false


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _process(_d: float) -> bool:
	if done:
		return true
	done = true
	_run()
	if fails.is_empty():
		print("结果 PASS：移动卡死回归 %d 项全过" % checks)
		quit(0)
	else:
		print("结果 FAIL：%s" % ", ".join(fails))
		quit(1)
	return true


func _run() -> void:
	GameThemeScript.clear_move_blocks()
	var probe := FakeAvatar.new()
	root.add_child(probe)

	# ---- 1) 输入框焦点：可见时才冻结，隐藏后必须放行 ----
	var edit := LineEdit.new()
	root.add_child(edit)
	edit.show()
	edit.grab_focus()
	_ok(GameThemeScript.is_typing(root), "可见 LineEdit 判为正在输入")
	edit.hide()
	_ok(not GameThemeScript.is_typing(root), "隐藏 LineEdit 不再判为正在输入")
	root.remove_child(edit)
	edit.queue_free()

	var pi := PlayerInputScript.new()
	pi.bot_driven = false
	var edit2 := LineEdit.new()
	root.add_child(edit2)
	Input.action_press("move_right")
	_ok(Input.is_action_pressed("move_right"), "headless 输入动作可用")
	var c_visible: Dictionary
	var c_hidden: Dictionary
	edit2.show()
	edit2.grab_focus()
	c_visible = pi.sample(probe, 1, 1)
	edit2.hide()
	c_hidden = pi.sample(probe, 2, 2)
	Input.action_release("move_right")
	_ok(absf(float(c_hidden.get("x", 0.0))) > 0.5,
		"隐藏输入框残留焦点时方向键仍然生效", "x=%.2f" % float(c_hidden.get("x", 0.0)))
	_ok(absf(float(c_visible.get("x", 0.0))) < 0.01,
		"可见输入框里打字时方向键被冻结", "x=%.2f" % float(c_visible.get("x", 0.0)))
	root.remove_child(edit2)
	edit2.queue_free()

	# ---- 2) 多来源冻结：关掉一个不能把另一个一起解除 ----
	GameThemeScript.clear_move_blocks()
	_ok(not GameThemeScript.is_move_blocked(), "初始无冻结")
	GameThemeScript.set_move_blocked("map", true)
	GameThemeScript.set_move_blocked("chat", true)
	_ok(GameThemeScript.is_move_blocked(), "两个来源都开着 -> 冻结")
	GameThemeScript.set_move_blocked("map", false)
	_ok(GameThemeScript.is_move_blocked(), "关地图后聊天仍开着 -> 仍冻结")
	GameThemeScript.set_move_blocked("chat", false)
	_ok(not GameThemeScript.is_move_blocked(), "两个来源都关 -> 解冻")

	# 面板隐藏 / 销毁时自动失效（关闭事件漏发也兜得住）
	var panel := Control.new()
	root.add_child(panel)
	panel.show()
	GameThemeScript.set_move_blocked("settings", true, panel)
	_ok(GameThemeScript.is_move_blocked(), "带节点的来源开着 -> 冻结")
	panel.hide()
	_ok(not GameThemeScript.is_move_blocked(), "面板隐藏后来源自动失效 -> 解冻")
	root.remove_child(panel)
	panel.queue_free()
	GameThemeScript.clear_move_blocks()

	# ---- 3) 缓冲塞满：InputBuffer 容量与 drop_oldest ----
	var b := InputBufferScript.new()
	for i in 70:
		b.push({"seq": i + 1, "x": 1.0, "y": 0.0, "round": 0}, Vector2(i, 0))
	_ok(b.entries.size() == InputBufferScript.CAPACITY,
		"缓冲写入超过容量仍不越界", "size=%d" % b.entries.size())
	var oldest := int(b.entries.front()["command"]["seq"])
	b.drop_oldest()
	b.push({"seq": 71, "x": 1.0, "y": 0.0, "round": 0}, Vector2.ZERO)
	_ok(b.entries.size() == InputBufferScript.CAPACITY and
		int(b.entries.front()["command"]["seq"]) == oldest + 1 and
		int(b.entries.back()["command"]["seq"]) == 71,
		"drop_oldest 丢最老一条并接纳新命令")

	# ---- 4) 真实 PlayerAvatar：预填满缓冲后仍继续采样 / 预测 ----
	var gs := root.get_node_or_null("GameState")
	if gs != null:
		gs.phase = 1          # GameState.Phase.IN_RUN（LOBBY=0 / IN_RUN=1 / ENDED=2）
	var scene: Resource = load("res://net/scenes/Player.tscn")
	if scene == null:
		_ok(false, "Player.tscn 可加载（autoload 就绪后）")
		return
	var a: Node = scene.instantiate()
	root.add_child(a)
	var nt := root.get_node_or_null("NetTick")
	if nt != null and nt.network_tick.is_connected(Callable(a, "_on_tick")):
		nt.network_tick.disconnect(Callable(a, "_on_tick"))
	a.set("is_local_player", true)
	a.set("_room_freeze", false)
	if a.get("buffer") == null:
		_ok(false, "PlayerAvatar 脚本已挂载（buffer 可读）")
		root.remove_child(a)
		a.queue_free()
		return
	for i in InputBufferScript.CAPACITY:
		a.buffer.push({"seq": i + 1, "x": 0.0, "y": 0.0, "round": a.round_id}, Vector2.ZERO)
	a.next_seq = InputBufferScript.CAPACITY + 1
	var p0: Vector2 = a.position
	var seq0: int = a.next_seq
	Input.action_press("move_right")
	for t in 10:
		a._on_tick(100 + t)
	Input.action_release("move_right")
	_ok(a.next_seq > seq0, "缓冲塞满后仍继续采样输入",
		"seq %d -> %d" % [seq0, a.next_seq])
	_ok(a.position.x > p0.x + 1.0, "缓冲塞满后人物仍在移动",
		"x %.1f -> %.1f" % [p0.x, a.position.x])
	_ok(a.buffer.entries.size() == InputBufferScript.CAPACITY,
		"缓冲塞满后容量稳定不增长", "size=%d" % a.buffer.entries.size())
	_ok(a.ui_blocked == false, "无冻结来源时 ui_blocked 不会残留 true")
	root.remove_child(a)
	a.queue_free()
	root.remove_child(probe)
	probe.queue_free()
