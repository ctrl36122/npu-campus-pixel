extends Node2D
## 程序化石拱桥（零素材，全代码绘制）。
##
## 每座桥对应 world.json 的 bridges[] 一项：
##   x, y, w, h     甲板（可步行）足迹（格），长边沿东西向跨过水道；
##                   甲板 = 桥下水面 + 四周 1 格，所以「可步行区 == 桥面视觉区」，
##                   玩家在桥上走不会被当成踩水。
##   cx, cy, cw, ch  桥下水面矩形（格），小船从这儿钻过。
##
## 节点原点设在甲板「南缘」西南角（世界像素），由 Objects 的 y 排序统一排序：
## 桥体像楼一样把身后（北面）的东西挡住 —— 小船自北向南划、在桥下时正好被挡住，
## 出南端后再出现，视觉上就是「从桥下钻过」。玩家站在甲板上时由 Arena 临时调高
## z_index 保证可见（否则会和被桥体挡住north面的东西一样被遮）。

const CELL := 8.0
const BRIDGE_H := 22.0          # 桥体（栏杆/挡墙）的视觉高度（像素）

const STONE    := Color(0.60, 0.58, 0.55)
const STONE_LT := Color(0.78, 0.76, 0.72)
const STONE_DK := Color(0.40, 0.39, 0.38)
const TUNNEL   := Color(0.09, 0.15, 0.19)
const RAIL     := Color(0.86, 0.84, 0.80)

var _w: float = 0.0
var _h: float = 0.0
var _hp: float = BRIDGE_H


func setup(data: Dictionary) -> void:
	_w = float(data.get("w", 1)) * CELL
	_h = float(data.get("h", 1)) * CELL
	# 原点 = 甲板南缘西南角（世界像素）→ y 排序以「南缘」为准
	position = Vector2(float(data.get("x", 0)) * CELL,
					  (float(data.get("y", 0)) + float(data.get("h", 0))) * CELL)
	queue_redraw()


func _draw() -> void:
	if _w <= 0.0 or _h <= 0.0:
		return
	var W := _w
	var D := _h
	var HP := _hp

	# ---- 桥面（顶面，抬高 HP）----
	draw_rect(Rect2(0.0, -D - HP, W, D), STONE_LT)
	# 铺装石板缝（横向）
	var seami := int(D / 6.0)
	for i in range(1, seami):
		var yy := -D - HP + float(i) * 6.0
		draw_line(Vector2(2.0, yy), Vector2(W - 2.0, yy), STONE, 1.0)
	# 中线（浅）
	draw_line(Vector2(W * 0.5, -D - HP + 2.0), Vector2(W * 0.5, -HP - 2.0), STONE, 1.0)
	# 远侧（北）栏杆高光
	draw_rect(Rect2(0.0, -D - HP, W, 2.0), RAIL)

	# ---- 南侧挡墙（前脸，最后画，挡住桥下小船）----
	draw_rect(Rect2(0.0, -HP, W, HP), STONE)
	# 砖缝（横向）
	for i in range(1, 4):
		var yy := -HP * float(i) / 4.0
		draw_line(Vector2(0.0, yy), Vector2(W, yy), STONE_DK, 1.0)
	# 拱洞（南面正中，深色，暗示船从这儿钻过）
	var rw: float = min(W * 0.42, 46.0)
	var ah: float = HP * 0.92
	draw_rect(Rect2(W * 0.5 - rw, -ah, rw * 2.0, ah), TUNNEL)
	# 近侧（南）栏杆高光
	draw_rect(Rect2(0.0, -HP - 2.0, W, 2.0), RAIL)

	# ---- 两端桥台（伸入岸/水的石块）----
	draw_rect(Rect2(-4.0, -D - HP, 4.0, D + HP), STONE_DK)
	draw_rect(Rect2(W, -D - HP, 4.0, D + HP), STONE_DK)
