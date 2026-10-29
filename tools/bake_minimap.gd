extends SceneTree
## 头less 预烘焙小地图（user://minimap_cache_v20.png），让编辑器首次运行不再做
## 昂贵的像素重绘，避免 AI 插件在 play 启动的重负载下掉线。
## 用法：godot --headless --path . --script res://tools/bake_minimap.gd

const ArenaScript := preload("res://net/scenes/Arena.gd")

func _initialize() -> void:
	var a: Node = ArenaScript.new()
	var tex: Variant = a.call("_build_minimap_texture")
	if tex != null:
		print("[bake_minimap] 已烘焙 尺寸=%dx%d" % [tex.get_width(), tex.get_height()])
	else:
		printerr("[bake_minimap] 烘焙失败")
	quit(0)
