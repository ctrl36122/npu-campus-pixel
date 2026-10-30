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
		"chair_seat":
			_chair_seat(o, w, h)
		"chair_back":
			_chair_back(o, w, h)
		"sofa":
			_sofa(o, w, h)
		"bed":
			_bed(o, w, h)
		"plant":
			_plant(o, w, h)
		"cushion":
			_cushion(o, w, h)
		"door":
			_door(o, w, h)
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

## 工位桌：桌面 + 显示器 + 键鼠。所有子件都按 rect 的比例算，
## 这样 2 格深的小桌和 6 格深的大桌都能用，不会出现「显示器比人还高」。
func _desk(o: Vector2, w: float, h: float) -> void:
	var front := clampf(h * 0.46, 5.0, 11.0)      # 正面（厚度）
	var rise := front
	_shadow(o, w, h, 2.0)
	# 桌体：正面 + 桌面
	draw_rect(Rect2(o.x, o.y + h - front, w, front), Color("2c3742"))
	draw_rect(Rect2(o.x, o.y + h - front, w, 1.0), Color("222a33"))
	draw_rect(Rect2(o.x, o.y - rise, w, h), Color("48586a"))
	draw_rect(Rect2(o.x, o.y - rise, w, 1.0), Color("6b8096"))
	draw_rect(Rect2(o.x, o.y - rise, 1.0, h), Color("556678"))
	draw_rect(Rect2(o.x + w - 1.0, o.y - rise, 1.0, h), Color("38434f"))
	# 桌面上的桌垫：比桌面暗一点，把屏幕和键盘衬出来
	var pad_x := o.x + w * 0.12
	var pad_w := w * 0.76
	draw_rect(Rect2(pad_x, o.y - rise + 2.0, pad_w, h - 4.0), Color(0, 0, 0, 0.13))

	# ── 显示器：宽高都跟着桌面走 ──
	var mw := clampf(w * 0.50, 11.0, 32.0)
	var mh := clampf(mw * 0.58, 7.0, 16.0)
	var mx := o.x + (w - mw) * 0.5
	var my := o.y - rise + 1.5        # 贴着桌面后沿（靠墙），前面留给键盘
	# 支架 + 底座阴影
	draw_rect(Rect2(mx + mw * 0.5 - 2.0, my + mh, 4.0, 3.0), Color("1b2228"))
	draw_rect(Rect2(mx + mw * 0.5 - 4.0, my + mh + 2.5, 8.0, 1.5), Color("161b20"))
	# 机身（外框）
	draw_rect(Rect2(mx - 1.5, my - 1.5, mw + 3.0, mh + 3.0), Color("151a1f"))
	draw_rect(Rect2(mx - 1.5, my - 1.5, mw + 3.0, 1.0), Color("39424a"))
	# 屏幕
	draw_rect(Rect2(mx, my, mw, mh), Color("9fe9ff"))
	draw_rect(Rect2(mx, my, mw, 1.0), Color("d8f7ff"))
	# 画面内容：标题条 + 两行正文 + 一个亮点，远看像在跑东西
	draw_rect(Rect2(mx + 1.5, my + 1.5, mw * 0.42, 1.5), Color(0.05, 0.28, 0.36, 0.9))
	var rows := int(maxf(2.0, (mh - 5.0) / 3.0))
	for i in range(rows):
		draw_rect(Rect2(mx + 1.5, my + 4.5 + float(i) * 3.0, mw * (0.72 - 0.1 * float(i)), 1.0),
			Color(0.05, 0.30, 0.38, 0.55))
	if mh > 9.0:
		draw_rect(Rect2(mx + mw - 4.0, my + mh - 4.0, 2.0, 2.0), Color(0.20, 0.75, 0.45, 0.9))
	# 屏幕反光
	draw_line(Vector2(mx + 1.5, my + mh - 1.5), Vector2(mx + mw * 0.35, my + 1.5),
		Color(1, 1, 1, 0.20), 1.0)

	# ── 键盘 + 鼠标：贴近桌沿，坐下时正好在手边 ──
	var kw := clampf(w * 0.46, 9.0, 26.0)
	var kh := clampf(h * 0.34, 4.0, 8.0)
	var kx := o.x + (w - kw) * 0.5
	var ky := o.y + h - front - kh - 1.0        # 落在桌面上、贴近桌沿，不压在正面
	draw_rect(Rect2(kx, ky, kw, kh), Color("232a30"))
	draw_rect(Rect2(kx, ky, kw, 1.0), Color("3f4a52"))
	var kxx := kx + 1.5
	while kxx < kx + kw - 1.5:
		draw_rect(Rect2(kxx, ky + 1.5, 1.0, kh - 3.0), Color(0.20, 0.24, 0.27, 0.9))
		kxx += 2.0
	draw_rect(Rect2(kx + kw + 2.0, ky + 1.0, 3.0, kh - 1.0), Color("2a3238"))


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


