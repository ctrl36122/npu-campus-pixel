extends Node2D
## 宿舍猫窝：软垫 + 食碗，纯程序绘制（和房间家具同一套画法）。
## 原点在底边中点，挂进 room.anchor() 的 y-sort 容器里。
## 色系：棕褐色软垫 + 灰蓝色食碗

func _draw() -> void:
	# 软垫外框（底层阴影）
	draw_rect(Rect2(-12.0, -9.0, 24.0, 9.0), Color("5b4636"))
	# 软垫主体
	draw_rect(Rect2(-11.0, -8.0, 22.0, 7.0), Color("c9a97a"))
	# 软垫亮面内层
	draw_rect(Rect2(-9.0, -6.0, 18.0, 4.0), Color("e0c49a"))
	# 软垫前沿暗边（底边压痕）
	draw_rect(Rect2(-12.0, -1.0, 24.0, 1.0), Color("3f3026"))

	# 右侧食碗 - 碗外壁
	draw_rect(Rect2(14.0, -4.0, 6.0, 4.0), Color("6d8494"))
	# 食碗内部亮面
	draw_rect(Rect2(15.0, -3.0, 4.0, 2.0), Color("b9c9d2"))
	# 【新增】碗口上沿细亮边，增加碗的立体感
	draw_rect(Rect2(14.0, -4.0, 6.0, 0.8), Color("d7e2e8"))
