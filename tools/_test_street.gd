extends SceneTree
## 生活设施自检（headless）：
##   1. world.tscn 里能找到快递柜/店招/售货机/自行车/垃圾桶这些节点；
##   2. 每个节点都挂上了 Sprite 且贴图非空；
##   3. 数量与 tools/street_props.json 对得上。
##
## 用法：godot --headless --path . --script res://tools/_test_street.gd

const KEYS := ["快递柜", "店招", "售货机", "自行车", "垃圾桶"]


func _initialize() -> void:
	var scene: PackedScene = load("res://scenes/world.tscn")
	if scene == null:
		print("STREET FAIL 加载 world.tscn 失败")
		quit(1)
		return
	var root: Node = scene.instantiate()
	var objs: Node = root.get_node_or_null("Objects")
	if objs == null:
		print("STREET FAIL 找不到 Objects 节点")
		quit(1)
		return

	var want := {"快递柜": 4, "店招": 2, "售货机": 3, "自行车": 21, "垃圾桶": 7}
	var got := {}
	var bad: Array[String] = []
	for n in objs.get_children():
		var nm := str(n.name)
		var hit := ""
		for k in KEYS:
			if nm.begins_with(k + "·"):
				hit = k
				break
		if hit == "":
			continue
		got[hit] = int(got.get(hit, 0)) + 1
		var spr: Sprite2D = n.get_node_or_null("Sprite")
		if spr == null or spr.texture == null:
			bad.append(nm)

	print("=== 生活设施 ===")
	var fails := 0
	for k in KEYS:
		var g: int = int(got.get(k, 0))
		var w: int = int(want.get(k, 0))
		var mark := "OK" if g == w else "MISMATCH"
		if g != w:
			fails += 1
		print("  %-6s %2d / %2d  %s" % [k, g, w, mark])
	if bad.is_empty():
		print("  贴图：全部就位")
	else:
		print("  贴图缺失 %d 个：%s" % [bad.size(), ", ".join(bad)])
		fails += 1
	print("结果 %s（失败项 %d）" % ["PASS" if fails == 0 else "FAIL", fails])
	root.free()
	quit(0 if fails == 0 else 1)
