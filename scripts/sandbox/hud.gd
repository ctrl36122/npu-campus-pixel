extends CanvasLayer
## Phase 1 调试 HUD：显示操作提示、所在格坐标、帧率

@export var player_path: NodePath = ^"../Player"
@export var tile_size: int = 16

var _lbl: Label


func _ready() -> void:
	layer = 5
	_lbl = Label.new()
	_lbl.add_theme_font_override("font", GameTheme.font())
	_lbl.add_theme_font_size_override("font_size", GameTheme.FS_HEAD)
	_lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_lbl.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.10, 0.9))
	_lbl.add_theme_constant_override("outline_size", 4)
	_lbl.position = Vector2(14, 10)
	add_child(_lbl)


func _process(_delta: float) -> void:
	var p := get_node_or_null(player_path)
	if p == null or _lbl == null:
		return
	var tile: Vector2 = p.position / float(tile_size)
	_lbl.text = "WASD / 方向键 移动 · Shift 加速　|　所在格 (%0.1f, %0.1f) · FPS %d" % [
		tile.x, tile.y, Engine.get_frames_per_second()]
