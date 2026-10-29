extends SceneTree
## 检查三项：NPC 与玩家的视觉缩放是否一致、小地图是否收集到楼名、楼名标注层是否建起来。

var step := 0
var boot
var cam_scale_ok := false


func _initialize() -> void:
	boot = load("res://scenes/online_boot.tscn").instantiate()
	root.add_child(boot)


func _process(_d: float) -> bool:
	step += 1
	if step < 300:
		return false
	if step == 300:
		var mini = root.find_child("Minimap", true, false)
		if mini == null:
			print("小地图 FAIL：没找到 Minimap 节点")
		else:
			print("小地图 size=", mini.size, " 建筑数=", mini.get("_buildings").size(),
				" 画出名字数=", mini.get("last_names"),
				" font=", "有" if mini.get("font") != null else "null")
			var bs = mini.get("_buildings")
			if bs.size() > 0:
				var b0 = bs[0]
				print("  最大楼: ", b0["name"], " 宽=", b0["w"])
		var lab = root.find_child("BuildingLabels", true, false)
		if lab == null:
			print("楼名层 FAIL：没找到")
		else:
			print("楼名层 标签数=", lab.get("_labels").size())

		# 角色视觉缩放：比较玩家的 Sprite 和 NPC 的 Sprite 的全局 scale
		var found := 0
		for p in get_nodes_in_group("players"):
			if not p.is_local_player:
				continue
			var ps = p.get_node_or_null("Visual/Sprite")
			if ps == null:
				continue
			print("玩家 Sprite 全局 scale=", ps.global_scale, " 位置=", p.global_position)
			found += 1
		var npcs := root.find_children("npc_*", "Node2D", true, false)
		for n in npcs:
			var ns = n.get_node_or_null("Visual/Sprite")
			if ns == null:
				print("NPC FAIL：Visual/Sprite 没找到 ", n.name)
				continue
			print("NPC ", n.get("display_name"), " 全局 scale=", ns.global_scale)
			found += 1
		print("结果 DONE 找到角色数=", found)
		quit(0)
		return true
	return false
