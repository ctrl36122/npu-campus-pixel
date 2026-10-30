extends Node2D
## 房间里的一件家具 / 一段隔断。按 kind 程序化绘制，零素材，跟校园同一套画法。
##
## 节点原点放在矩形「底边中点」：y-sort 拿 position.y 就是物体落脚的那条线，
## 与玩家按脚部排序的规则一致，人走到桌子后面才会被挡，而不是永远浮在上面。
##
## 三维感统一用「向上挤出 rise 像素 + 正面暗、顶面亮」表达，
## 跟校园建筑的 2.5D 挤出是同一套语言（只是这里高度小得多）。

const TS := 8.0

# 各类家具的挤出高度（像素，局部 8px/格空间）
const RISE_WALL := 13.0
const RISE_TABLE := 8.0
const RISE_DESK := 9.0
const RISE_BOARD := 8.0
const RISE_BOX := 7.0

var kind: String = "table"
var cell := Rect2()


func setup(k: String, r: Rect2, z: int = 0) -> void:
	kind = k
	cell = r
	position = Vector2(r.get_center().x * TS, r.end.y * TS)
	# z_index 在 y-sort 容器里优先于 y 比较。椅子靠它把「主体」压到所有人下面、
	# 「坐面前沿」抬到所有人上面 —— 一个节点没法同时做到这两件事。
	z_index = z
	queue_redraw()


func _draw() -> void:
	var w := cell.size.x * TS
	var h := cell.size.y * TS
	if w < 1.0 or h < 1.0:
		return
	var o := Vector2(-w * 0.5, -h)          # 矩形左上角（局部）
	match kind:
		"wall":
			_wall(o, w, h)
		"desk":
			_desk(o, w, h)
		"board":
			_board(o, w, h)
		"vending":
			_vending(o, w, h)
		"pit":
			_pit(o, w, h)
		"chair":
			_chair(o, w, h)
		"chair_front":
			_chair_front(o, w, h)
		"deco":
			_crate(o, w, h, Color("4a5b46"), Color("36452f"))   # 绿植箱 / 空调
		"block":
			_crate(o, w, h, Color("6b563e"), Color("4e3f2d"))
		_:
			_table(o, w, h)


# ---------------------------------------------------------------- 通用小块

## 落地阴影：宽比物体小一圈、贴着底边，画在正面之前
func _shadow(o: Vector2, w: float, h: float, spread: float = 2.0) -> void:
	draw_rect(Rect2(o.x + spread, o.y + h - 3.0, w - spread * 2.0, 5.0), Color(0, 0, 0, 0.30))


## 木箱 / 柜子一类：顶面亮、正面暗，加一圈包边
func _crate(o: Vector2, w: float, h: float, top: Color, face: Color) -> void:
	_shadow(o, w, h, 1.5)
	draw_rect(Rect2(o.x, o.y + h - RISE_BOX, w, RISE_BOX), face)
	draw_rect(Rect2(o.x, o.y - RISE_BOX, w, h), top)
	draw_rect(Rect2(o.x, o.y - RISE_BOX, w, 1.0), top.lightened(0.22))
	draw_rect(Rect2(o.x, o.y - RISE_BOX, 1.0, h), top.lightened(0.10))
	draw_rect(Rect2(o.x + w - 1.0, o.y - RISE_BOX, 1.0, h), top.darkened(0.25))
	# 包边十字
	draw_rect(Rect2(o.x, o.y - RISE_BOX + h * 0.5 - 0.5, w, 1.0), top.darkened(0.30))


# ---------------------------------------------------------------- 隔断墙

func _wall(o: Vector2, w: float, h: float) -> void:
	_shadow(o, w, h)
	# 正面（背光）
	draw_rect(Rect2(o.x, o.y + h - RISE_WALL, w, RISE_WALL), Color("39414b"))
	draw_rect(Rect2(o.x, o.y + h - RISE_WALL, w, 1.0), Color("2b323b"))
	# 顶面（受光）
	draw_rect(Rect2(o.x, o.y - RISE_WALL, w, h), Color("5a6470"))
	draw_rect(Rect2(o.x, o.y - RISE_WALL, w, 1.0), Color("7f8b99"))
	draw_rect(Rect2(o.x, o.y - RISE_WALL, 1.0, h), Color("69737f"))
	draw_rect(Rect2(o.x + w - 1.0, o.y - RISE_WALL, 1.0, h), Color("4b535e"))
	# 顶面的板缝：每 16px 一道，看得出是拼起来的隔板
	var xx := 16.0
	while xx < w - 2.0:
		draw_rect(Rect2(o.x + xx, o.y - RISE_WALL, 1.0, h), Color(0, 0, 0, 0.12))
		xx += 16.0


# ---------------------------------------------------------------- 桌子

