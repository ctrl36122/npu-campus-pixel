extends SceneTree
## 验证角色创建流程：初始弹窗 + 玩家锁定 → 填昵称确认 → 弹窗消失 + 解锁 + 数据落地
var step := 0
var p
var ui
var ok := true

func _initialize() -> void:
	var scn = load("res://scenes/sandbox/phase1.tscn").instantiate()
	root.add_child(scn)
	p = scn.get_node("Player")
	ui = scn.get_node("CharCreate")

func _physics_process(_d: float) -> bool:
	step += 1
	if step == 3:
		var v: bool = ui.is_open()
		var l: bool = p.locked
		if not v or not l: ok = false
		print("初始   弹窗可见=", v, " 玩家锁定=", l)
	elif step == 5:
		ui._name_edit.text = ""
		ui._confirm()                       # 空昵称应被拦下
		if not ui.is_open(): ok = false
		print("空昵称 弹窗仍开=", ui.is_open(), " 提示=", ui._hint.text)
	elif step == 7:
		ui._select("nancy")
		ui._name_edit.text = "西工大新生"
		ui._confirm()
	elif step == 9:
		print("确认后 弹窗可见=", ui.is_open(), " 玩家锁定=", p.locked,
			" 外观=", p.hero_id, " 昵称=", p.display_name)
		if ui.is_open() or p.locked or p.display_name != "西工大新生" or p.hero_id != "nancy":
			ok = false
		print("结果 ", "ALL PASS" if ok else "FAIL")
		quit(0 if ok else 1)
		return true
	return false
