extends SceneTree
## 临时工具：裁一块截图并放大，用来检查像素级细节（比如坐姿对不对）。
##   XGD_CROP="x,y,w,h,scale" XGD_SRC=res://shot_verify.png
## 输出 res://_scratch/crop.png

func _initialize() -> void:
	var src := OS.get_environment("XGD_SRC")
	if src == "":
		src = "res://shot_verify.png"
	var spec := OS.get_environment("XGD_CROP")
	if spec == "":
		spec = "440,230,240,140,4"
	var parts := spec.split(",")
	if parts.size() < 5:
		print("[crop] XGD_CROP 需要 5 个数：x,y,w,h,scale")
		quit(1)
		return
	var x := int(parts[0])
	var y := int(parts[1])
	var w := int(parts[2])
	var h := int(parts[3])
	var scale := float(parts[4])

	var img := Image.load_from_file(ProjectSettings.globalize_path(src))
	if img == null:
		print("[crop] 读不到 ", src)
		quit(1)
		return
	w = mini(w, img.get_width() - x)
	h = mini(h, img.get_height() - y)
	if w <= 0 or h <= 0:
		print("[crop] 裁剪区域越界")
		quit(1)
		return

	var part := img.get_region(Rect2i(x, y, w, h))
	part.resize(int(w * scale), int(h * scale), Image.INTERPOLATE_NEAREST)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_scratch"))
	part.save_png(ProjectSettings.globalize_path("res://_scratch/crop.png"))
	print("[crop] 已保存 res://_scratch/crop.png ", part.get_width(), "x", part.get_height())
	quit(0)
