extends Node2D
## 宿舍猫窝：软垫 + 食碗，纯程序绘制（和房间家具同一套画法）。
## 原点在底边中点，挂进 room.anchor() 的 y-sort 容器里。

func _draw() -> void:
	# 外框 / 垫面 / 内圈 / 前沿暗边
	draw_rect(Rect2(-12.0, -9.0, 24.0, 9.0), Color("5b4636"))
	draw_rect(Rect2(-11.0, -8.0, 22.0, 7.0), Color("c9a97a"))
	draw_rect(Rect2(-9.0, -6.0, 18.0, 4.0), Color("e0c49a"))
	draw_rect(Rect2(-12.0, -1.0, 24.0, 1.0), Color("3f3026"))
	# 右侧小食碗
	draw_rect(Rect2(14.0, -4.0, 6.0, 4.0), Color("6d8494"))
	draw_rect(Rect2(15.0, -3.0, 4.0, 2.0), Color("b9c9d2"))
