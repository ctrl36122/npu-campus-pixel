extends SceneTree
## 牵绳绕路回归：猫的直线被楼挡住时，不许「原地左右擦墙 / 空跑腿」，
## 要顺着 NavGrid 的 A* 绕过去；连路都没有（玩家被围住/上船）时才允许落到脚边。
##
##   APPDATA=<临时目录> XGD_OFFLINE=1 godot --headless --script res://tools/_test_leash_path.gd
##
## 两幕：
##   ① 一堵竖墙隔着，猫必须绕到墙另一边（走的是远路，不是擦墙）
##   ② 玩家被四面墙围死、根本没有路，猫也必须凑到脚边（不能把人跟丢）
## 全程盯三个指标：连续空跑的时长、单帧最大位移（防瞬移骗过）、走路里程。

const WALL_X0 := 30
const WALL_X1 := 32
const WALL_Y0 := 28
const WALL_Y1 := 44

const STAGE1_TIME := 9.0
const STAGE2_TIME := 4.0

var cat: Node2D = null
var walker: CharacterBody2D = null
var nav: NavGrid = null
var stage := 0
var stage_t := 0.0
var t := 0.0

var last_pos := Vector2.ZERO
var moved := 0.0
var frames := 0
var max_jump := 0.0
var flail := 0
var flail_t := 0.0
var flail_max_t := 0.0
var passed_top := false   # 轨迹是否从墙上方绕过（y < 墙顶）
var passed_bottom := false

var fails: Array[String] = []
var checks := 0


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _reset_stats() -> void:
	last_pos = cat.position
	moved = 0.0
	frames = 0
	max_jump = 0.0
	flail = 0
	flail_t = 0.0
	flail_max_t = 0.0
	passed_top = false
	passed_bottom = false


## 一张只有建筑的地图：W×H 格，8px/格
func _world(polys: Array) -> Dictionary:
	return {"map": {"W": 80, "H": 80}, "water": [], "bridges": [], "buildings": polys}


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

	# ① 一堵竖墙，把地图切成左右两半（上下都留了绕行的口子）
	nav = NavGrid.new()
	nav.build(_world([
		{"poly": [[WALL_X0, WALL_Y0], [WALL_X1, WALL_Y0], [WALL_X1, WALL_Y1], [WALL_X0, WALL_Y1]],
			"hp": 0.0},
	]), 8.0)
	_ok(nav.is_walkable(Vector2i(20, 35)), "地图①：墙左边可走")
	_ok(nav.is_walkable(Vector2i(40, 35)), "地图①：墙右边可走")
	_ok(not nav.is_walkable(Vector2i(31, 35)), "地图①：墙上是障碍")

	walker = CharacterBody2D.new()
	walker.position = Vector2(40.0, 35.5) * 8.0     # 墙右边
	root.add_child(walker)
	cat = Node2D.new()
	cat.set_script(script)
	root.add_child(cat)
	cat.call("setup", Vector2(20.0, 35.5) * 8.0, script.SKINS[0], 9999, nav)
	cat.call("start_follow", walker)
	_reset_stats()


func _process(delta: float) -> bool:
	t += delta
	stage_t += delta
	walker.velocity = Vector2.ZERO

	# 统计（headless 首帧很长，前 0.3 秒不计）
	var d: float = cat.position.distance_to(last_pos)
	moved += d
	var jump := d
	last_pos = cat.position
	if t > 0.3:
		max_jump = maxf(max_jump, jump)
		if d < 0.2 and str(cat.get("anim")) in ["walk", "run"]:
			flail += 1
			flail_t += delta
			flail_max_t = maxf(flail_max_t, flail_t)
		else:
			flail_t = 0.0
		if cat.position.y < float(WALL_Y0) * 8.0:
			passed_top = true
		if cat.position.y > float(WALL_Y1) * 8.0:
			passed_bottom = true
		frames += 1

	if stage == 0 and stage_t < STAGE1_TIME:
		return false
	if stage == 0:
		var dist: float = cat.position.distance_to(walker.position)
		print("  ① 绕墙：最终距玩家 %.0fpx，走了 %.0fpx，空跑 %d/%d 帧（最长连续 %.2fs），单帧最大位移 %.1fpx" % [
			dist, moved, flail, frames, flail_max_t, max_jump])
		_ok(dist < 70.0, "①被墙隔着也能绕到玩家身边", "实测 %.0fpx" % dist)
		_ok(flail_max_t <= 0.12, "①不连续原地空跑（最长 ≤0.12s 过渡）",
			"实测 %.2fs，共 %d 帧" % [flail_max_t, flail])
		_ok(passed_top or passed_bottom, "①真的从墙的上方/下方绕过去（不是穿墙）",
		"上方=%s 下方=%s" % [str(passed_top), str(passed_bottom)])
		_ok(max_jump < 40.0, "①过程中没有瞬移", "单帧最大 %.1fpx" % max_jump)
		_setup_boxed()
		return false
	if stage_t < STAGE2_TIME:
		return false

	var dist2: float = cat.position.distance_to(walker.position)
	print("  ② 围死：最终距玩家 %.0fpx，空跑最长 %.2fs，单帧最大位移 %.1fpx" % [
		dist2, flail_max_t, max_jump])
	_ok(dist2 < 40.0, "②根本没有路时也能凑到脚边（不脱离人）", "实测 %.0fpx" % dist2)
	_ok(flail_max_t <= 0.12, "②不连续原地空跑", "实测 %.2fs" % flail_max_t)
	print("结果 ", "PASS" if fails.is_empty() else "FAIL", "（%d 项）" % checks)
	quit(0 if fails.is_empty() else 1)
	return true


## ② 把玩家四面围死，猫丢到很远的地方：A* 无解，只能落到脚边
func _setup_boxed() -> void:
	stage = 1
	stage_t = 0.0
	var cx := 40
	var cy := 35
	var box: Array = []
	# 上下两道横墙、左右两道竖墙，留不出任何缝
	box.append({"poly": [[cx - 6, cy - 6], [cx + 6, cy - 6], [cx + 6, cy - 5], [cx - 6, cy - 5]], "hp": 0.0})
	box.append({"poly": [[cx - 6, cy + 5], [cx + 6, cy + 5], [cx + 6, cy + 6], [cx - 6, cy + 6]], "hp": 0.0})
	box.append({"poly": [[cx - 6, cy - 6], [cx - 5, cy - 6], [cx - 5, cy + 6], [cx - 6, cy + 6]], "hp": 0.0})
	box.append({"poly": [[cx + 5, cy - 6], [cx + 6, cy - 6], [cx + 6, cy + 6], [cx + 5, cy + 6]], "hp": 0.0})
	var nav2 := NavGrid.new()
	nav2.build(_world(box), 8.0)
	cat.set("_nav", nav2)
	cat.call("_clear_path")
	# 远远丢到地图左上角（猫没有 teleport_to，直接改 pos）
	var far := Vector2(4.0, 4.0) * 8.0
	cat.set("pos", far)
	cat.position = far
	cat.set("home", far)
	_reset_stats()
