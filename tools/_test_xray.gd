extends SceneTree
## 打印传送后哪些楼被判透明、玩家在其贴图上的像素坐标
var step := 0
var boot
var avatar
var tp_done := false


func _initialize() -> void:
	boot = load("res://scenes/online_boot.tscn").instantiate()
	root.add_child(boot)


func _process(_d: float) -> bool:
	step += 1
	if step == 400 and not tp_done:
		var sf = root.get_node_or_null("SessionFlow")
		if sf != null and sf.world != null:
			var w = sf.world
			w.request_teleport(w.campus.to_global(Vector2(347, 438) * 8.0))
			tp_done = true
	if step > 520 and step % 20 == 0 and avatar == null:
		for n in root.find_children("*", "CharacterBody2D", true, false):
			if n.is_local_player:
				avatar = n
	if avatar != null and step > 640:
		var sf = root.get_node_or_null("SessionFlow")
		var w = sf.world
		var objs = w.campus.get_node_or_null("Objects")
		var gp: Vector2 = avatar.global_position
		print("玩家全局=", gp)
		for n in objs.get_children():
			if not (n is StaticBody2D):
				continue
			var spr = n.get_node_or_null("Sprite")
			if spr == null or spr.texture == null:
				continue
			var tl: Vector2 = spr.get_global_transform() * spr.offset
			var sc: float = spr.global_scale.x
			var px := Vector2i(((gp - Vector2(0, 16)) - tl) / sc)
			var img: Image = spr.texture.get_image()
			if img.is_compressed():
				img.decompress()
			var inside: bool = px.x >= 0 and px.y >= 0 and px.x < img.get_width() and px.y < img.get_height()
			var a: float = img.get_pixelv(px).a if inside else -1.0
			if a > 0.1 or spr.modulate.a < 0.99:
				print(str(n.name), " 楼全局=", n.global_position, " tl=", tl,
					" 像素=", px, " alpha=", a, " 楼modulate=", spr.modulate.a)
		print("结果 DONE")
		quit(0)
		return true
	return false
