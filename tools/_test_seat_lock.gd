extends SceneTree
## 座位锁定自检（headless）：
##   坐下 / 躺下后按方向键，角色不能移动；必须先按 E 起身，之后才能走。
## 同时覆盖宿舍的椅子与床两种座位。
##
## 用法：godot --headless --path . --script res://tools/_test_seat_lock.gd

var arena: Node = null
var avatar: Node = null
var stage: int = 0
var clock: float = 0.0
var seat_pos := Vector2.ZERO
var frozen_pos := Vector2.ZERO
var fails: int = 0
var seat_kind: String = "chair"


func _initialize() -> void:
	OS.set_environment("XGD_OFFLINE", "1")
	OS.set_environment("XGD_NOHOME", "1")
	root.add_child(load("res://scenes/online_boot.tscn").instantiate())


func _process(delta: float) -> bool:
	clock += delta
	if arena == null:
		var sf := root.get_node_or_null("SessionFlow")
		if sf != null and sf.get("world") != null:
			arena = sf.get("world")
		return false
	if avatar == null:
		for n in root.find_children("*", "CharacterBody2D", true, false):
			if bool(n.get("is_local_player")):
				avatar = n
		return false

	if stage == 0 and clock > 2.0:
		print("进入宿舍房间……")
		var ok: bool = bool(arena.call("enter_room", "res://assets/rooms/dorm_space.json"))
		if not ok:
			_fail("进不了宿舍房间")
		stage = 1
		clock = 0.0
	elif stage == 1 and clock > 0.8:
		_test_seat("chair")
		stage = 2
		clock = 0.0
	elif stage == 2 and clock > 0.6:
		frozen_pos = avatar.position
		Input.action_press("move_right")
		stage = 3
		clock = 0.0
	elif stage == 3 and clock > 0.8:
		Input.action_release("move_right")
		var moved: float = avatar.position.distance_to(frozen_pos)
		print("坐下后按方向键：位移 %.2fpx，sit_dir=%d（应为 0 位移且仍坐着）" % [
			moved, int(avatar.get("sit_dir"))])
		if moved > 1.0:
			_fail("坐下后仍能被 WASD 移动")
		if int(avatar.get("sit_dir")) == 0:
			_fail("按方向键把坐姿清掉了（应该必须按 E 才起身）")
		# 模拟按 E 起身
		arena.call("_try_interact")
		stage = 4
		clock = 0.0
	elif stage == 4 and clock > 0.5:
		print("按 E 后：sit_dir=%d（应为 0）" % int(avatar.get("sit_dir")))
		if int(avatar.get("sit_dir")) != 0:
			_fail("按 E 没有起身")
		frozen_pos = avatar.position
		Input.action_press("move_right")
		stage = 5
		clock = 0.0
	elif stage == 5 and clock > 0.8:
		Input.action_release("move_right")
		var moved: float = avatar.position.distance_to(frozen_pos)
		print("起身后按方向键：位移 %.1fpx（应 > 0）" % moved)
		if moved < 2.0:
			_fail("起身后仍然走不动")
		# 换到床上再验证一次躺下锁定
		_test_seat("bed")
		stage = 6
		clock = 0.0
	elif stage == 6 and clock > 0.6:
		frozen_pos = avatar.position
		Input.action_press("move_up")
		stage = 7
		clock = 0.0
	elif stage == 7 and clock > 0.8:
		Input.action_release("move_up")
		var moved: float = avatar.position.distance_to(frozen_pos)
		print("躺下后按方向键：位移 %.2fpx，sit_dir=%d（应为 0 位移且仍躺着）" % [
			moved, int(avatar.get("sit_dir"))])
		if moved > 1.0:
			_fail("躺下后仍能被 WASD 移动")
		if int(avatar.get("sit_dir")) == 0:
			_fail("按方向键把躺姿清掉了")
		arena.call("_try_interact")
		stage = 8
		clock = 0.0
	elif stage == 8 and clock > 0.5:
		if int(avatar.get("sit_dir")) != 0:
			_fail("躺着时按 E 没有起身")
		print("结果 %s（失败项 %d）" % ["PASS" if fails == 0 else "FAIL", fails])
		quit(0 if fails == 0 else 1)
		return true
	return false


func _test_seat(kind: String) -> void:
	var seats: Array = arena.get("_seats_room")
	var chosen: Dictionary = {}
	for s in seats:
		if String(s["kind"]) == kind:
			chosen = s
			break
	if chosen.is_empty():
		_fail("宿舍里找不到 %s 座位" % kind)
		return
	seat_kind = kind
	seat_pos = chosen["pos"]
	if kind == "bed":
		print("躺到床上……")
		_net().call("sit_down", 5, chosen["pos"])      # 5 = 躺下（LIE_BASE），朝下
	else:
		print("坐到椅子上……")
		_net().call("sit_down", 1, chosen["pos"])      # 1 = 坐下，朝下


## SceneTree 脚本里没有 autoload 全局名，走节点路径取 Net 单例。
func _net() -> Node:
	return root.get_node_or_null("Net")


func _fail(msg: String) -> void:
	fails += 1
	print("  [FAIL] " + msg)
