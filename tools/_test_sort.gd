extends SceneTree
## 数值验证：把玩家传送到楼北（应被楼挡）与楼南（应在楼前），
## 打印 players 容器与角色、建筑的真实变换，确认 y-sort 用的坐标空间。

var step := 0
var boot
var avatar
var t := 0.0


func _initialize() -> void:
	boot = load("res://scenes/online_boot.tscn").instantiate()
	root.add_child(boot)


func _process(delta: float) -> bool:
	step += 1
	t += delta
	if step == 400:
		var sf = root.get_node_or_null("SessionFlow")
		if sf == null or sf.world == null:
			print("结果 FAIL：世界没就绪")
			quit(1)
			return true
		var w = sf.world
		var objs = w.campus.get_node_or_null("Objects")
		var players = w.players
		print("Objects y_sort=", objs.y_sort_enabled,
			"  Players 父=", players.get_parent().name,
			"  Players y_sort=", players.y_sort_enabled,
			"  Players scale=", players.scale)
		# 传送到自动化学院北侧 cell (347,399)
		w.request_teleport(w.campus.to_global(Vector2(347, 399) * 8.0))
	elif step > 400 and step % 30 == 0 and avatar == null:
		var sf = root.get_node_or_null("SessionFlow")
		for n in root.find_children("*", "CharacterBody2D", true, false):
			if n.is_local_player:
				avatar = n
		if avatar == null and step > 700:
			print("结果 FAIL：没找到角色")
			quit(1)
			return true
	elif avatar != null and step > 760:
		var sf = root.get_node_or_null("SessionFlow")
		var w = sf.world
		var objs = w.campus.get_node_or_null("Objects")
		print("角色 position=", avatar.position, " global=", avatar.global_position)
		print("Players global_origin=", (w.players as Node2D).global_position)
		# 找自动化学院
		for n in objs.get_children():
			if n is StaticBody2D and str(n.name).contains("自动化"):
				print("楼 global=", n.global_position, " (foot)")
				var spr = n.get_node_or_null("Sprite")
				print("楼贴图全局顶=", spr.get_global_transform() * spr.offset,
					" 高=", spr.texture.get_size().y * spr.global_scale.y)
				# 楼在玩家南边多少
				print("玩家在楼北? ", avatar.global_position.y < n.global_position.y,
					"  玩家应被楼盖住（若 y-sort 正确）")
				break
		print("结果 DONE")
		quit(0)
		return true
	return false
