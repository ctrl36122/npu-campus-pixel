extends SceneTree
## 起身同步不变量自检（headless / offline，单进程）：
## 坐下 / 躺下后再按 E 起身，必须保证「起身落点」同步进了权威快照 server_state，
## 否则联机时 position 是 ALWAYS 复制（每帧从服务端覆盖客户端），服务端那份却停在
## 座位中心 —— 客户端刚 _step_out 挪出来就被拉回、本地预测又挪出来 → 反复拉扯 = 抽搐。
##
## 这里校验 stand_up() 后 server_state.position 与 avatar.position 一致（一致就不会触发
## reconcile 抖动），并且 server_state.seq 已刷新（服务端广播了新姿势）。离线模式里
## Net.is_server() 为真，stand_up() 里的 _publish_pose 也会真正跑到，所以能验证到。
##
## 用法：godot --headless --path . --script res://tools/_test_seat_standup_sync.gd

var arena
var avatar
var stage := 0
var clock := 0.0
var fails := 0

# 当前被测座位的快照
var _pre_ss := Vector2.ZERO
var _pre_pos := Vector2.ZERO
var _post_ss := Vector2.ZERO
var _post_pos := Vector2.ZERO
var _post_seq := 0
var _post_sit := 0
var _kind := ""

func _initialize() -> void:
	OS.set_environment("XGD_OFFLINE", "1")
	OS.set_environment("XGD_NOHOME", "1")
	root.add_child(load("res://scenes/online_boot.tscn").instantiate())

func _process(_delta) -> bool:
	clock += _delta
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

	# 进宿舍
	if stage == 0 and clock > 2.0:
		print("进入宿舍房间……")
		if not bool(arena.call("enter_room", "res://assets/rooms/dorm_space.json")):
			_fail("进不了宿舍房间")
		stage = 1
		clock = 0.0
	# —— 床（躺下）——
	elif stage == 1 and clock > 0.8:
		_kind = "bed"
		var bed = _find_seat("bed")
		if bed.is_empty():
			_fail("宿舍里找不到 bed 座位")
			stage = 9
			clock = 0.0
		else:
			avatar.lay_at(bed["pos"], "down")      # 同 Arena._on_seat_changed 的躺姿路径
			stage = 2
			clock = 0.0
	elif stage == 2 and clock > 0.4:
		_pre_ss = avatar.server_state.get("position", Vector2.ZERO)
		_pre_pos = avatar.position
		stage = 3
		clock = 0.0
	elif stage == 3 and clock > 0.4:
		avatar.stand_up()                          # 同按 E 起身路径
		stage = 4
		clock = 0.0
	elif stage == 4 and clock > 0.4:
		_post_ss = avatar.server_state.get("position", Vector2.ZERO)
		_post_pos = avatar.position
		_post_seq = int(avatar.server_state.get("seq", 0))
		_post_sit = int(avatar.get("sit_dir"))
		_eval()
		stage = 5
		clock = 0.0
	# —— 椅子（坐下）——
	elif stage == 5 and clock > 0.8:
		_kind = "chair"
		var ch = _find_seat("chair")
		if ch.is_empty():
			_fail("宿舍里找不到 chair 座位")
			stage = 9
			clock = 0.0
		else:
			avatar.sit_at(ch["pos"], "down")
			stage = 6
			clock = 0.0
	elif stage == 6 and clock > 0.4:
		_pre_ss = avatar.server_state.get("position", Vector2.ZERO)
		_pre_pos = avatar.position
		stage = 7
		clock = 0.0
	elif stage == 7 and clock > 0.4:
		avatar.stand_up()
		stage = 8
		clock = 0.0
	elif stage == 8 and clock > 0.4:
		_post_ss = avatar.server_state.get("position", Vector2.ZERO)
		_post_pos = avatar.position
		_post_seq = int(avatar.server_state.get("seq", 0))
		_post_sit = int(avatar.get("sit_dir"))
		_eval()
		stage = 9
		clock = 0.0
	elif stage == 9 and clock > 0.4:
		print("结果 %s（失败项 %d）" % ["PASS" if fails == 0 else "FAIL", fails])
		quit(0 if fails == 0 else 1)
		return true
	return false


func _find_seat(kind: String) -> Dictionary:
	var seats = arena.get("_seats_room")
	for s in seats:
		if String(s["kind"]) == kind:
			return s
	return {}


func _eval() -> void:
	var pre_d := _pre_ss.distance_to(_pre_pos)
	var post_d := _post_ss.distance_to(_post_pos)
	print("[%s] 坐下时 server_state≈pos? %s (Δ=%.1f) | 起身后 server_state≈pos? %s (Δ=%.1f) seq=%d sit_dir=%d" % [
		_kind, str(pre_d < 0.5), pre_d, str(post_d < 0.5), post_d, _post_seq, _post_sit])
	# 关键不变量：起身后 server_state 必须落在 avatar.position（否则联机会抽搐）
	if not (post_d < 0.5):
		_fail("%s 起身后 server_state 与 position 不一致（Δ=%.1f）→ 联机抽搐" % [_kind, post_d])
	if _post_sit != 0:
		_fail("%s 起身后 sit_dir 不为 0" % _kind)
	if not (pre_d < 0.5):
		_fail("%s 坐下时 server_state 与 position 不一致（Δ=%.1f）" % [_kind, pre_d])


func _fail(msg: String) -> void:
	fails += 1
	print("  [FAIL] " + msg)
