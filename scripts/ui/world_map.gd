extends Control
## 全屏校园地图 —— 对应网页版的 picker：
## 滚轮缩放、拖拽平移、点任意位置传送、放大后显示楼名。
##
## 联机下传送是「请求」不是「直接改位置」：位置由服务器权威管理，
## 所以这里只把目标世界坐标交给 Arena.request_teleport()，由服务器放人并校验落点。

signal closed

const MapData := preload("res://scripts/ui/map_data.gd")
const CAMPUS_LOCAL := Vector2(3392.0, 6400.0)
const MAP_PX := Vector2(424.0, 800.0)
const TS := 8.0                       # 小地图 1 像素 = 1 格 = 8 校园局部像素
## 缩放范围：0.7 = 比整屏略小（看全貌），8 = 能看清单栋楼
const ZOOM_MIN := 0.7
const ZOOM_MAX := 8.0

var tex: Texture2D
var campus: Node2D
var arena: Node2D
var font: Font
## 校园底图（从房间视图切回时复原，setup 里记下）
var _campus_tex: Texture2D
## 当前底图逻辑尺寸：校园常量 424×800，进房间换成房间 W×H 格
var _map_px := MAP_PX
## 房间视图模式：全屏地图换成房间平面图（房间无「传送」概念，点击不传送）
var _room_mode := false
var _room: Node2D = null
var _room_cells := Vector2.ZERO          # 房间尺寸（格），玩家点按此归一

var zoom: float = 1.0
var pan: Vector2 = Vector2.ZERO

var _img: TextureRect
var _btn_close: Button
var _bg: ColorRect
var _dragging := false
var _drag_total := 0.0
var _touches := {}
var _pinch_start := 0.0
var _pinch_base_zoom := 1.0
var _tap_pos := Vector2.ZERO
var _buildings: Array = []            # [{name, pos}]，pos 是校园局部像素（轮廓质心）
var _ready_once := false


func setup(t: Texture2D, c: Node2D, a: Node2D, f: Font) -> void:
	tex = t
	_campus_tex = t
	campus = c
	arena = a
	font = f
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_layers()
	_collect_buildings()
	_ready_once = true
	_sync_image()
	queue_redraw()


## 背景和底图都放进子节点：底图用线性过滤缩放到逻辑尺寸 MAP_PX，
## 再按 zoom 整体缩放。楼名仍在本控件的 _draw 里画，走默认过滤保持锐利。
func _build_layers() -> void:
	_bg = ColorRect.new()
	_bg.name = "Bg"
	_bg.color = Color(0.02, 0.03, 0.045, 0.9)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.show_behind_parent = true
	add_child(_bg)
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_img = TextureRect.new()
	_img.name = "MapImage"
	_img.texture = tex
	_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_img.stretch_mode = TextureRect.STRETCH_SCALE
	_img.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_img.show_behind_parent = true
	_img.size = MAP_PX
	add_child(_img)

	# 关闭按钮：手机上按不到 Esc / M，触屏按钮层万一被挡也得有出口，
	# 所以地图自己带一个明确的关闭键（点它发 closed 信号，由 online_boot 收走）。
	_btn_close = Button.new()
	_btn_close.name = "CloseBtn"
	_btn_close.text = "✕  关闭"
	_btn_close.focus_mode = Control.FOCUS_NONE
	_btn_close.mouse_filter = Control.MOUSE_FILTER_STOP
	_btn_close.add_theme_font_override("font", font)
	_btn_close.add_theme_font_size_override("font_size", 14)
	_btn_close.add_theme_color_override("font_color", Color("#e8eef5"))
	_btn_close.add_theme_color_override("font_hover_color", Color("#ffffff"))
	_btn_close.add_theme_color_override("font_pressed_color", Color("#ffffff"))
	for st in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.10, 0.14, 0.19, 0.96) if st == "normal" else Color(0.17, 0.26, 0.36, 0.98)
		sb.border_color = Color(0.44, 0.58, 0.72, 1.0)
		sb.set_border_width_all(2)
		sb.content_margin_left = 8.0
		sb.content_margin_right = 8.0
		_btn_close.add_theme_stylebox_override(st, sb)
	_btn_close.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_btn_close.offset_left = -110.0
	_btn_close.offset_top = 14.0
	_btn_close.offset_right = -14.0
	_btn_close.offset_bottom = 58.0
	_btn_close.pressed.connect(func(): closed.emit())
	add_child(_btn_close)


## 底图位置/缩放跟着当前 zoom/pan 走。
func _sync_image() -> void:
	if _img == null or not is_instance_valid(_img):
		return
	var s := _scale()
	_img.position = _origin(s)
	_img.scale = Vector2(s, s)


## 楼名锚点：world.json 的**轮廓质心**（和底图上画的楼完全对齐）。
func _collect_buildings() -> void:
	_buildings.clear()
	for b in MapData.buildings():
		if not bool(b.get("named", true)):
			continue
		_buildings.append({"name": str(b["name"]), "pos": b["pos"]})


func _process(_delta: float) -> void:
	if visible:
		_sync_image()


