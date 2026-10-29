extends Node

func _ready() -> void:
	var s = load("res://scenes/online_boot.tscn").instantiate()
	add_child(s)
	await get_tree().create_timer(3.0).timeout
	for p in get_tree().get_nodes_in_group("players"):
		var spr = p.get_node_or_null("Visual/Sprite")
		var nm = p.get_node_or_null("Name")
		print("[diag] player=", p.name, " scale=", p.scale,
			" spr_scale=", spr.scale if spr else "none",
			" spr_global=", spr.global_scale if spr else "none",
			" spr_size=", (spr.sprite_frames.get_frame_texture(spr.animation, 0).get_size() if spr and spr.sprite_frames else "?"),
			" name_fs=", (nm.get_theme_font_size("font_size") if nm else -1))
		print("       parent=", p.get_parent().name, " parent_scale=", p.get_parent().scale,
			" gp=", p.get_parent().get_parent().name if p.get_parent().get_parent() else "-",
			" gp_scale=", p.get_parent().get_parent().scale if p.get_parent().get_parent() else "-")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://rg_c.png")
	print("[shot] rg_c")
	get_tree().quit()
