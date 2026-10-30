extends SceneTree
## 家具一览：把 room_prop.gd 里每种 kind 各画一个，排成网格截图。
## 改家具画法时用它对照，不用每次进房间猜「那块棕的是什么」。
##
## 跑法：godot --path . --script tools/_probe_props.gd
## 产物：_scratch/props_sheet.png

const RoomProp := preload("res://net/scripts/room_prop.gd")
const OUT := "res://_scratch/props_sheet.png"
const CELL := 96.0            # 每个格子边长（像素）
const ZOOM := 4.0

var _frame := 0
var _root: Node2D

## kind → [宽格, 深格]
const ITEMS := [
	["desk", 6.0, 2.0],
	["chair_seat", 2.0, 1.5],
	["chair_back", 1.75, 1.375],
	["table", 4.0, 2.0],
	["sofa", 6.0, 2.0],
	["plant", 2.0, 1.6],
	["cushion", 2.0, 1.5],
	["block", 2.0, 2.0],
	["vending", 3.0, 2.0],
	["board", 3.0, 2.0],
	["wall", 3.0, 2.0],
]


func _initialize() -> void:
	RenderingServer.set_default_clear_color(Color("12171e"))


func _process(_d: float) -> bool:
	_frame += 1
	if _frame == 2:
		_build()
	elif _frame == 12:
		_shot()
		quit()
		return true
	return false


func _build() -> void:
	_root = Node2D.new()
	get_root().add_child(_root)
	# 每格 96px 世界里放一件家具，家具按 8px/格 画，所以整图放大 2 倍看
	_root.scale = Vector2(2.0, 2.0)

	var cols := 6
	for i in range(ITEMS.size()):
		var it: Array = ITEMS[i]
		var gx := float(i % cols) * CELL
		var gy := float(i / cols) * CELL
		var w: float = it[1]
		var h: float = it[2]
		# 家具底边中点放在格子底部中央偏上，留出往上涨的空间
		var base := Vector2(gx + CELL * 0.5, gy + CELL - 20.0)
		var r := Rect2(base.x - w * 8.0 * 0.5, base.y - h * 8.0, w * 8.0, h * 8.0)

		var p := RoomProp.new()
		p.set_script(RoomProp)
		_root.add_child(p)
		p.call("setup", String(it[0]), cell_rect(r))

		var lab := Label.new()
		lab.text = String(it[0])
		lab.position = Vector2(gx + 4.0, gy + 2.0)
		lab.add_theme_font_size_override("font_size", 9)
		lab.add_theme_color_override("font_color", Color("#9fb0bf"))
		_root.add_child(lab)

		# 格子底：一条浅色地面，方便看清阴影和脚
		var floor_rect := ColorRect.new()
		floor_rect.color = Color("2a2119")
		floor_rect.position = Vector2(gx + 2.0, gy + 14.0)
		floor_rect.size = Vector2(CELL - 4.0, CELL - 16.0)
		floor_rect.z_index = -10
		_root.add_child(floor_rect)

	var cam := Camera2D.new()
	get_root().add_child(cam)
	var rows := int(ceil(float(ITEMS.size()) / float(cols)))
	cam.position = Vector2(CELL * cols * 0.5, CELL * rows * 0.5) * 2.0
	var fit := minf(1280.0 / (CELL * cols * 2.0), 720.0 / (CELL * rows * 2.0)) * 0.98
	cam.zoom = Vector2(fit, fit)
	cam.make_current()


## setup() 吃的是「格」，这里把像素矩形换算回去
func cell_rect(r: Rect2) -> Rect2:
	return Rect2(r.position / 8.0, r.size / 8.0)


func _shot() -> void:
	var img := get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_scratch"))
	if img.save_png(OUT) == OK:
		print("[props] 已保存 ", OUT, " ", img.get_width(), "×", img.get_height())
	else:
		printerr("[props] 保存失败")
