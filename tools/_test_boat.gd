extends SceneTree
## 小船自检（headless）：
##   1. 15 艘船都落在水格里，且船边 12 格内存在可站立岸线；
##   2. 本机玩家能上船（吸附、关碰撞、船位跟随）；
##   3. 按方向键能把船划走，且船始终在水格里；
##   4. 靠岸后按 E 能下船（恢复碰撞、落在陆地、船恢复空船）。
##
## 用法：godot --headless --path . --script res://tools/_test_boat.gd

var arena: Node = null
var avatar: Node = null
var stage: int = 0
var clock: float = 0.0
var boat_index: int = -1
var boat_before := Vector2.ZERO
var move_action := "move_right"
var fails: int = 0


func _initialize() -> void:
	# 单机 + 不回家（回房会把出生点放到宿舍床上，这里要校园里的角色）
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
		_check_layout()
		stage = 1
		clock = 0.0
	elif stage == 1 and clock > 0.5:
		_do_board()
		stage = 2
		clock = 0.0
	elif stage == 2 and clock > 0.8:
		_check_boarded()
		boat_before = arena.get("_boats")[boat_index]["pos"]
		# 有些船的东边就是岸，往水里那侧划（测试只验证「能划动且不出水」）
		move_action = "move_right"
		if not bool(arena.call("_is_water", boat_before + Vector2(16, 0))):
			move_action = "move_left"
		Input.action_press(move_action)
		stage = 3
		clock = 0.0
	elif stage == 3 and clock > 0.7:
		Input.action_release(move_action)
		_check_sailed()
		Input.action_press("move_up")
		stage = 4
		clock = 0.0
	elif stage == 4 and clock > 0.45:
		Input.action_release("move_up")
		_check_heading(Vector2.UP, "上")
		_shot("res://shot_boat_up.png")
		Input.action_press("move_down")
		stage = 5
		clock = 0.0
	elif stage == 5 and clock > 0.45:
		Input.action_release("move_down")
		_check_heading(Vector2.DOWN, "下")
		_do_disembark()
		stage = 6
		clock = 0.0
	elif stage == 6 and clock > 0.8:
		_check_disembarked()
		print("结果 %s（失败项 %d）" % ["PASS" if fails == 0 else "FAIL", fails])
		quit(0 if fails == 0 else 1)
		return true
	return false


func _fail(msg: String) -> void:
	fails += 1
	print("  [FAIL] " + msg)


func _check_layout() -> void:
	var boats: Array = arena.get("_boats")
	var nodes: Array = arena.get("_boat_nodes")
	print("小船：状态 %d 艘 / 节点 %d 个" % [boats.size(), nodes.size()])
	if boats.size() != 15:
		_fail("船数量不是 15")
	if nodes.size() != boats.size():
		_fail("本地表现节点数量与船状态不一致")
	for i in boats.size():
		var pos: Vector2 = boats[i]["pos"]
		var cell := pos / 8.0
		if not bool(arena.call("_is_water", pos)):
			_fail("第 %d 艘不在水格里 cell=%s" % [i, cell])
		var land: Dictionary = arena.call("_find_land_near", pos)
		if not bool(land["ok"]):
			_fail("第 %d 艘附近找不到可站立岸线 cell=%s" % [i, cell])
		else:
			print("  #%02d cell=%s 岸线=%s" % [i, cell, (land["pos"] as Vector2) / 8.0])


func _do_board() -> void:
	var boats: Array = arena.get("_boats")
	boat_index = 0
	var raw := OS.get_environment("XGD_BOAT_INDEX").strip_edges()
	if not raw.is_empty() and raw.is_valid_int():
		boat_index = clampi(int(raw), 0, boats.size() - 1)
	var land: Dictionary = arena.call("_find_land_near", boats[boat_index]["pos"])
	if not bool(land["ok"]):
		_fail("上船测试：船边找不到岸")
		return
	avatar.call("teleport_to", land["pos"])
	var ok: bool = bool(arena.call("_try_board", boat_index))
	print("上船请求 -> %s" % ok)
	if not ok:
		_fail("_try_board 返回 false")


func _check_boarded() -> void:
	var boats: Array = arena.get("_boats")
	var mine: int = int(arena.get("_my_boat"))
	var expected: Vector2 = boats[boat_index]["pos"] + Vector2(0, 2)
	print("上船后：my_boat=%d on_boat=%s pos=%s 期望=%s" % [
		mine, str(avatar.get("on_boat")), avatar.position, expected])
	if mine != boat_index:
		_fail("_my_boat 没有指向刚上的船")
	if not bool(avatar.get("on_boat")):
		_fail("PlayerAvatar.on_boat 没有置位")
	if avatar.position.distance_to(expected) > 2.0:
		_fail("人物没有吸附到船位")
	var cs := avatar.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs != null and not cs.disabled:
		_fail("上船后玩家碰撞没有关闭")
	_shot("res://shot_boat_on.png")


func _check_sailed() -> void:
	var boats: Array = arena.get("_boats")
	var pos: Vector2 = boats[boat_index]["pos"]
	var moved: float = absf(pos.x - boat_before.x) + absf(pos.y - boat_before.y)
	print("划船：位移 %.1fpx（%s），船位=%s，水格=%s" % [
		moved, move_action, pos / 8.0, str(arena.call("_is_water", pos))])
	if moved < 10.0:
		_fail("按方向键后船没有前进")
	if not bool(arena.call("_is_water", pos)):
		_fail("船划出了水域")


func _check_heading(expected: Vector2, label: String) -> void:
	var nodes: Array = arena.get("_boat_nodes")
	var dir := Vector2.ZERO
	if boat_index < nodes.size() and is_instance_valid(nodes[boat_index]):
		dir = nodes[boat_index].get("dir")
	print("船头朝向：按%s后 dir=%s（应为 %s）" % [label, dir, expected])
	if dir != expected:
		_fail("按%s后船头没有转向" % label)


func _do_disembark() -> void:
	var ok: bool = bool(arena.call("_try_disembark"))
	print("下船请求 -> %s" % ok)
	if not ok:
		_fail("_try_disembark 返回 false（船边找不到岸或状态不对）")


func _check_disembarked() -> void:
	print("下船后：my_boat=%d on_boat=%s pos=%s 船占用=%d" % [
		int(arena.get("_my_boat")), str(avatar.get("on_boat")), avatar.position,
		int(arena.get("_boats")[boat_index]["rider"])])
	if int(arena.get("_my_boat")) != -1:
		_fail("_my_boat 没有清空")
	if bool(avatar.get("on_boat")):
		_fail("on_boat 没有清除")
	if int(arena.get("_boats")[boat_index]["rider"]) != 0:
		_fail("船仍显示有人")
	if bool(arena.call("_is_water", avatar.position)):
		_fail("人物落点还在水里")
	var cs := avatar.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs != null and cs.disabled:
		_fail("下船后玩家碰撞没有恢复")
	_shot("res://shot_boat_off.png")


func _shot(path: String) -> void:
	if not OS.has_environment("XGD_BOAT_SHOT"):
		return
	var img := root.get_texture().get_image()
	if img != null:
		img.save_png(path)
		print("[shot] " + path)
