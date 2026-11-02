extends Node2D
## 程序化石拱桥（零素材，全代码绘制）。
##
## 每座桥对应 world.json 的 bridges[] 一项：
##   x, y, w, h     桥面（可步行）足迹（格）：横跨水道，长度 = 水道宽 + 2 格桥台，
##                   进深 5~6 格 —— 南北两侧都留着水面，才看得出是「桥」不是铺装广场。
##   cx, cy, cw, ch 桥下水面矩形（格），小船从这儿钻过（仍算水，只是不生成水碰撞）。
##
## 画法（和楼体不一样，特意不上移）：桥面**就画在足迹上**，挡墙朝南伸出去 HP 像素。
## 楼体是「屋面上移 hp + 南立面」的挤出，人站在楼前地面上脚和墙面是对齐的；
## 但人是要**站在桥面上**走的，如果桥面也整体上移，脚就会永远比铺装偏南一个 HP，
## 看起来像踩在栏杆外头。所以这里桥面留在原位，只有挡墙/拱洞向南凸出。
##
## 节点原点 = 桥面南缘西南角（世界像素），由 Objects 的 y 排序统一排序：
## 桥体把身后（北面）的东西挡住 —— 小船自北向南划、在桥下时被桥体盖住，
## 出南端才重新露出来，视觉上就是「从桥下钻过」。玩家站在桥面上时由 Arena
## 临时调高 z_index 保证可见（划船时不调，人得跟着船一起被桥挡住）。

const CELL := 8.0
const BRIDGE_H := 20.0          # 挡墙（桥面到水面的高差）视觉高度（像素）= 2.5 格
## 桥面尺寸（格）。必须是 @export：生成器把 world.json 的数据写进来后要被序列化进
## world.tscn —— 普通成员变量存不进场景，运行时读回来就是 0，桥会一片都不画（踩过）。
@export var deck_w: float = 0.0
@export var deck_h: float = 0.0
var _hp: float = BRIDGE_H

const STONE    := Color(0.60, 0.58, 0.55)      # 挡墙主色
const STONE_MD := Color(0.67, 0.65, 0.61)      # 砌块交错色
const STONE_LT := Color(0.79, 0.77, 0.73)      # 石券 / 受光边
const STONE_DK := Color(0.40, 0.39, 0.38)      # 砖缝 / 阴影
const PAVE     := Color(0.82, 0.78, 0.66)      # 桥面铺装（靠校园路面的沙色，别和墙同色）
const PAVE_DK  := Color(0.71, 0.67, 0.56)
const TUNNEL   := Color(0.07, 0.12, 0.16)      # 拱洞深处
const RAIL     := Color(0.90, 0.88, 0.84)      # 栏杆石（受光顶面）
const RAIL_DK  := Color(0.47, 0.45, 0.43)      # 栏杆立柱
const WATER    := Color(0.408, 0.573, 0.518)   # 拱洞里透出的水色（跟地面图的新水色对齐）
const SHADOW   := Color(0.0, 0.0, 0.0, 0.20)   # 投在水面上的影


func setup(data: Dictionary) -> void:
	deck_w = float(data.get("w", 1))
	deck_h = float(data.get("h", 1))
	# 原点 = 桥面南缘西南角（世界像素）→ y 排序以「南缘」为准
	position = Vector2(float(data.get("x", 0)) * CELL,
					  (float(data.get("y", 0)) + float(data.get("h", 0))) * CELL)
	queue_redraw()


