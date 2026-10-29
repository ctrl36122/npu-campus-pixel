extends Node2D
## 像素工大 · 主场景
##
## 地图本体是 scenes/world.tscn（可编辑关卡：地面/建筑/树/碰撞全是真实节点），
## 本场景只负责把「世界 + 玩家 + 楼名标注 + HUD」组装起来。
##
## 想改地图内容 → 打开 scenes/world.tscn 直接拖，或者在场景树里增删节点。
## 快捷键：WASD/方向键 移动 · Shift 加速 · 滚轮 缩放 · L 楼名

const CELL := 8.0
const LabelsScript := preload("res://scripts/labels.gd")

@onready var world: Node2D = $World
@onready var player: Node2D = $Player

var labels: CanvasLayer
var hud: Label


func _ready() -> void:
	var hint := get_node_or_null("EditorHint")
	if hint != null:
		hint.queue_free()

	# 把玩家挪进世界的 Objects 节点，才能和建筑/树一起按脚底 y 排序
	var objs := world.get_node_or_null("Objects")
	if objs != null and player != null:
		player.reparent(objs, true)

	_build_labels()
	_build_hud()

	print("[像素工大] 世界就绪 · Objects 子节点 %d · 玩家位置 %s" % [
		objs.get_child_count() if objs != null else 0, str(player.position)])


# ================================================================ 楼名标注
func _build_labels() -> void:
	labels = LabelsScript.new()
	labels.name = "Labels"
	add_child(labels)
	# 从场景里读（不是从 JSON），所以在编辑器里拖动楼，楼名会跟着走
	labels.call("setup_from_world", world)


# ================================================================ HUD
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	hud = Label.new()
	hud.add_theme_font_override("font", GameTheme.font())
	hud.add_theme_font_size_override("font_size", GameTheme.FS_HEAD)
	hud.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.1, 0.9))
	hud.add_theme_constant_override("outline_size", 4)
	hud.position = Vector2(16, 12)
	hud.text = "WASD / 方向键 移动 · Shift 加速 · 滚轮 缩放 · L 楼名"
	layer.add_child(hud)


# ================================================================ 输入
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_L:
			if labels != null:
				labels.visible = not labels.visible
	elif event is InputEventMouseButton and event.pressed:
		var cam := get_viewport().get_camera_2d()
		if cam == null:
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam.zoom = (cam.zoom * 1.12).clamp(Vector2(0.6, 0.6), Vector2(4.0, 4.0))
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam.zoom = (cam.zoom / 1.12).clamp(Vector2(0.6, 0.6), Vector2(4.0, 4.0))