# ---------------------------------------------------------------- 椅子
#
# 尺度参照人物：人约 18px 高、11px 宽。老版本椅子是一块 26×26 的方块 ——
# 比人还大，坐进去就是「被箱子吞掉」，这也是之前怎么看都不像坐着的根因。
# 现在坐面 16×12、椅背 13×12，跟人一个量级。
#
# 椅子拆两个节点，各自在 z 轴上让路：
#   chair_seat  z = -1  坐垫与椅脚，永远在人身后
#   chair_back  z = +2  椅背，永远在人前面 —— 坐着时挡住臀腿，只露头和肩
# 一个节点做不到「一半在身后、一半在身前」，y-sort 是整块比较。
# 椅背摆哪一侧由 Room.gd 按座位朝向算，这里只管把它画成一块软包板。
# 具体落点用 tools/_probe_sit.gd 对照过（见 _scratch/sit_lab.png）。


## 坐垫 + 椅脚。rect 是椅子占地，坐垫占上面大部分，底部留给椅脚。
##
## 配色是「黑椅 + 橙色腰线」：房间整体是蓝灰色（地面、隔板、显示器全是冷色），
## 椅子再用蓝就和人身上的蓝衬衫糊在一起 —— 坐着时人和椅子分不开，根本看不出坐姿。
func _chair_seat(o: Vector2, w: float, h: float) -> void:
	var foot := clampf(h * 0.26, 3.0, 4.5)     # 椅脚高度
	var seat_h := h - foot
	var cx := o.x + w * 0.5
	_shadow(o, w, h, 2.0)

	# 椅脚：立柱 + 底盘（五爪椅在这个尺寸上分不出来）
	draw_rect(Rect2(cx - 2.0, o.y + seat_h, 4.0, foot - 1.5), Color("22262c"))
	draw_rect(Rect2(cx - 5.0, o.y + h - 1.5, 10.0, 1.5), Color("1b1f24"))

	# 坐垫比占地左右各宽 1px：椅背 13px、坐垫 18px，两侧各露 2px 坐垫，
	# 才不会被误读成「一个箱子」。
	var sx := o.x - 1.0
	var sw := w + 2.0
	draw_rect(Rect2(sx, o.y, sw, seat_h), Color("2b3038"))              # 外沿（暗）
	draw_rect(Rect2(sx + 1.0, o.y, sw - 2.0, seat_h - 2.0), Color("4a545f"))
	draw_rect(Rect2(sx + 1.0, o.y, sw - 2.0, 1.0), Color("5c6774"))     # 受光边
	draw_rect(Rect2(sx + 2.0, o.y + 2.0, sw - 4.0, seat_h - 4.0), Color("3b434e"))
	# 前沿压暗，坐垫才有厚度
	draw_rect(Rect2(sx + 1.0, o.y + seat_h - 2.0, sw - 2.0, 2.0), Color("21262c"))