func _table(o: Vector2, w: float, h: float) -> void:
	_shadow(o, w, h)
	# 桌体侧面
	draw_rect(Rect2(o.x, o.y + h - RISE_TABLE, w, RISE_TABLE), Color("4a3a28"))
	draw_rect(Rect2(o.x, o.y + h - RISE_TABLE, w, 1.0), Color("3a2d1e"))
	# 桌面
	draw_rect(Rect2(o.x, o.y - RISE_TABLE, w, h), Color("7a6144"))
	draw_rect(Rect2(o.x, o.y - RISE_TABLE, w, 1.0), Color("9c7f5b"))
	draw_rect(Rect2(o.x, o.y - RISE_TABLE, 1.0, h), Color("8a6f4e"))
	draw_rect(Rect2(o.x + w - 1.0, o.y - RISE_TABLE, 1.0, h), Color("5f4a33"))
	# 木纹
	var yy := o.y - RISE_TABLE + 5.0
	while yy < o.y - RISE_TABLE + h - 3.0:
		draw_rect(Rect2(o.x + 4.0, yy, w - 8.0, 1.0), Color(0.10, 0.08, 0.06, 0.22))
		yy += 6.0


# ---------------------------------------------------------------- 工位（桌子 + 显示器 + 键盘）

func _desk(o: Vector2, w: float, h: float) -> void:
	_shadow(o, w, h)
	draw_rect(Rect2(o.x, o.y + h - RISE_DESK, w, RISE_DESK), Color("2c3742"))
	draw_rect(Rect2(o.x, o.y + h - RISE_DESK, w, 1.0), Color("222a33"))
	draw_rect(Rect2(o.x, o.y - RISE_DESK, w, h), Color("48586a"))
	draw_rect(Rect2(o.x, o.y - RISE_DESK, w, 1.0), Color("6b8096"))
	draw_rect(Rect2(o.x, o.y - RISE_DESK, 1.0, h), Color("556678"))
	draw_rect(Rect2(o.x + w - 1.0, o.y - RISE_DESK, 1.0, h), Color("38434f"))

	# 显示器：立在桌面靠后，屏幕朝镜头
	var mw := minf(w * 0.64, 46.0)
	var mh := 20.0
	var mx := o.x + (w - mw) * 0.5
	var my := o.y - RISE_DESK + 4.0
	# 底座阴影 + 支架
	draw_rect(Rect2(mx + 2.0, my + mh + 2.0, mw, 3.0), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(mx + mw * 0.5 - 3.0, my + mh + 1.0, 6.0, 4.0), Color("1b2228"))
	# 机身
	draw_rect(Rect2(mx - 2.0, my - 2.0, mw + 4.0, mh + 4.0), Color("151a1f"))
	draw_rect(Rect2(mx - 2.0, my - 2.0, mw + 4.0, 1.0), Color("39424a"))
	# 屏幕（冷白偏青，跟夜间窗光一个色系）
	draw_rect(Rect2(mx, my, mw, mh), Color("9fe9ff"))
	draw_rect(Rect2(mx, my, mw, 1.0), Color("d8f7ff"))
	# 画面内容：标题条 + 两行正文 + 一个亮点，远看像在跑程序
	draw_rect(Rect2(mx + 2.0, my + 2.0, mw * 0.42, 2.0), Color(0.05, 0.28, 0.36, 0.9))
	draw_rect(Rect2(mx + 2.0, my + 7.0, mw * 0.74, 1.0), Color(0.05, 0.30, 0.38, 0.55))
	draw_rect(Rect2(mx + 2.0, my + 11.0, mw * 0.58, 1.0), Color(0.05, 0.30, 0.38, 0.55))
	draw_rect(Rect2(mx + 2.0, my + 15.0, mw * 0.44, 1.0), Color(0.05, 0.30, 0.38, 0.40))
	draw_rect(Rect2(mx + mw - 6.0, my + mh - 5.0, 3.0, 3.0), Color(0.20, 0.75, 0.45, 0.9))
	# 屏幕反光
	draw_line(Vector2(mx + 2.0, my + mh - 2.0), Vector2(mx + mw * 0.35, my + 2.0), Color(1, 1, 1, 0.22), 1.0)

	# 键盘：靠近桌子前沿，玩家坐下时正好在手边
	var kw := minf(w * 0.5, 34.0)
	var kx := o.x + (w - kw) * 0.5
	var ky := o.y + h - RISE_DESK - 13.0
	draw_rect(Rect2(kx, ky, kw, 9.0), Color("232a30"))
	draw_rect(Rect2(kx, ky, kw, 1.0), Color("3f4a52"))
	var kxx := kx + 2.0
	while kxx < kx + kw - 2.0:
		draw_rect(Rect2(kxx, ky + 2.0, 1.0, 6.0), Color(0.20, 0.24, 0.27, 0.9))
		kxx += 2.0
	# 鼠标
	draw_rect(Rect2(kx + kw + 3.0, ky + 2.0, 4.0, 7.0), Color("2a3238"))


