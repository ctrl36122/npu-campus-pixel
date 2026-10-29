extends Node2D
## 一盏路灯：竖杆 + 悬臂 + 灯头，全部程序绘制（零素材）。
## origin = 杆底（地面锚点）。挂进 Objects 参与 y 排序；加 "props" 组避开透视墙判定。
## 夜间光晕由 Arena 的 NightGlow 层在灯头位置叠加（本脚本只画实体）。

const POLE_H := 13.0        # 杆高（校园局部像素，×2 世界显示 ≈ 3.2 格）
const ARM := 4.0            # 悬臂长

var _face := 1.0            # 悬臂朝向（1 右 / -1 左），生成时随机


func setup(face: float) -> void:
	_face = face
	queue_redraw()


func _draw() -> void:
	var pole := Color(0.22, 0.24, 0.28)
	var pole_lite := Color(0.38, 0.41, 0.46)
	# 杆身（两段色做出立体感）
	draw_rect(Rect2(Vector2(-1.0, -POLE_H), Vector2(1.2, POLE_H)), pole)
	draw_rect(Rect2(Vector2(0.2, -POLE_H), Vector2(0.5, POLE_H)), pole_lite)
	# 底座
	draw_rect(Rect2(Vector2(-1.6, -1.2), Vector2(3.2, 1.4)), pole)
	# 悬臂朝马路一侧弯过去
	draw_rect(Rect2(Vector2(0.0 if _face > 0.0 else -ARM, -POLE_H - 0.8), Vector2(ARM, 1.0)), pole)
	# 灯头（罩 + 灯芯；灯芯白天是灰白，夜里被 NightGlow 光晕盖住也无妨）
	var hx := (ARM - 1.2) * _face
	draw_rect(Rect2(Vector2(hx - 1.4, -POLE_H - 2.2), Vector2(2.8, 1.2)), pole)
	draw_rect(Rect2(Vector2(hx - 1.0, -POLE_H - 1.2), Vector2(2.0, 0.9)), Color(0.95, 0.93, 0.82))