func _draw() -> void:
	if deck_w <= 0.0 or deck_h <= 0.0:
		return
	var W := deck_w * CELL
	var D := deck_h * CELL
	var HP := _hp
	var rail := 5.0             # 栏杆条高

	# ---- 桥面（就画在足迹上：y ∈ [-D, 0]）----
	draw_rect(Rect2(0.0, -D, W, D), PAVE)
	var row_h := 10.0
	var r := 0
	var yy := -D
	while yy < 0.0:
		var hh: float = minf(row_h, -yy)
		draw_line(Vector2(0.0, yy), Vector2(W, yy), PAVE_DK, 1.0)
		var off: float = 0.0 if r % 2 == 0 else 16.0
		var px := off
		while px < W:
			draw_line(Vector2(px, yy), Vector2(px, yy + hh), PAVE_DK, 1.0)
			px += 32.0
		yy += row_h
		r += 1

	# ---- 北侧栏杆（远端，压在桥面北沿）----
	draw_rect(Rect2(0.0, -D, W, rail), RAIL)
	draw_line(Vector2(0.0, -D + rail), Vector2(W, -D + rail), STONE_DK, 1.0)
	_draw_posts(0.0, -D, W, rail)

	# ---- 挡墙（南立面，从桥面南沿往南凸 HP）----
	draw_rect(Rect2(0.0, 0.0, W, HP), STONE)
	# 砌石：横缝 + 错缝竖缝
	var course := 6.0
	var crow := 0
	var wy := 0.0
	while wy < HP:
		var hh2: float = minf(course, HP - wy)
		if crow % 2 == 1:
			draw_rect(Rect2(0.0, wy, W, hh2), STONE_MD)
		draw_line(Vector2(0.0, wy), Vector2(W, wy), STONE_DK, 1.0)
		var off2: float = 0.0 if crow % 2 == 0 else 10.0
		var bx := off2
		while bx < W:
			draw_line(Vector2(bx, wy), Vector2(bx, wy + hh2), STONE_DK, 1.0)
			bx += 20.0
		wy += course
		crow += 1

	# ---- 拱洞：从墙脚往上是直腿 + 半圆顶（贴水那一侧敞开）----
	var span: float = W / maxf(1.0, roundf(W / 64.0))
	var arches: int = clampi(int(roundf(W / 64.0)), 1, 8)
	var aw: float = minf(span * 0.32, HP - 5.0)     # 拱洞半宽
	var ah: float = maxf(2.0, HP - aw - 2.0)        # 直腿高
	for i in range(arches):
		var acx: float = span * (float(i) + 0.5)
		var pts := PackedVector2Array()
		pts.append(Vector2(acx - aw, HP))
		pts.append(Vector2(acx - aw, HP - ah))
		for k in range(1, 13):
			var t: float = PI + PI * float(k) / 12.0
			pts.append(Vector2(acx + cos(t) * aw, HP - ah + sin(t) * aw))
		pts.append(Vector2(acx + aw, HP))
		draw_colored_polygon(pts, TUNNEL)
		# 洞里透出的水（贴着洞底，暗示水从桥下穿过）
		draw_rect(Rect2(acx - aw + 1.0, HP - 4.0, aw * 2.0 - 2.0, 3.0), WATER)
		# 石券（浅色一圈，把洞和墙面分开）
		var rim := PackedVector2Array()
		rim.append(Vector2(acx - aw - 1.5, HP))
		rim.append(Vector2(acx - aw - 1.5, HP - ah))
		for k2 in range(1, 13):
			var t2: float = PI + PI * float(k2) / 12.0
			rim.append(Vector2(acx + cos(t2) * (aw + 1.5), HP - ah + sin(t2) * (aw + 1.5)))
		rim.append(Vector2(acx + aw + 1.5, HP - ah))
		rim.append(Vector2(acx + aw + 1.5, HP))
		draw_polyline(rim, STONE_LT, 1.0)
		# 拱心石
		draw_rect(Rect2(acx - 2.0, HP - ah - aw + 1.0, 4.0, 5.0), STONE_LT)

	# ---- 南侧栏杆（压在桥面南沿，把「桥」的边界框出来）----
	draw_rect(Rect2(0.0, -rail, W, rail), RAIL)
	draw_line(Vector2(0.0, -1.0), Vector2(W, -1.0), STONE_DK, 1.0)
	_draw_posts(0.0, -rail, W, rail)

	# ---- 墙脚在水面上的投影 ----
	draw_rect(Rect2(2.0, HP, W - 4.0, 5.0), SHADOW)

	# ---- 两端桥台（收住桥头，压在岸上）----
	draw_rect(Rect2(-3.0, -D, 3.0, D + HP), STONE_DK)
	draw_rect(Rect2(W, -D, 3.0, D + HP), STONE_DK)


## 栏杆立柱：沿栏杆条均匀撒短柱，避免成一条死板色带
func _draw_posts(x0: float, y0: float, w: float, rail: float) -> void:
	var step: float = 22.0
	var n: int = maxi(1, int(w / step))
	for i in range(n + 1):
		var px: float = minf(x0 + float(i) * step, x0 + w - 2.0)
		draw_rect(Rect2(px, y0 - 1.0, 2.0, rail + 1.0), RAIL_DK)
