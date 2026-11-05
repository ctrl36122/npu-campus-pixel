extends SceneTree
## 猫头顶名牌的几何回归测试：位置居中、贴着脑袋、朝左不镜像、字号不随花色变。
##
## 为什么单独测：名牌的坐标要在「猫被 scale 镜像 + 花色缩放」的夹缝里算出正着的字，
## 这层逆缩放写错了肉眼很难发现（会变成镜像字或飘到半空）。
##   APPDATA=<临时目录> godot --headless --script res://tools/_test_cat_tag.gd

var fails: Array[String] = []


func _ok(cond: bool, label: String, extra := "") -> void:
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _rect_of(ci: CanvasItem, r: Rect2) -> Rect2:
	if ci == null:
		return Rect2()
	var gt := ci.get_global_transform_with_canvas()
	var a: Vector2 = gt * r.position
	var b: Vector2 = gt * (r.position + r.size)
	return Rect2(a, b - a).abs()


func _det(ci: CanvasItem) -> float:
	var t := ci.get_global_transform_with_canvas()
	return t.x.x * t.y.y - t.y.x * t.x.y


func _initialize() -> void:
	var cat_script: Script = load("res://net/scenes/Cat.gd")
	var host := Node2D.new()
	host.position = Vector2(400, 300)
	root.add_child(host)

	var cat := Node2D.new()
	cat.set_script(cat_script)
	host.add_child(cat)
	# skin 5 = 蓝猫（size 1.22），故意用非 1.0 的花色验证补偿缩放
	cat.call("setup", Vector2(100, 100), (cat_script.SKINS as Array)[5], 4242)
	_ok(cat.has_method("set_display_name"), "Cat 有 set_display_name")

	var sprite: Sprite2D = cat.get("_sprite") as Sprite2D
	_ok(sprite != null, "猫贴图已生成（素材在）")
	if sprite == null:
		print("结果 FAIL：没有贴图，后面的几何没意义")
		quit(1)
		return

	cat.call("set_display_name", "小煤球")
	var tag: Label = cat.get("_tag") as Label
	_ok(tag != null, "名牌节点已生成")
	if tag == null:
		print("结果 FAIL：没有名牌")
		quit(1)
		return
	_ok(tag.text == "小煤球", "文字正确", tag.text)
	_ok(tag.mouse_filter == Control.MOUSE_FILTER_IGNORE, "名牌不吃鼠标（否则点不到猫）")

	var body := _rect_of(sprite, Rect2(-16.5, -16.0, 33.0, 32.0))
	var trect := _rect_of(tag, Rect2(Vector2.ZERO, tag.size))
	print("  猫身 ", body, "  名牌 ", trect)

	_ok(absf(trect.get_center().x - body.get_center().x) < 1.5, "左右居中",
		"差 %.1f px" % (trect.get_center().x - body.get_center().x))
	# 贴图帧顶部约 5px 是空的（FOOT_Y=27 / 帧高 32），名牌可以压进这点空白
	_ok(trect.end.y <= body.position.y + 6.0, "名牌在画出来的头顶之上",
		"名牌底 %.1f / 帧顶 %.1f" % [trect.end.y, body.position.y])
	_ok(absf(body.position.y - trect.end.y) < 12.0, "没有飘得太高",
		"间距 %.1f px" % (body.position.y - trect.end.y))
	_ok(trect.size.y > 3.0 and trect.size.y < 12.0, "字号克制", "%.1f px 高" % trect.size.y)
	_ok(trect.size.x > 8.0 and trect.size.x < 40.0, "宽度合理", "%.1f px 宽" % trect.size.x)

	# 朝左：整体镜像后名字不能跟着翻，且仍在头顶正中
	# （游戏里 _process 每帧会把 face 写进 scale，探针这里手动同步一次）
	cat.face = -1.0
	cat.scale = Vector2(0.62 * 1.22 * -1.0, 0.62 * 1.22)
	cat.call("_sync_tag")
	var body2 := _rect_of(sprite, Rect2(-16.5, -16.0, 33.0, 32.0))
	var trect2 := _rect_of(tag, Rect2(Vector2.ZERO, tag.size))
	print("  朝左后 猫身 ", body2, "  名牌 ", trect2)
	_ok(absf(trect2.get_center().x - body2.get_center().x) < 1.5, "朝左后仍左右居中",
		"差 %.1f px" % (trect2.get_center().x - body2.get_center().x))
	_ok(trect2.end.y <= body2.position.y + 6.0, "朝左后仍在头顶之上")
	# 镜像体现在 transform 的行列式上：猫朝左时父级是负的，名牌必须是正的（字没翻）
	_ok(_det(tag) > 0.0, "名字没有左右镜像", "det=%.3f" % _det(tag))

	# 换个更小的花色：名字字号不该跟着变小
	var before := trect.size.y
	cat.call("setup", Vector2(100, 100), (cat_script.SKINS as Array)[11], 4242)  # 奶猫 size 0.72
	cat.call("_sync_tag")
	var small := _rect_of(tag, Rect2(Vector2.ZERO, tag.size)).size.y
	_ok(absf(small - before) < 1.0, "换小花色后字号不变", "%.1f → %.1f" % [before, small])

	cat.call("set_display_name", "")
	_ok(cat.get("_tag") == null, "传空串能摘掉名牌")

	print("结果 %s" % ("PASS" if fails.is_empty() else "FAIL：" + ", ".join(fails)))
	quit(0 if fails.is_empty() else 1)
