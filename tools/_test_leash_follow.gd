extends SceneTree
## 牵绳跟随手感回归：玩家 110 走路 / 170 冲刺 / **掉头走过来**，
## 猫必须真的跟得上，而且不许「抽搐」。
##
##   APPDATA=<临时目录> XGD_OFFLINE=1 godot --headless --script res://tools/_test_leash_follow.gd
##
## 抽搐的两种历史形态，各有一条判据盯着：
##   ① 猫离人比「该待的距离」还近时，目标点翻到猫背后，猫朝**远离人**的方向走，
##      玩家 56px/s 逼近、猫 52px/s 退开，距离锁死在 16px 每帧抖 —— 看 retreat。
##   ② 站在「走/站」阈值上每帧来回切，姿态一秒闪十几次 —— 看 anim_flips。
## 瞬移兜底会把距离强行拉回 0，所以还要检查这期间有没有真的移动过（走路里程），
## 否则「靠瞬移」也能骗过稳态距离。

const STEP_TIME := 3.5      # 每档走多久
const SETTLE := 1.2         # 头 1.2 秒是加速靠拢阶段，不计入稳态
const TICK := 1.0 / 30.0    # 玩家物理 tick：位置每 1/30 秒跳一次，不是每帧

var cat: Node2D = null
var walker: CharacterBody2D = null
var t := 0.0
var phase := 0
var phase_t := 0.0
var last_pos := Vector2.ZERO
var last_walker := Vector2.ZERO
var prev_step := Vector2.ZERO
var stair_acc := 0.0

var dist_sum := 0.0
var dist_n := 0
var moved := 0.0
var anim_flips := 0        # 站/走/跑之间切换的次数：每帧来回切就是「抽搐」
var last_anim := ""
var max_rate := 1.0        # 跟随时动画帧率倍率的最大值：翻太快 12px 的猫腿看着就是抖
var retreat := 0           # 玩家朝猫走过来、猫却往外躲的帧数
var reversals := 0         # 相邻两帧位移方向掉头（>120°）的次数
var fails: Array[String] = []
var checks := 0

## 每档：标签 / 玩家速度 / 方向 / 额外要检查什么
var phases := [
	{"label": "玩家 110 走路", "spd": 110.0, "dir": Vector2.RIGHT, "chase": true},
	{"label": "玩家 170 冲刺", "spd": 170.5, "dir": Vector2.RIGHT, "chase": true},
	# 真机上走路实测约 56px/s（30Hz tick × 一步 1.87px，指令不是每 tick 都有），
	# 而这个速度正好落在老代码的「僵持点」上：玩家 56 逼近、猫 55 退开 → 锁死在 16px
	{"label": "玩家掉头走过来", "spd": 56.0, "dir": Vector2.LEFT, "chase": false},
]


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
	last_walker = walker.position


func _process(delta: float) -> bool:
	t += delta
	phase_t += delta
	var d: Dictionary = phases[mini(phase, phases.size() - 1)]
	if phase_t < STEP_TIME and t < 90.0:
		var dir: Vector2 = d["dir"]
		var spd: float = float(d["spd"])
		# 玩家位置是 **30Hz 阶跃** 的（物理 tick 一次跳一步），猫却是每帧读它 ——
		# 这正是「抽搐」的触发条件：目标点每两帧跳 3.7px，猫的速度跟着一高一低。
		# 按帧平均地挪过去就把这个效应抹平了，测试也就抓不到那个 bug。
		stair_acc += delta
		var steps := 0
		while stair_acc >= TICK:
			stair_acc -= TICK
			steps += 1
		var pstep: Vector2 = dir * spd * TICK * float(steps)
		walker.position += pstep
		walker.velocity = dir * spd
		var cstep: Vector2 = cat.position - last_pos
		moved += cstep.length()
		last_pos = cat.position
		max_rate = maxf(max_rate, float(cat.get("_anim_rate")))
		# 猫却在「朝远离人的方向」走：玩家正朝它走过来的时候，这是最刺眼的那种抖
		var to_cat: Vector2 = cat.position - walker.position
		# pstep 和「玩家→猫」同向 = 玩家正朝猫走过来（夹角 < 45°）
		if to_cat.length() > 10.0 and pstep.length() > 0.05:
			if pstep.normalized().dot(to_cat.normalized()) > 0.7:
				if cstep.dot(to_cat.normalized()) > 0.02:
					retreat += 1
		if prev_step.length() > 0.12 and cstep.length() > 0.12:
			if prev_step.normalized().dot(cstep.normalized()) < -0.5:
				reversals += 1
		if cstep.length() > 0.12:
			prev_step = cstep
		if phase_t > SETTLE:
			dist_sum += cat.position.distance_to(walker.position)
			dist_n += 1
			var a := str(cat.get("anim"))
			if a != last_anim:
				if last_anim != "":
					anim_flips += 1
				last_anim = a
		return false
	_report(d)
	if phase + 1 >= phases.size():
		print("结果 ", "PASS" if fails.is_empty() else "FAIL", "（%d 项）" % checks)
		quit(0 if fails.is_empty() else 1)
		return true
	phase += 1
	phase_t = 0.0
	dist_sum = 0.0
	dist_n = 0
	moved = 0.0
	anim_flips = 0
	last_anim = ""
	max_rate = 1.0
	retreat = 0
	reversals = 0
	prev_step = Vector2.ZERO
	last_walker = walker.position
	return false


func _report(d: Dictionary) -> void:
	var label: String = d["label"]
	var avg := dist_sum / float(maxi(dist_n, 1))
	print("  %s：稳态间距 %.1fpx，猫自己走了 %.0fpx，姿态切换 %d 次（%d 帧采样），往外躲 %d 帧，掉头 %d 次" % [
		label, avg, moved, anim_flips, dist_n, retreat, reversals])
	_ok(avg < 70.0, label + "时距玩家 70px 内", "实测 %.1fpx" % avg)
	if bool(d["chase"]):
		# 3.5 秒玩家最多走 600px：猫若只靠瞬移，走路里程会接近 0
		_ok(moved > 200.0, label + "时猫真的在跑（不是靠瞬移）", "实测 %.0fpx" % moved)
		# run 那行只有 4 帧 / 12fps，倍率给到 2 就是 24fps 翻腿，肉眼就是一抖一抖
		_ok(max_rate <= 1.26, label + "时腿不翻太快（帧率倍率 ≤1.25）", "实测 %.2f" % max_rate)
	# 稳态期间应该一直跑着，站点/跑之间来回切就是抽搐
	_ok(anim_flips <= 4, label + "时姿态不抖（站↔跑切换 ≤4 次）", "实测 %d 次" % anim_flips)
	# 玩家迎面走过来的时候猫**不许往外躲**：一躲就会和玩家贴成 16px 僵持，每帧抖
	_ok(retreat <= 5, label + "时猫不往远离人的方向躲", "实测 %d 帧" % retreat)
	_ok(reversals <= 5, label + "时没有原地掉头抖", "实测 %d 次" % reversals)
