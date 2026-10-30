extends SceneTree
## 坐姿对照实验：同一个人物（坐姿帧）+ 同一把椅子，只改「人相对椅子的落点」，
## 一次渲染几组并排看，挑出最像「坐在椅子上」的那个偏移。
##
## 为什么需要这个：坐姿对不对，靠算坐标算不出来 —— 椅子、人、z 层级三者
## 相互遮挡，只有真渲出来用眼睛比才行。改椅子画法或落点公式前先跑一遍。
##
## 跑法：godot --path . --script tools/_probe_sit.gd
## 产物：_scratch/sit_lab.png

const RoomProp := preload("res://net/scripts/room_prop.gd")
const FRAMES := preload("res://assets/sandbox/frames_adam.tres")
const OUT := "res://_scratch/sit_lab.png"

## 样本矩阵：每行一个「椅背高度」，每列一个「人脚底相对椅子底边的偏移」
const BACK_HEIGHTS := [10.0, 12.0]
const OFFSETS := [-7.0, -4.0, -1.0, 2.0, 5.0]
const GAP := 40.0          # 样本间距（房间局部像素）
const ROW_H := 44.0

var _frame := 0


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
	var root := Node2D.new()
	get_root().add_child(root)
	root.scale = Vector2(2.0, 2.0)

	var idx := 0
	for ri in range(BACK_HEIGHTS.size()):
		var bh: float = float(BACK_HEIGHTS[ri])
		for ci in range(OFFSETS.size()):
			var bx := 30.0 + float(ci) * GAP
			var by := 60.0 + float(ri) * ROW_H
			var off: float = float(OFFSETS[ci])
			idx += 1

			# 地面
			var fl := ColorRect.new()
			fl.color = Color("241c14")
			fl.position = Vector2(bx - 18.0, by - 34.0)
			fl.size = Vector2(36.0, 46.0)
			fl.z_index = -50
			root.add_child(fl)

			# 坐垫（人身后）
			var seat := RoomProp.new()
			root.add_child(seat)
			seat.call("setup", "chair_seat", _cells(bx - 8.0, by - bh, 16.0, bh), -1)

			# 人物：坐姿帧，脚底落在 by + off
			var holder := Node2D.new()
			holder.position = Vector2(bx, by + off)
			holder.scale = Vector2(0.375, 0.375)
			root.add_child(holder)
			var spr := AnimatedSprite2D.new()
			spr.sprite_frames = FRAMES
			spr.offset = Vector2(0, -24)
			spr.animation = &"up_sit"
			holder.add_child(spr)

			# 椅背（人前面）
			var back := RoomProp.new()
			root.add_child(back)
			back.call("setup", "chair_back", _cells(bx - 6.5, by - bh, 13.0, bh), 2)

			# 标签
			var lab := Label.new()
			lab.text = "%d/%+.0f" % [int(bh), off]
			lab.position = Vector2(bx - 8.0, by + 10.0)
			lab.add_theme_font_size_override("font_size", 7)
			lab.add_theme_color_override("font_color", Color("#8fa3b8"))
			root.add_child(lab)

	var cam := Camera2D.new()
	get_root().add_child(cam)
	cam.position = Vector2(GAP * float(OFFSETS.size()) * 0.5 + 12.0,
		60.0 + ROW_H * 0.5) * 2.0
	cam.zoom = Vector2(6.4, 6.4) / 2.0
	cam.make_current()


## 像素矩形 → setup() 要的格矩形
func _cells(x: float, y: float, w: float, h: float) -> Rect2:
	return Rect2(Vector2(x, y) / 8.0, Vector2(w, h) / 8.0)


func _shot() -> void:
	var img := get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_scratch"))
	if img.save_png(OUT) == OK:
		print("[sit] 已保存 ", OUT, " ", img.get_width(), "×", img.get_height())
	else:
		printerr("[sit] 保存失败")