# ---------------------------------------------------------------- 白板

func _board(o: Vector2, w: float, h: float) -> void:
	# 白板是「立」着的：支架脚贴底边，板面往上立，所以可见高度只有 rect 的一部分
	var foot := minf(h * 0.26, 12.0)            # 支架露出的高度
	var bottom := o.y + h - foot                # 板面底边
	var bh := minf(h * 0.74, h - foot + 10.0)   # 板面高
	var top := bottom - bh
	# 支架
	draw_rect(Rect2(o.x + w * 0.5 - 2.0, bottom - 3.0, 4.0, foot + 3.0), Color("4b525a"))
	draw_rect(Rect2(o.x + w * 0.5 - w * 0.24, o.y + h - 3.0, w * 0.48, 3.0), Color("3a4048"))
	# 板面厚度（下沿一条暗边，表示有厚度）
	draw_rect(Rect2(o.x, bottom - 3.0, w, 3.0), Color("8d99a5"))
	# 板面
	draw_rect(Rect2(o.x, top, w, bh), Color("e9eff5"))
	draw_rect(Rect2(o.x, top, w, 1.0), Color("ffffff"))
	draw_rect(Rect2(o.x, top, 1.0, bh), Color("c9d3dc"))
	draw_rect(Rect2(o.x + w - 1.0, top, 1.0, bh), Color("b3bfc9"))
	draw_rect(Rect2(o.x, top + bh - 1.0, w, 1.0), Color("b9c4ce"))
	# 板上的字迹
	var cx := o.x + 5.0
	var cy := top + 6.0
	draw_rect(Rect2(cx, cy, w * 0.44, 1.0), Color(0.16, 0.22, 0.30, 0.55))
	draw_rect(Rect2(cx, cy + 5.0, w * 0.62, 1.0), Color(0.16, 0.22, 0.30, 0.42))
	draw_rect(Rect2(cx, cy + 10.0, w * 0.34, 1.0), Color(0.16, 0.22, 0.30, 0.42))
	draw_rect(Rect2(cx + w * 0.56, cy + 7.0, 7.0, 7.0), Color(0.85, 0.35, 0.30, 0.5))
	# 笔槽
	draw_rect(Rect2(o.x + 1.0, bottom - 5.0, w - 2.0, 2.0), Color("6d7780"))


# ---------------------------------------------------------------- 贩卖机

func _vending(o: Vector2, w: float, h: float) -> void:
	_shadow(o, w, h)
	var rise := 8.0
	# 正面 / 顶面
	draw_rect(Rect2(o.x, o.y + h - rise, w, rise), Color("4a2b57"))
	draw_rect(Rect2(o.x, o.y + h - rise, w, 1.0), Color("3a1f45"))
	draw_rect(Rect2(o.x, o.y - rise, w, h), Color("6b3f7d"))
	draw_rect(Rect2(o.x, o.y - rise, w, 1.0), Color("8d5aa2"))
	draw_rect(Rect2(o.x, o.y - rise, 1.0, h), Color("7d4b90"))
	draw_rect(Rect2(o.x + w - 1.0, o.y - rise, 1.0, h), Color("50305e"))
	# 玻璃橱窗
	var gx := o.x + 3.0
	var gy := o.y - rise + 5.0
	var gw := w * 0.56
	var gh := h * 0.50
	draw_rect(Rect2(gx, gy, gw, gh), Color("1d2b33"))
	# 货架 + 饮料
	for row in range(3):
		var ry := gy + 3.0 + row * (gh - 6.0) / 3.0
		draw_rect(Rect2(gx + 2.0, ry + 6.0, gw - 4.0, 1.0), Color("3a4a52"))
		var bx := gx + 3.0
		while bx < gx + gw - 5.0:
			var tints := [Color("d05a4e"), Color("4f9ad0"), Color("d9b04a")]
			draw_rect(Rect2(bx, ry, 3.0, 6.0), tints[(row + int(bx)) % 3])
			bx += 5.0
	# 玻璃反光
	draw_line(Vector2(gx + 2.0, gy + gh - 3.0), Vector2(gx + gw * 0.45, gy + 3.0), Color(1, 1, 1, 0.16), 2.0)
	# 按钮面板 + 出货口
	var px := o.x + w * 0.68
	draw_rect(Rect2(px, o.y - rise + 7.0, 9.0, 13.0), Color("2f2b36"))
	draw_rect(Rect2(px + 2.0, o.y - rise + 9.0, 5.0, 2.0), Color("6de08a"))
	draw_rect(Rect2(o.x + 3.0, o.y + h - 12.0, w - 6.0, 6.0), Color("141018"))
	draw_rect(Rect2(o.x + 3.0, o.y + h - 12.0, w - 6.0, 1.0), Color("2b2233"))


