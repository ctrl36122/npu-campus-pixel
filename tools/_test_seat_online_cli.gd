extends SceneTree
## 联机抽搐复现（headless 客户端，连专用 WebSocket 服务器）：
##   连 127.0.0.1:9080 → 坐到校园长椅 → 按 E 起身 → 之后逐帧记录本机角色位置
##   （不按键 + 按住方向键各测一段），检测是否来回抽搐（位置反复反向 = 抖动）。
##
## 用法：先起 _test_seat_srv.gd（带 --server 旗标），再跑本脚本。

var arena
var avatar
var stage := 0
var clock := 0.0
var seats := []
var samples := []
var sample_clock := 0.0
var fail_flips := 0
var _dt := 0.0

func _initialize() -> void:
	OS.set_environment("XGD_SERVER", "ws://127.0.0.1:9080/ws")
	OS.set_environment("XGD_NOHOME", "1")
	root.add_child(load("res://scenes/online_boot.tscn").instantiate())

func _process(delta) -> bool:
	_dt = delta
	clock += delta
	if arena == null:
		var sf = root.get_node_or_null("SessionFlow")
		if sf != null and sf.get("world") != null:
			arena = sf.get("world")
		return false
	if avatar == null:
		for n in root.find_children("*", "CharacterBody2D", true, false):
			if bool(n.get("is_local_player")):
				avatar = n
		return false

	# 找校园长椅（不进宿舍，这样 _room_freeze=false，客户端会走 reconcile，抽搐才会出现）
	if stage == 0 and clock > 2.5:
		seats = arena.get("_seats_campus")
		var bench = {}
		for s in seats:
			if String(s["kind"]) == "bench":
				bench = s
				break
		if bench.is_empty():
			print("[cli][FAIL] 校园里找不到长椅")
			quit(1)
			return true
		print("[cli] 坐到长椅 @ %s" % bench["pos"])
		_net().call("sit_down", 1, bench["pos"])
		stage = 1
		clock = 0.0
	elif stage == 1 and clock > 0.6:
		print("[cli] 按 E 起身……")
		_net().call("sit_down", 0, Vector2.ZERO)
		stage = 2
		clock = 0.0
	elif stage == 2 and clock > 0.3:
		_begin_sample("起身不按键")
		stage = 3
		clock = 0.0
	elif stage == 3 and clock < 1.5:
		_sample()
	elif stage == 3 and clock >= 1.5:
		_end_sample()
		Input.action_press("move_right")
		_begin_sample("起身按右键")
		stage = 4
		clock = 0.0
	elif stage == 4 and clock < 1.5:
		_sample()
	elif stage == 4 and clock >= 1.5:
		_end_sample()
		Input.action_release("move_right")
		print("[cli] 结果：方向反转次数触发判定 %d（0 = 无抽搐）" % fail_flips)
		quit(0 if fail_flips == 0 else 1)
		return true
	return false

func _begin_sample(label: String) -> void:
	samples.clear()
	sample_clock = 0.0
	print("[cli] --- 采样：%s ---" % label)

func _sample() -> void:
	samples.append(avatar.position)
	sample_clock += _dt
	if sample_clock >= 0.1:
		sample_clock = 0.0
		var p: Vector2 = avatar.position
		print("   t=%.2f  pos=(%.1f, %.1f)  sit_dir=%d" % [clock, p.x, p.y, int(avatar.get("sit_dir"))])

func _end_sample() -> void:
	var flips := 0
	var prev_dir := Vector2.ZERO
	for i in range(1, samples.size()):
		var d: Vector2 = samples[i] - samples[i - 1]
		if d.length() < 0.3:
			continue
		if prev_dir != Vector2.ZERO and d.dot(prev_dir) < 0.0:
			flips += 1
		prev_dir = d
	print("[cli]   采样 %d 帧，方向反转 %d 次%s" % [samples.size(), flips, "  ← 抽搐!" if flips >= 3 else ""])
	if flips >= 3:
		fail_flips += 1

func _net() -> Node:
	return root.get_node_or_null("Net")
