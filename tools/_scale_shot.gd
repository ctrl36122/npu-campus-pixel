extends Node2D
## 临时：在真实的 campus scale=2 层级下，对比不同缩放的角色尺寸。

const WORLD: PackedScene = preload("res://scenes/world.tscn")
const FRAMES: SpriteFrames = preload("res://assets/sandbox/frames_adam.tres")
const TS := 8.0
const CAMPUS_SCALE := 2.0

var _cam: Camera2D


func _ready() -> void:
	var w := WORLD.instantiate()
	w.scale = Vector2(CAMPUS_SCALE, CAMPUS_SCALE)
	add_child(w)
	var objs: Node2D = w.get_node("Objects")

	# 三排：0.5（现状）/ 0.375 / 0.3125，挂在 Objects（和玩家一致）
	var rows := [
		[0.5, 344.0],
		[0.375, 350.0],
		[0.3125, 356.0],
	]
	for r in rows:
		var sc: float = r[0]
		var y: float = r[1]
		for i in 4:
			_add(objs, Vector2(382 + i * 5, y), sc)

	_cam = Camera2D.new()
	add_child(_cam)
	_cam.zoom = Vector2(1.6, 1.6)
	_cam.position = Vector2(391 * TS * CAMPUS_SCALE, 350 * TS * CAMPUS_SCALE)
	_cam.make_current()
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://scale_compare.png")
	print("[shot] compare")
	get_tree().quit()


func _add(parent: Node, cell: Vector2, sc: float) -> void:
	var holder := Node2D.new()
	holder.position = cell * TS
	parent.add_child(holder)
	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = FRAMES
	spr.animation = &"down_idle"
	spr.offset = Vector2(0, -24)
	spr.scale = Vector2(sc, sc)
	holder.add_child(spr)
