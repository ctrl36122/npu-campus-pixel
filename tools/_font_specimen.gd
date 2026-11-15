extends SceneTree
## 字体样张 v3：同一行字配不同描边宽度，用来核对「描边把像素字笔画吃掉」的问题。
## 用法：godot --path . --script res://tools/_font_specimen.gd --resolution 1280x720
## 产物：res://build/_font_specimen.png

const TEXT := "教学西楼B座 · 按 E 进入 · 图书馆"

var _f := 0


func _initialize() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#141a26")
	bg.size = Vector2(1280, 720)
	root.add_child(bg)

	var silver: FontFile = load("res://assets/fonts/silver.ttf")
	silver.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	silver.hinting = TextServer.HINTING_NONE
	silver.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED

	var y := 10
	for plan in [[0, "0 无描边"], [1, "1px"], [2, "2px（现在用的）"],
			[3, "3px"], [4, "4px（旧版粗黑体的值）"], [5, "5px（旧版楼名的值）"]]:
		var w: int = plan[0]
		var row_h := 62
		# 模拟游戏里楼名压在草地/路面上的底色
		var grass := ColorRect.new()
		grass.color = Color(0.30, 0.46, 0.28)
		grass.position = Vector2(0, y)
		grass.size = Vector2(1280, row_h)
		root.add_child(grass)

		var l := Label.new()
		l.text = TEXT
		l.position = Vector2(220, y + 8)
		l.add_theme_font_override("font", silver)
		l.add_theme_font_size_override("font_size", 25)
		l.add_theme_color_override("font_color", Color(0.93, 0.95, 0.98))
		l.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 1.0))
		l.add_theme_constant_override("outline_size", w)
		root.add_child(l)

		var tag := Label.new()
		tag.text = plan[1]
		tag.position = Vector2(10, y + 18)
		tag.add_theme_font_override("font", silver)
		tag.add_theme_font_size_override("font_size", 19)
		tag.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0))
		tag.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 1.0))
		tag.add_theme_constant_override("outline_size", 1)
		root.add_child(tag)

		y += row_h
	print("[specimen] 描边对照共 6 行")


func _process(_dt: float) -> bool:
	_f += 1
	if _f == 8:
		var img := root.get_texture().get_image()
		img.save_png("res://build/_font_specimen.png")
		print("[specimen] 已保存 ", img.get_size())
		return true
	return false
