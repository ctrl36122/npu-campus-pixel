extends Control
## 右上角小地图：整张校园缩略图 + 楼名 + 相机视野框 + 玩家点。
## 点一下打开全屏地图（等价网页版「点小地图开 picker」）。
##
## 楼名对应网页版 minimap 的 bold 12px 描边字。整张校园压到 158px 宽，
## 一栋楼只有几像素，全画会糊成一团，所以按楼的体量从大到小画，
## 和已经画下的名字框重叠的就跳过 —— 留下的都是大地标。

signal pressed_open

const MapData := preload("res://scripts/ui/map_data.gd")
const CAMPUS_LOCAL := Vector2(3392.0, 6400.0)
const NAME_FS := 9                   # 小地图上的楼名字号
const MIN_BOX_PX := 4.0               # 楼在小地图上小于这个宽度就不标名字
const LABEL_LIMIT := 20               # 局部视野里楼名更多，上限放宽（仍有防重叠）
## 常态显示「自己周边」多少格：100×200 格 ≈ 屏幕可见范围（80×45 格）的 1.2×4.4，
## 比整张校园（212×400）放大 4 倍多，楼和路都能看清。点开是整张校园的全屏地图。
const VIEW_CELLS := Vector2(100.0, 200.0)
const CELL_PX := 8.0

var tex: Texture2D
var campus: Node2D
var font: Font
var _img: TextureRect
var _atlas: AtlasTexture
var _view_size := VIEW_CELLS * CELL_PX      # 800 × 1600（校园局部像素）
var _view_origin := Vector2.ZERO            # 当前视野左上角（校园局部像素）

var _buildings: Array = []            # [{name, pos, w}]  pos 是校园局部像素，w 是楼宽（局部像素）
var last_names: int = 0              # 上一帧实际画出的名字数（调试用）


func setup(t: Texture2D, c: Node2D, f: Font) -> void:
	tex = t
	campus = c
	font = f
	# PASS 而不是 STOP：左键在本控件里被 accept_event 吃掉，
	# 但滚轮会继续往下传，落到玩家的 _unhandled_input 去缩放镜头。
	# 用 STOP 的话鼠标停在小地图上滚轮就失效了。
	mouse_filter = Control.MOUSE_FILTER_PASS
	_build_image_node()
	_collect_buildings()
	queue_redraw()


## 底图交给子 TextureRect 画：它用线性过滤把高清底图（1696×3200）缩小到 158×298，
## 比在本控件里 draw_texture_rect（默认最近邻，8~10 倍缩小会严重走样）干净得多；
## 而本控件自己的 draw_string 仍走默认过滤，楼名保持锐利。
func _build_image_node() -> void:
	_atlas = AtlasTexture.new()
	_atlas.atlas = tex
	_atlas.region = Rect2(Vector2.ZERO, tex.get_size() * 0.5)
	if _img != null and is_instance_valid(_img):
		_img.texture = _atlas
		return
	_img = TextureRect.new()
	_img.name = "MapImage"
	_img.texture = _atlas
	_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_img.stretch_mode = TextureRect.STRETCH_SCALE
	_img.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_img.show_behind_parent = true
	add_child(_img)
	_img.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## 楼名位置：直接用 world.json 的**轮廓质心**（MapData 已按格算好并转成局部像素）。
## 以前取「贴图顶部中心」= 2.5D 屋顶，比地面高出一截，名字才会整体偏北、各偏各的。
func _collect_buildings() -> void:
	_buildings.clear()
	var added := 0
	for b in MapData.buildings():
		if not bool(b.get("named", true)):
			continue
		_buildings.append({
			"name": MapData.short_name(str(b["name"])),
			"pos": b["pos"],
			"w": float(b["w_cells"]) * 8.0,
		})
		added += 1
		if added >= LABEL_LIMIT:
			break


func _process(_delta: float) -> void:
	_follow_player()
	queue_redraw()


## 裁切窗口跟着本地玩家：先置中，再夹在地图边界内（走到边上时自己不再居中）
func _follow_player() -> void:
	if tex == null or campus == null:
		return
	var c := _local_local_pos()
	_view_origin = c - _view_size * 0.5
	_view_origin.x = clampf(_view_origin.x, 0.0, maxf(0.0, CAMPUS_LOCAL.x - _view_size.x))
	_view_origin.y = clampf(_view_origin.y, 0.0, maxf(0.0, CAMPUS_LOCAL.y - _view_size.y))
	if _atlas != null:
		# 底图是校园的一半分辨率（1696×3200），裁切区域也要折半
		_atlas.region = Rect2(_view_origin * 0.5, _view_size * 0.5)


