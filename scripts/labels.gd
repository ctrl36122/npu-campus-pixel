extends CanvasLayer
## 建筑名称标注层
## CanvasLayer + Label，每帧把「场景里那栋楼的贴图位置」投影成屏幕坐标。
## 因为读的是场景节点（不是 JSON），所以在编辑器里拖动建筑，楼名会跟着走。

const MIN_ZOOM := 0.75       # 视距再远就不画楼名（会糊成一团）
const LABEL_W := 132.0
const BASE_FS := 13          # 基准字号；实际字号随镜头缩放（区间 11~19，太大盖楼太小看不清）

var _labels: Array[Label] = []
var _sprites: Array[Sprite2D] = []
var _names: Array[String] = []
var _widths: Array[float] = []       # 每个标签底板的宽度（按文字长短，不浪费空间）
var _font: Font
var _cur_fs := -1


func _ready() -> void:
	layer = 2
	_font = GameTheme.font()


## 从世界场景里收集建筑（Objects 下带 Sprite 子节点的 StaticBody2D）
func setup_from_world(world: Node2D) -> void:
	for l in _labels:
		l.queue_free()
	_labels.clear()
	_sprites.clear()

	var objs := world.get_node_or_null("Objects")
	if objs == null:
		return
	for n in objs.get_children():
		if not (n is StaticBody2D):
			continue
		if n.is_in_group("props"):
			continue          # 校门/长椅/路灯/喷泉等小物件不标建筑名
		var spr: Sprite2D = n.get_node_or_null("Sprite")
		if spr == null or spr.texture == null:
			continue
		var nm := str(n.name)
		if nm == "" or nm == "无名建筑":
			continue
		var l := Label.new()
		l.text = nm
		l.add_theme_font_override("font", _font)
		l.add_theme_font_size_override("font_size", BASE_FS)
		# 按建筑类型分色：扫一眼就能分出宿舍 / 教学楼 / 食堂 / 图书馆，不用逐个读字
		var col := _color_for(nm)
		l.add_theme_color_override("font_color", col)
		l.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.10, 0.88))
		l.add_theme_constant_override("outline_size", 5)
		# 光靠描边在草地/路面上还是不够跳，再加一块深色底板（像素风：直角、不圆角）
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.04, 0.06, 0.09, 0.78)
		sb.border_color = Color(col.r, col.g, col.b, 0.55)
		sb.set_border_width_all(1)
		sb.content_margin_left = 5
		sb.content_margin_right = 5
		sb.content_margin_top = 1
		sb.content_margin_bottom = 1
		l.add_theme_stylebox_override("normal", sb)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 底板宽度跟着文字走：短名字不会因为固定 132 宽而显得空荡荡
		var tw := 0.0
		if _font != null:
			tw = _font.get_string_size(nm, HORIZONTAL_ALIGNMENT_CENTER, -1, BASE_FS).x
		var w := clampf(tw + 12.0, 46.0, LABEL_W + 40.0)
		l.size = Vector2(w, 21)
		add_child(l)
		_labels.append(l)
		_sprites.append(spr)
		_names.append(nm)
		_widths.append(w - LABEL_W)          # 存「相对 LABEL_W 的差值」，改字号时按比例缩放


## 按楼名关键字上色（比读 world.json 的类型字段简单，而且 OSM 里有些楼没填 type）
func _color_for(nm: String) -> Color:
	if nm.contains("图书馆"):
		return Color(1.0, 0.86, 0.45)          # 金：地标
	if nm.contains("餐厅") or nm.contains("食堂"):
		return Color(1.0, 0.74, 0.42)          # 橙：吃饭的地方
	if nm.contains("游泳") or nm.contains("体育"):
		return Color(0.66, 0.95, 0.95)         # 青：场馆
	if nm.contains("宿舍") or nm.contains("公寓") or nm.contains("苑"):
		return Color(0.68, 0.93, 0.70)         # 绿：住的地方
	if nm.contains("教学") or nm.contains("学院") or nm.contains("实验") or nm.contains("楼"):
		return Color(0.70, 0.86, 1.0)          # 蓝：上课的地方
	if nm.contains("门") or nm.contains("广场") or nm.contains("中心"):
		return Color(0.90, 0.88, 0.98)         # 淡紫：公共节点
	return Color(1, 1, 1, 0.95)


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return
	if cam.zoom.x < MIN_ZOOM or not visible:
		for l in _labels:
			l.visible = false
		return                       # 必须 return：否则下面的定位循环会把 visible 又设回 true

	# 字号随镜头缩放，但压窄区间：太大会盖住楼体，太小读不清
	var fs := clampi(int(round(10.5 * cam.zoom.x)), 11, 19)
	if fs != _cur_fs:
		for i in _labels.size():
			_labels[i].add_theme_font_size_override("font_size", fs)
			_labels[i].size = Vector2(LABEL_W + _widths[i] * float(fs) / float(BASE_FS),
				19.0 + float(fs - BASE_FS) * 0.6)
		_cur_fs = fs

	var xf := get_viewport().get_canvas_transform()
	var vp := get_viewport().get_visible_rect()
	var placed: Array[Rect2] = []            # 本帧已放置的标签矩形，用于避让
	for i in _labels.size():
		var spr := _sprites[i]
		var sz: Vector2 = spr.texture.get_size() * spr.global_scale
		# 贴图左上角（世界坐标）。注意不能写 get_global_position() + offset ——
		# offset 是局部单位，联机世界里校园整体 scale=2，直接加会偏一半。
		var tl: Vector2 = spr.get_global_transform() * spr.offset
		var sp_tl: Vector2 = xf * tl
		var sp_br: Vector2 = xf * (tl + sz)
		var l := _labels[i]

		# 楼在屏幕上的可见矩形（把世界矩形投到屏幕坐标）
		var rect := Rect2(sp_tl, sp_br - sp_tl).abs()
		if rect.position.x > vp.size.x + 80.0 or rect.end.x < -80.0 \
				or rect.position.y > vp.size.y + 40.0 or rect.end.y < -40.0:
			l.visible = false             # 完全出画面
			continue

		# 锚点 = 可见部分的上缘中点：
		# 巨型楼（图书馆）贴图顶缘常常在屏幕外，跟着世界坐标走会让名字
		# 飘到画面外或离楼体十万八千里；钉在「楼在屏幕上的可见顶缘」才贴脸。
		var ax: float = clampf((rect.position.x + rect.end.x) * 0.5,
			rect.position.x, rect.end.x)
		var ay: float = maxf(rect.position.y - 8.0, 6.0)   # 悬在可见顶缘上方 8px；楼顶出画面时钉在屏幕顶
		ax = clampf(ax, l.size.x * 0.5 + 4.0, vp.size.x - l.size.x * 0.5 - 4.0)
		ay = clampf(ay, 6.0, vp.size.y - 30.0)

		# 重叠避让：两栋楼锚点接近时（钉边楼尤其容易撞），后者往下挪一格标签高
		var box := Rect2(Vector2(ax, ay) - l.size * 0.5, l.size)
		var tries := 0
		while tries < 6:
			var hit := false
			for r in placed:
				if box.intersects(r):
					hit = true
					break
			if not hit:
				break
			ay += l.size.y + 2.0
			box.position = Vector2(ax, ay) - l.size * 0.5
			tries += 1

		l.position = box.position
		l.visible = true
		placed.append(box)
