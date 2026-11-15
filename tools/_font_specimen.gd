extends SceneTree
## 字体样张：同一段中英文，用当前 Noto / Silver 多个字号各画一行，出一张 PNG 人工比对。
## 每行固定高度，方便按坐标裁图对齐比较。
## 用法：
##   godot --path . --script res://tools/_font_specimen.gd --resolution 1280x720
## 产物：res://build/_font_specimen.png

const TEXT := "像素工大 宿舍楼 3号 自习空间（开放 07:00）NPC 42% abcdefg"

var _f := 0
var rows: Array = []          # [y, 高度]


func _initialize() -> void:
	var bg := ColorRect.new()
	bg.color = Color("#141a26")
	bg.size = Vector2(1280, 720)
	root.add_child(bg)

	var noto: FontFile = load("res://assets/fonts/noto_sc_game.ttf")
	var silver: FontFile = load("res://assets/fonts/silver.ttf")
	silver.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	silver.hinting = TextServer.HINTING_NONE
	silver.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED

	var plan := [
		["Noto", noto, 13],
		["Silver", silver, 16],
		["Silver", silver, 19],
		["Silver", silver, 22],
		["Silver", silver, 26],
		["Silver", silver, 32],
		["Silver", silver, 38],
	]
	var y := 6
	for p in plan:
		var size: int = p[2]
		var row_h: int = int(size * 1.9) + 6
		var tag := Label.new()
		tag.text = "%s %d" % [p[0], size]
		tag.position = Vector2(6, y)
		tag.add_theme_font_override("font", noto)
		tag.add_theme_font_size_override("font_size", 9)
		tag.add_theme_color_override("font_color", Color(0.45, 0.55, 0.65))
		root.add_child(tag)

		var l := Label.new()
		l.text = TEXT
		l.position = Vector2(90, y)
		l.add_theme_font_override("font", p[1])
		l.add_theme_font_size_override("font_size", size)
		l.add_theme_color_override("font_color", Color(0.93, 0.95, 0.97))
		root.add_child(l)

		# 参考线：这条横线一定能看出字底对齐/高度关系
		var line := ColorRect.new()
		line.color = Color(0.22, 0.30, 0.40)
		line.position = Vector2(0, y + row_h - 2)
		line.size = Vector2(1280, 1)
		root.add_child(line)

		rows.append([y, row_h])
		y += row_h
	print("[specimen] 行布局 ", rows)


func _process(_dt: float) -> bool:
	_f += 1
	if _f == 10:
		var img := root.get_texture().get_image()
		img.save_png("res://build/_font_specimen.png")
		print("[specimen] 已保存 ", img.get_size())
		return true
	return false