func _local_local_pos() -> Vector2:
	for p in get_tree().get_nodes_in_group("players"):
		if p.get("is_local_player") == true:
			return campus.to_local(p.global_position)
	return CAMPUS_LOCAL * 0.5


func _draw() -> void:
	if tex == null or campus == null:
		return
	# 底图由子节点 MapImage 画（见 _build_image_node），这里只画上层元素。
	draw_rect(Rect2(Vector2.ZERO, size), Color("#2c3a49"), false, 1.0)

	_draw_names()
	_draw_viewport_box()
	_draw_players()


## 楼名：大地标优先，画过的框挡住后来者（避免几十个名字叠成一坨）
func _draw_names() -> void:
	if font == null:
		return
	var placed: Array[Rect2] = []
	for b in _buildings:
		var box_px: float = float(b["w"]) / _view_size.x * size.x
		if box_px < MIN_BOX_PX:
			continue
		var nm := str(b["name"])
		var tw: float = font.get_string_size(nm, HORIZONTAL_ALIGNMENT_CENTER, -1, NAME_FS).x
		var mp: Vector2 = _to_mini_local(b["pos"] as Vector2)
		var r := Rect2(mp - Vector2(tw * 0.5 + 2.0, NAME_FS * 0.5 + 1.0),
			Vector2(tw + 4.0, NAME_FS + 3.0))
		if r.position.x < 0 or r.end.x > size.x or r.position.y < 0 or r.end.y > size.y:
			continue
		var hit := false
		for q in placed:
			if q.intersects(r):
				hit = true
				break
		if hit:
			continue
		placed.append(r)
		_outlined_text(nm, Vector2(mp.x, mp.y + NAME_FS * 0.35), Color(0.95, 0.97, 1.0, 0.95))
	last_names = placed.size()


## 相机可见范围
func _draw_viewport_box() -> void:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		return
	var span: Vector2 = get_viewport().get_visible_rect().size / cam.zoom
	var c: Vector2 = cam.global_position
	var a := _to_mini(c - span * 0.5)
	var b := _to_mini(c + span * 0.5)
	var r := Rect2(a, b - a)
	# 先深后浅：局部视野放大后底图是亮草地/米色路，单画白线根本看不见
	draw_rect(r, Color(0, 0, 0, 0.45), false, 3.0)
	draw_rect(r, Color(1, 0.98, 0.9, 0.95), false, 1.5)


## 玩家：自己白点，别人橙点
func _draw_players() -> void:
	for p in get_tree().get_nodes_in_group("players"):
		var mp := _to_mini(p.global_position)
		var col: Color = Color(1, 1, 1) if p.is_local_player else Color("#ffb03a")
		# 深色底 + 亮色芯，浅色底图上也一眼看到自己
		draw_rect(Rect2(mp - Vector2(4, 4), Vector2(8, 8)), Color(0, 0, 0, 0.55))
		draw_rect(Rect2(mp - Vector2(2.5, 2.5), Vector2(5, 5)), col)


## 描边字：八向深色描边 + 1px 投影，深色底板上也能看清（像素风不要抗锯齿模糊）
func _outlined_text(s: String, at: Vector2, col: Color) -> void:
	var offs := [
		Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1),
		Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1),
	]
	for d in offs:
		draw_string(font, at + d, s, HORIZONTAL_ALIGNMENT_CENTER, -1, NAME_FS,
			Color(0.02, 0.03, 0.05, 0.95))
	draw_string(font, at + Vector2(0, 1), s, HORIZONTAL_ALIGNMENT_CENTER, -1, NAME_FS,
		Color(0, 0, 0, 0.45))
	draw_string(font, at, s, HORIZONTAL_ALIGNMENT_CENTER, -1, NAME_FS, col)


func _to_mini(world_pos: Vector2) -> Vector2:
	return _to_mini_local(campus.to_local(world_pos))


func _to_mini_local(local_pos: Vector2) -> Vector2:
	return (local_pos - _view_origin) / _view_size * size


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		pressed_open.emit()
		accept_event()
