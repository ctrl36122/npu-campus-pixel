extends SceneTree
## 验证 NPC：数量、名字、外观、位置随时间变化

var step := 0
var npcs := []
var t0 := 0


func _initialize() -> void:
	root.add_child(load("res://scenes/online_boot.tscn").instantiate())


func _process(_d: float) -> bool:
	step += 1
	if step == 320:
		for n in root.find_children("npc_*", "Node2D", true, false):
			npcs.append(n)
		print("NPC 数量=%d" % npcs.size())
		for n in npcs:
			print("  %-6s pos=(%d,%d) hero=%s" % [
				str(n.get("display_name")), int(n.position.x), int(n.position.y), str(n.get("hero_id"))])
		t0 = Time.get_ticks_msec()
	if t0 > 0 and Time.get_ticks_msec() - t0 > 1600:
		print("1.6 秒后：")
		for n in npcs:
			print("  %-6s → (%d,%d)" % [str(n.get("display_name")), int(n.position.x), int(n.position.y)])
		quit(0)
		return true
	return false