func _draw() -> void:
	if tex == null or not _ready_once:
		return
	_sync_image()

	var s := _scale()
	var o := _origin(s)
	var map_rect := Rect2(o, MAP_PX * s)
	draw_rect(map_rect, Color("#3c4c5e"), false, 2.0)

	# 房间视图：顶部居中标题，不画楼名（房间没有「楼」）
	if _room_mode and _room != null and is_instance_valid(_room) and font != null:
		_outlined_text(String(_room.get("data").get("name", "内景")),
			Vector2(size.x * 0.5, 22.0), 18, Color(0.95, 0.97, 1.0, 0.96))
	# 放大到一定程度才画楼名，否则会糊成一团（阈值和网页版 picker 的 1.5 一致）
	if not _room_mode and zoom >= 1.5 and font != null:
		var fs := clampi(int(round(10.0 * zoom)), 10, 20)
		var placed: Array[Rect2] = []
		for b in _buildings:
			var nm := str(b["name"])
			var mp: Vector2 = b["pos"] / CAMPUS_LOCAL * MAP_PX
			var sp: Vector2 = o + mp * s
			if sp.x < -60 or sp.x > size.x + 60 or sp.y < -20 or sp.y > size.y + 20:
				continue
			# 重叠剔除：挨太近的楼名只留先画的那个，避免放大后糊成一团
			var tw: float = font.get_string_size(nm, HORIZONTAL_ALIGNMENT_CENTER, -1, fs).x
			var r := Rect2(sp.x - tw * 0.5 - 3.0, sp.y - fs * 0.5 - 2.0, tw + 6.0, fs + 4.0)
			var hit := false
			for q in placed:
				if q.intersects(r):
					hit = true
					break
			if hit:
				continue
			placed.append(r)
			_outlined_text(nm, Vector2(sp.x, sp.y + fs * 0.35), fs,
				Color(0.95, 0.97, 1.0, 0.96))

	# 玩家位置
	for p in get_tree().get_nodes_in_group("players"):
		var mp2: Vector2
		if _room_mode and _room != null and is_instance_valid(_room):
			var pl: Vector2 = _room.to_local(p.global_position)   # 房间局部：8px/格
			mp2 = (pl / TS) / _room_cells * _map_px
		else:
			var local: Vector2 = campus.to_local(p.global_position)
			mp2 = local / CAMPUS_LOCAL * _map_px
		var sp2: Vector2 = o + mp2 * s
		var col: Color = Color(1, 1, 1) if p.is_local_player else Color("#ffb03a")
		draw_circle(sp2, 4.0, col)
		draw_arc(sp2, 4.0, 0, TAU, 12, Color(0, 0, 0, 0.7), 1.0)

	# 底部提示
	if font != null:
		# 提示按平台写：手机上「滚轮 / M / Esc」根本不存在，写了只会让人困惑
		var touch := DisplayServer.is_touchscreen_available() or OS.has_feature("mobile") \
			or OS.has_environment("XGD_TOUCH")
		var hint: String
		if _room_mode:
			if touch:
				hint = "缩放 %d%%　·　房间视图（不传送）　·　单指拖动　·　双指缩放　·　右上角关闭" % int(round(zoom * 100.0))
			else:
				hint = "缩放 %d%%　·　房间视图（不传送）　·　滚轮缩放　·　拖拽平移　·　M / Esc 关闭" % int(round(zoom * 100.0))
		else:
			if touch:
				hint = "缩放 %d%%　·　点任意位置传送　·　单指拖动　·　双指缩放　·　右上角关闭" % int(round(zoom * 100.0))
			else:
				hint = "缩放 %d%%　·　点击任意位置传送　·　滚轮缩放　·　拖拽平移　·　M / Esc 关闭" % int(round(zoom * 100.0))
		draw_rect(Rect2(0, size.y - 40, size.x, 40), Color(0.02, 0.03, 0.045, 0.92))
		draw_string(font, Vector2(0, size.y - 18), hint,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 13, Color("#9fb0bd"))


## 描边字：四向偏移画一层深色再压亮色，避免草地底色把白字吃掉
func _outlined_text(s: String, at: Vector2, fs: int, col: Color) -> void:
	for d in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
		draw_string(font, at + d, s, HORIZONTAL_ALIGNMENT_CENTER, -1, fs,
			Color(0.02, 0.04, 0.07, 0.92))
	draw_string(font, at, s, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, col)


# ---------------------------------------------------------------- 变换
func _base_scale() -> float:
	return minf(size.y * 0.84 / _map_px.y, size.x * 0.84 / _map_px.x)


func _scale() -> float:
	return _base_scale() * zoom


func _origin(s: float) -> Vector2:
	return size * 0.5 + pan - _map_px * s * 0.5


func reset_view() -> void:
	zoom = 1.0
	pan = Vector2.ZERO
	_sync_image()
	queue_redraw()