# ---------------------------------------------------------------- 地下室开口

## SkyOffice 原图里这是通往地下室的楼梯口。纯黑一块太扎眼（远看像两台电视），
## 改画成「下沉区域」：切口一圈边 + 往下的台阶，暗但有层次，仍然不可通行。
func _pit(o: Vector2, w: float, h: float) -> void:
	draw_rect(Rect2(o.x, o.y, w, h), Color("1b1f25"))
	# 台阶：越深越暗
	var n := 5
	for i in range(n):
		var t := float(i) / float(n)
		var yy := o.y + 5.0 + t * (h - 10.0)
		var c := Color("2a303a").darkened(t * 0.32)
		draw_rect(Rect2(o.x + 5.0, yy, w - 10.0, 5.0), c)
		draw_rect(Rect2(o.x + 5.0, yy, w - 10.0, 1.0), c.lightened(0.26))
	# 切口边：上沿压暗（光被挡住），下沿提亮（受光）
	draw_rect(Rect2(o.x, o.y, w, 5.0), Color(0, 0, 0, 0.40))
	draw_rect(Rect2(o.x, o.y + h - 2.0, w, 2.0), Color("454d58"))
	draw_rect(Rect2(o.x + w - 2.0, o.y, 2.0, h), Color("3d444e"))
	draw_rect(Rect2(o.x, o.y, 2.0, h), Color("232830"))


## 椅子比其它件小一圈。rect 是「占地」（1×2 格），椅子本体只画在靠底的那一块，
## 上方留空就是坐人的位置——玩家站到那儿会被 y-sort 排到椅子后面，看着像坐下了。
##
## 三件套：靠背（深色、比坐面高）、坐面（亮木色、中间压暗表示软垫）、
## 一圈轮廓线。只画一个方块的话，远看跟木箱没区别。
## 坐面的**前沿薄条**（只有 12px 高），z_index 抬到人之上，专门用来盖住坐着的人的腿。
## 椅子主体是另一个节点（z_index 压到人之下），所以「身后有椅背、身前有坐沿」
## 才能同时成立 —— 单个节点要么整个人被吞、要么人整个浮在椅子前。
func _chair_front(o: Vector2, w: float, h: float) -> void:
	draw_rect(Rect2(o.x, o.y, w, h), Color("b07a45"))
	draw_rect(Rect2(o.x, o.y, w, 1.0), Color("c98d52"))     # 前沿高光
	draw_rect(Rect2(o.x, o.y, 1.0, h), Color("a06c3c"))
	draw_rect(Rect2(o.x + w - 1.0, o.y, 1.0, h), Color("83552c"))
	draw_rect(Rect2(o.x, o.y + h - 1.0, w, 1.0), Color("7a4f26"))
	draw_rect(Rect2(o.x + 2.0, o.y + 2.0, w - 4.0, h - 3.0), Color(0, 0, 0, 0.10))


func _chair(o: Vector2, w: float, h: float) -> void:
	var seat := minf(w, h * 0.5)
	var sx := o.x + (w - seat) * 0.5
	var sy := o.y + h - seat
	_shadow(Vector2(sx, sy), seat, seat, 1.0)

	# 靠背：立在坐面后沿，比坐面窄一点、更高
	var bw := seat - 2.0
	var bx := o.x + (w - bw) * 0.5
	var bh := 15.0
	var by := sy - bh + 4.0
	draw_rect(Rect2(bx, by, bw, bh), Color("7a4f2c"))
	draw_rect(Rect2(bx, by, bw, 1.0), Color("9a663a"))
	draw_rect(Rect2(bx, by, 1.0, bh), Color("8a5a33"))
	draw_rect(Rect2(bx + bw - 1.0, by, 1.0, bh), Color("5e3d1e"))
	draw_rect(Rect2(bx + 2.0, by + bh * 0.52, bw - 4.0, 1.0), Color(0, 0, 0, 0.20))

	# 坐面
	draw_rect(Rect2(sx, sy, seat, seat), Color("b07a45"))
	draw_rect(Rect2(sx, sy, seat, 1.0), Color("c98d52"))
	draw_rect(Rect2(sx, sy, 1.0, seat), Color("a06c3c"))
	draw_rect(Rect2(sx + seat - 1.0, sy, 1.0, seat), Color("83552c"))
	draw_rect(Rect2(sx, sy + seat - 1.0, seat, 1.0), Color("7a4f26"))
	# 坐垫内凹
	draw_rect(Rect2(sx + 3.0, sy + 3.0, seat - 6.0, seat - 6.0), Color(0, 0, 0, 0.12))
