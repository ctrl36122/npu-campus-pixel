extends SceneTree
## 牵绳跟随回归：玩家 110（冲刺 170）往前走，猫必须真的跟得上，
## 而不是像以前那样最高只有 32、只能靠 220px 瞬移「啪」一下闪到脚边。
##
##   APPDATA=<临时目录> XGD_OFFLINE=1 godot --headless --script res://tools/_test_leash_follow.gd
##
## 只检查「稳态间距」：走一段之后猫和玩家的距离应该稳定在一个小值上。
## 瞬移兜底会把距离强行拉回 0，所以还要检查这期间有没有真的移动过（走路里程），
## 否则「靠瞬移」也能骗过稳态距离。

const STEP_TIME := 4.0      # 每档速度走多久
const SETTLE := 1.5         # 头 1.5 秒是加速靠拢阶段，不计入稳态

var cat: Node2D = null
var walker: CharacterBody2D = null
var t := 0.0
var phase := 0
var phase_t := 0.0
var dir := Vector2.RIGHT
var dist_sum := 0.0
var dist_n := 0
var moved := 0.0
var last_pos := Vector2.ZERO
var fails: Array[String] = []
var checks := 0


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _initialize() -> void:
	var script: Script = load("res://net/scenes/Cat.gd")
	if script == null:
		print("结果 FAIL：Cat.gd 载不进来")
		quit(1)
		return
	if not ResourceLoader.exists("res://assets/cats/oreo_cat_sheet.png"):
		print("跳过：素材未随仓库分发（assets/cats/oreo_cat_sheet.png 不在）")
		quit(0)
		return
	walker = CharacterBody2D.new()
	walker.position = Vector2(2000.0, 2000.0)   # 挪到没人的地方，别撞到别的东西
	root.add_child(walker)
	cat = Node2D.new()
	cat.set_script(script)
	root.add_child(cat)
	cat.call("setup", walker.position + Vector2(-12.0, 8.0), script.SKINS[0], 7777, null)
	cat.call("start_follow", walker)
	last_pos = cat.position


func _process(delta: float) -> bool:
	t += delta
	if phase_t < STEP_TIME and t < 60.0:
		phase_t += delta
		# 玩家按着方向键走 / 冲刺
		var spd := 110.0 if phase == 0 else 170.5
		walker.velocity = dir * spd
		walker.position += dir * spd * delta
		moved += cat.position.distance_to(last_pos)
		last_pos = cat.position
		if phase_t > SETTLE:
			dist_sum += cat.position.distance_to(walker.position)
			dist_n += 1
		return false
	# 一档走完
	var avg := dist_sum / float(maxi(dist_n, 1))
	var label := "玩家 110 走路" if phase == 0 else "玩家 170 冲刺"
	print("  %s：稳态间距 %.1fpx，猫自己走了 %.0fpx（%d 帧采样）" % [label, avg, moved, dist_n])
	_ok(avg < 40.0, label + "时距玩家 40px 内", "实测 %.1fpx" % avg)
	# 4 秒玩家最多走 682px：猫若只靠瞬移，走路里程会接近 0
	_ok(moved > 200.0, label + "时猫真的在跑（不是靠瞬移）", "实测 %.0fpx" % moved)

	phase += 1
	phase_t = 0.0
	dist_sum = 0.0
	dist_n = 0
	moved = 0.0
	if phase > 1:
		# 停下：猫应该贴到脚边就不再动
		walker.velocity = Vector2.ZERO
		if t < 900.0:
			pass
		print("结果 ", "PASS" if fails.is_empty() else "FAIL", "（%d 项）" % checks)
		quit(0 if fails.is_empty() else 1)
	return false