## 进建筑内景：全屏地图换成房间平面图（与右上角小图共用同一张房间底图）。
## 房间没有「传送」概念，所以 _try_teleport 在房间模式下直接 no-op。
## M 键在房间内原本被屏蔽，现在既然有房间视图，M 也能开了（见 online_boot）。
func set_room(room: Node2D) -> void:
	if room == null or not is_instance_valid(room):
		return
	var rt: Texture2D = room.get("minimap_tex")
	var sz: Vector2 = room.get("size_px")
	if rt == null or sz.x < 1.0 or sz.y < 1.0:
		return
	_room_mode = true
	_room = room
	_room_cells = sz / TS
	_map_px = _room_cells
	tex = rt
	if _img != null and is_instance_valid(_img):
		_img.texture = rt
		_img.size = _map_px
	_buildings.clear()
	reset_view()
	queue_redraw()


## 回到校园视图：复原底图、楼名、逻辑尺寸
func clear_room() -> void:
	if not _room_mode:
		return
	_room_mode = false
	_room = null
	_map_px = MAP_PX
	tex = _campus_tex
	if _img != null and is_instance_valid(_img):
		_img.texture = _campus_tex
		_img.size = MAP_PX
	_collect_buildings()
	reset_view()
	queue_redraw()


# ---------------------------------------------------------------- 交互
## 触摸设备：只用触摸事件。Godot 会把触摸也合成为鼠标事件，两套都处理会重复触发
## （表现为拖一下跳两倍、点一下传送两次）。
func _is_touch() -> bool:
	return DisplayServer.is_touchscreen_available() or OS.has_feature("mobile") \
		or OS.has_environment("XGD_TOUCH")


func _two_dist() -> float:
	var ps: Array = _touches.values()
	if ps.size() < 2:
		return 0.0
	return (ps[0] as Vector2).distance_to(ps[1] as Vector2)


func _touch_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			_tap_pos = event.position
			if _touches.size() == 2:
				_dragging = false
				_pinch_start = _two_dist()
				_pinch_base_zoom = zoom
			elif _touches.size() == 1:
				_dragging = true
				_drag_total = 0.0
		else:
			_touches.erase(event.index)
			if _touches.size() < 2:
				_pinch_start = 0.0
			if _touches.is_empty():
				_dragging = false
				# 单指轻点（几乎没拖动）→ 传送到那个位置
				if _drag_total < 12.0:
					_try_teleport(_tap_pos)
			queue_redraw()
		accept_event()
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			# 双指捏合缩放（以两指中点为锚）
			var d := _two_dist()
			if _pinch_start > 12.0 and d > 12.0:
				var ps: Array = _touches.values()
				var mid: Vector2 = ((ps[0] as Vector2) + (ps[1] as Vector2)) * 0.5
				_zoom_at(_pinch_base_zoom * (d / _pinch_start), mid)
		elif _dragging and _touches.size() == 1:
			pan += event.relative
			_drag_total += event.relative.length()
			queue_redraw()
		accept_event()


func _gui_input(event: InputEvent) -> void:
	if _is_touch():
		_touch_input(event)
		return
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(zoom * 1.18, event.position)
			accept_event()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(zoom / 1.18, event.position)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging = true
				_drag_total = 0.0
			else:
				_dragging = false
				# 拖动距离很小才算点击，避免平移地图时误传送
				if _drag_total < 6.0:
					_try_teleport(event.position)
	elif event is InputEventMouseMotion and _dragging:
		pan += event.relative
		_drag_total += event.relative.length()
		queue_redraw()
		accept_event()


## 以 at（屏幕坐标）为锚点缩放。target_zoom 就是新的 zoom 倍数，
## 不用再除 _base_scale()——_scale() 里已经乘过一次了，
## 多除一次会让「向下滚」算出比原来更大的值，表现就是只能放大不能缩小。
func _zoom_at(target_zoom: float, at: Vector2) -> void:
	var old_s := _scale()
	var map_px: Vector2 = (at - _origin(old_s)) / old_s
	zoom = clampf(target_zoom, ZOOM_MIN, ZOOM_MAX)
	var new_s := _scale()
	pan = at - (map_px * new_s) - size * 0.5 + MAP_PX * new_s * 0.5
	_sync_image()
	queue_redraw()


## 关闭按钮同样用原始触摸判定（真机上 Button 的触摸不可靠），
## 命中就吃掉事件，避免又触发一次「点哪传送到哪」。
func _input(event: InputEvent) -> void:
	if not visible or _btn_close == null or not is_instance_valid(_btn_close):
		return
	if event is InputEventScreenTouch and event.pressed \
			and _btn_close.get_global_rect().grow(10.0).has_point(event.position):
		closed.emit()
		get_viewport().set_input_as_handled()


func _try_teleport(at: Vector2) -> void:
	if _room_mode:
		return                                   # 房间视图只读，没有「传到房间某点」的概念
	if campus == null or arena == null:
		return
	var s := _scale()
	var map_px: Vector2 = (at - _origin(s)) / s
	if map_px.x < 0 or map_px.y < 0 or map_px.x > MAP_PX.x or map_px.y > MAP_PX.y:
		return                                    # 点到地图外，忽略
	var local: Vector2 = map_px * TS
	arena.request_teleport(campus.to_global(local))
	closed.emit()
