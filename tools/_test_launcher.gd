extends SceneTree
## 验证启动菜单的三个入口真能跳转（change_scene_to_file 后场景是否正常建起来）

var step := 0
var target := "res://net/scenes/NetBoot.tscn"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--to="):
			target = a.substr(5)
	root.add_child(load("res://scenes/launcher.tscn").instantiate())


func _process(_d: float) -> bool:
	step += 1
	if step == 8:
		var err: int = change_scene_to_file(target)
		print("→ 跳转 %s  err=%d" % [target, err])
	if step == 60:
		var cur := current_scene
		if cur == null:
			print("结果 FAIL：没有当前场景")
			quit(1)
			return true
		var n := cur.get_child_count()
		print("结果 OK：场景=%s 子节点=%d" % [cur.name, n])
		quit(0 if n > 0 else 1)
		return true
	return false