## 椅背：一块立起来的软包板，比坐垫高、比人窄 —— 坐着时正好挡住臀腿、
## 露出头和肩膀，这才是「坐在椅子上」的读法。
func _chair_back(o: Vector2, w: float, h: float) -> void:
	var cx := o.x + w * 0.5
	var top := o.y + 1.0
	var bot := o.y + h - 1.5
	if bot - top < 5.0:
		bot = top + 5.0
	var body := Color("333a45")
	var hi := Color("6d7a89")
	var lo := Color("1f242a")

	# 连接件（椅背插进坐垫那一截）
	draw_rect(Rect2(cx - 2.0, bot, 4.0, 1.5), Color("1d2126"))

	# 板体：内缩矩形 + 补一层，凑出 2px 圆角
	draw_rect(Rect2(o.x + 2.0, top, w - 4.0, bot - top), body)
	draw_rect(Rect2(o.x, top + 2.0, w, bot - top - 2.0), body)
	draw_rect(Rect2(o.x + 2.0, top, w - 4.0, 1.0), hi)
	draw_rect(Rect2(o.x, top + 2.0, 1.0, bot - top - 2.0), lo)
	draw_rect(Rect2(o.x + w - 1.0, top + 2.0, 1.0, bot - top - 2.0), lo)

	# 内衬软包 + 橙色腰线（黑椅配橙条是电竞椅的经典样子，也把它和蓝衬衫分开）
	var ix := o.x + 2.0
	var iy := top + 2.5
	var iw := w - 4.0
	var ih := bot - iy - 1.0
	if iw > 4.0 and ih > 4.0:
		draw_rect(Rect2(ix, iy, iw, ih), Color("454e5a"))
		draw_rect(Rect2(ix, iy, iw, 1.0), Color(0, 0, 0, 0.18))
		if ih > 3.5:
			draw_rect(Rect2(ix, iy + ih * 0.55, iw, 1.5), Color("c2683a"))

	# 两侧扶手（露在板体外面 1px），坐着时正好在腰侧
	var ay := o.y + h * 0.45
	draw_rect(Rect2(o.x - 1.0, ay, 1.5, 3.5), Color("2b3038"))
	draw_rect(Rect2(o.x + w - 0.5, ay, 1.5, 3.5), Color("2b3038"))


# ---------------------------------------------------------------- 门

## 玻璃移门。房间南墙留了门洞，但洞外是虚空 —— 不加门就是一块纯黑，
## 看着像「墙上破了个洞」。画一扇关着的门，既盖住黑，也告诉玩家出口在哪。
func _door(o: Vector2, w: float, h: float) -> void:
	var frame := Color("59646f")
	var glass_a := Color("20303c")
	var glass_b := Color("2b4250")
	# 门框
	draw_rect(Rect2(o.x, o.y, w, h), frame)
	draw_rect(Rect2(o.x, o.y, w, 1.5), frame.lightened(0.22))
	# 两扇玻璃
	var gw := w * 0.5 - 2.0
	draw_rect(Rect2(o.x + 1.5, o.y + 2.0, gw, h - 4.0), glass_a)
	draw_rect(Rect2(o.x + 2.5, o.y + 3.0, gw - 2.0, h - 6.0), glass_b)
	draw_rect(Rect2(o.x + w * 0.5 + 0.5, o.y + 2.0, gw, h - 4.0), glass_a)
	draw_rect(Rect2(o.x + w * 0.5 + 1.5, o.y + 3.0, gw - 2.0, h - 6.0), glass_b)
	# 中缝 + 两个拉手
	draw_rect(Rect2(o.x + w * 0.5 - 0.5, o.y + 1.0, 1.0, h - 2.0), frame.darkened(0.15))
	draw_rect(Rect2(o.x + w * 0.5 - 3.0, o.y + h * 0.45, 1.5, h * 0.3), Color("8b97a3"))
	draw_rect(Rect2(o.x + w * 0.5 + 1.5, o.y + h * 0.45, 1.5, h * 0.3), Color("8b97a3"))
	# 玻璃上的斜反光
	draw_line(Vector2(o.x + 3.0, o.y + h - 3.0), Vector2(o.x + gw * 0.9, o.y + 3.0),
		Color(1, 1, 1, 0.10), 1.0)
	draw_line(Vector2(o.x + w * 0.5 + 3.0, o.y + h - 3.0), Vector2(o.x + w * 0.5 + gw * 0.9, o.y + 3.0),
		Color(1, 1, 1, 0.10), 1.0)


