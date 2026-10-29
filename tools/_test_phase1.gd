extends SceneTree
## Phase 1 自动化验收：实测碰撞层是否生效（不靠肉眼）
## 用法：godot --headless --path . --script res://tools/_test_phase1.gd
##
## 做法：关掉玩家自己的 _physics_process，由本脚本接管推动，
##       先向南撞地图边界，再向北撞建筑，检查是否被挡住。

const SPEED := 150.0
const DT := 1.0 / 60.0

var player: CharacterBody2D
var frame := 0
var y_after_south := 0.0
var y_after_north := 0.0
var ok := true


func _initialize() -> void:
	var ps = load("res://scenes/sandbox/phase1.tscn")
	if ps == null:
		push_error("场景加载失败")
		quit(1)
		return
	var scn = ps.instantiate()
	root.add_child(scn)
	player = scn.get_node("Player")
	player.set_physics_process(false)


func _physics_process(_delta: float) -> bool:
	frame += 1

	if frame == 2:
		print("起点 ", player.position)

	# 阶段 A：向南推向地图边界（边界在 y = 64*8 = 512）
	if frame > 2 and frame <= 200:
		player.velocity = Vector2(0, SPEED)
		player.move_and_slide()
		if frame == 200:
			y_after_south = player.position.y
			if y_after_south > 512.0:
				ok = false
				print("FAIL 穿出南边界 y=", y_after_south)
			else:
				print("PASS 南边界挡住 y=", y_after_south, "（边界 512）")

	# 阶段 B：向北推，撞建筑（建筑脚线 y = 40*8 = 320）
	if frame > 200 and frame <= 520:
		player.velocity = Vector2(0, -SPEED)
		player.move_and_slide()
		if frame == 520:
			y_after_north = player.position.y
			if y_after_north < 320.0:
				ok = false
				print("FAIL 穿进建筑 y=", y_after_north, "（脚线 320）")
			else:
				print("PASS 建筑挡住 y=", y_after_north, "（脚线 320）")

	if frame >= 520:
		print("结果 ", "ALL PASS" if ok else "有失败项")
		quit(0 if ok else 1)
		return true
	return false