# ---------------------------------------------------------------- 沙发

## 朝南（面朝镜头）的沙发：靠背立在 rect 北沿，座面在它前面，
## 两端各一块扶手。休息区里正对着门口，进来第一眼就看见。
func _sofa(o: Vector2, w: float, h: float) -> void:
	var arm := clampf(w * 0.10, 2.0, 5.0)
	var back_h := clampf(h * 0.72, 6.0, 12.0)
	var body := Color("6b4f6f")
	var hi := Color("8b6a90")
	var lo := Color("4e3a52")
	_shadow(o, w, h, 3.0)

	# 靠背（往画面上方立）
	draw_rect(Rect2(o.x + arm, o.y - back_h + 2.0, w - arm * 2.0, back_h), body)
	draw_rect(Rect2(o.x + arm, o.y - back_h + 2.0, w - arm * 2.0, 1.0), hi)
	draw_rect(Rect2(o.x + arm, o.y - back_h + 2.0, 1.0, back_h), hi.darkened(0.25))
	draw_rect(Rect2(o.x + w - arm - 1.0, o.y - back_h + 2.0, 1.0, back_h), lo)
	# 靠背上的两道压线，坐下去才有「分格」的感觉
	var seg := (w - arm * 2.0) / 3.0
	for i in range(1, 3):
		draw_rect(Rect2(o.x + arm + seg * i - 0.5, o.y - back_h + 5.0, 1.0, back_h - 6.0),
			Color(0, 0, 0, 0.16))

	# 座面（被靠背压住上半截）
	draw_rect(Rect2(o.x + arm, o.y + 1.0, w - arm * 2.0, h - 1.0), Color("7d5d81"))
	draw_rect(Rect2(o.x + arm, o.y + 1.0, w - arm * 2.0, 1.0), Color("95739a"))
	draw_rect(Rect2(o.x + arm, o.y + h - 2.0, w - arm * 2.0, 2.0), lo)
	# 坐垫分两块
	draw_rect(Rect2(o.x + arm + (w - arm * 2.0) * 0.5 - 0.5, o.y + 3.0, 1.0, h - 6.0),
		Color(0, 0, 0, 0.14))

	# 扶手：比座面高一点，两侧各一块
	for sx in [o.x, o.x + w - arm]:
		draw_rect(Rect2(sx, o.y - 5.0, arm, h + 5.0), Color("5e4462"))
		draw_rect(Rect2(sx, o.y - 5.0, arm, 1.0), Color("7d5d81"))
		draw_rect(Rect2(sx + (0.0 if sx == o.x else arm - 1.0), o.y - 5.0, 1.0, h + 5.0), lo)


# ---------------------------------------------------------------- 床

## 单人床，俯视 + 微 2.5D：床架正面、床垫顶面、床头枕头、下半段盖被子。
## 头在 rect 上方（北），脚在下方 —— 宿舍里床统一头朝墙摆。
func _bed(o: Vector2, w: float, h: float) -> void:
	_shadow(o, w, h, 1.5)
	var rise := clampf(h * 0.12, 3.0, 6.0)     # 床架露出的正面高度
	# 床架正面（靠镜头那条边）
	draw_rect(Rect2(o.x, o.y + h - rise, w, rise), Color("4a3c30"))
	draw_rect(Rect2(o.x, o.y + h - rise, w, 1.0), Color("33291f"))
	# 床垫顶面（受光）
	draw_rect(Rect2(o.x, o.y - rise, w, h), Color("d8d2c4"))
	draw_rect(Rect2(o.x, o.y - rise, w, 1.0), Color("efe9dc"))
	draw_rect(Rect2(o.x, o.y - rise, 1.0, h), Color("c8c1b3"))
	draw_rect(Rect2(o.x + w - 1.0, o.y - rise, 1.0, h), Color("b4ad9f"))
	var top := o.y - rise
	# 被子：盖住下半段（脚端），头端留出枕头区
	var pillow_h := clampf(h * 0.20, 5.0, 10.0)
	var quilt_y := top + pillow_h + clampf(h * 0.06, 2.0, 4.0)
	var quilt_h := (top + h) - quilt_y - 1.0
	if quilt_h > 3.0:
		draw_rect(Rect2(o.x + 1.0, quilt_y, w - 2.0, quilt_h), Color("6d86a6"))
		draw_rect(Rect2(o.x + 1.0, quilt_y, w - 2.0, 1.0), Color("86a0c0"))
		draw_rect(Rect2(o.x + 1.0, quilt_y + quilt_h * 0.5, w - 2.0, 1.0), Color(0, 0, 0, 0.10))
		draw_rect(Rect2(o.x + 1.0, quilt_y + quilt_h - 1.0, w - 2.0, 1.0), Color(0, 0, 0, 0.16))
	# 枕头（头端，靠上）
	var pw := clampf(w * 0.72, 8.0, 22.0)
	var px := o.x + (w - pw) * 0.5
	draw_rect(Rect2(px, top + 2.0, pw, maxf(3.0, pillow_h - 1.0)), Color("f3efe6"))
	draw_rect(Rect2(px, top + 2.0, pw, 1.0), Color("ffffff"))
	draw_rect(Rect2(px, top + 2.0, 1.0, maxf(3.0, pillow_h - 1.0)), Color("e2ddd2"))
	draw_rect(Rect2(px + pw - 1.0, top + 2.0, 1.0, maxf(3.0, pillow_h - 1.0)), Color("d5cfc2"))


# ---------------------------------------------------------------- 绿植 / 坐垫

## 盆栽：花盆 + 三团叶子。房间里全是指示灯和屏幕，需要一点绿的断一下。
func _plant(o: Vector2, w: float, h: float) -> void:
	_shadow(o, w, h, 1.5)
	var pot_w := w * 0.52
	var pot_x := o.x + (w - pot_w) * 0.5
	var pot_h := clampf(h * 0.45, 4.0, 7.0)
	var pot_y := o.y + h - pot_h
	draw_rect(Rect2(pot_x, pot_y, pot_w, pot_h), Color("7d4d34"))
	draw_rect(Rect2(pot_x, pot_y, pot_w, 1.0), Color("9a6444"))
	draw_rect(Rect2(pot_x + pot_w - 1.0, pot_y, 1.0, pot_h), Color("613a26"))

	# 叶子：三团叠着长，越往上越小
	var cx := o.x + w * 0.5
	var leaf := Color("3f6b45")
	var leaf_hi := Color("548b5a")
	var top_y := pot_y - h * 0.62
	var tiers := [
		Rect2(cx - w * 0.46, pot_y - h * 0.26, w * 0.92, h * 0.30),
		Rect2(cx - w * 0.34, pot_y - h * 0.48, w * 0.68, h * 0.26),
		Rect2(cx - w * 0.22, top_y, w * 0.44, h * 0.24),
	]
	for t in tiers:
		draw_rect(t, leaf)
		draw_rect(Rect2(t.position.x, t.position.y, t.size.x, 1.0), leaf_hi)
	draw_rect(Rect2(cx - 0.5, pot_y - h * 0.30, 1.0, h * 0.30), Color("2f5236"))


## 地上的坐垫：几乎平铺，只有 2px 厚度 + 一圈包边
func _cushion(o: Vector2, w: float, h: float) -> void:
	draw_rect(Rect2(o.x, o.y - 2.0, w, h), Color("5a4a6e"))
	draw_rect(Rect2(o.x, o.y - 2.0, w, 1.0), Color("7a6890"))
	draw_rect(Rect2(o.x, o.y + h - 2.0, w, 2.0), Color("453a55"))
	draw_rect(Rect2(o.x + 2.0, o.y - 1.0, w - 4.0, h - 4.0), Color(0, 0, 0, 0.10))
