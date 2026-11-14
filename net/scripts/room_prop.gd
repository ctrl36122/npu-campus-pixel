extends Node2D
## 房间里的一件家具 / 一段隔断。按 kind 程序化绘制，零素材，跟校园同一套画法。
##
## 节点原点放在矩形「底边中点」：y-sort 拿 position.y 就是物体落脚的那条线，
## 与玩家按脚部排序的规则一致，人走到桌子后面才会被挡，而不是永远浮在上面。
##
## 三维感统一用「向上挤出 rise 像素 + 正面暗、顶面亮」表达，
## 跟校园建筑的 2.5D 挤出是同一套语言（只是这里高度小得多）。

const TS := 8.0

# ── 外部素材贴图 ──────────────────────────────────────────────────────────
# 图书馆休息区用了两套第三方素材缩出来的贴图：摊开的旧书、沙发与扶手椅。
# 这两张图**可能在仓库里不存在**（沙发包没有授权文件，按 .gitignore 处理），
# 所以用运行时 load 而不是 preload —— preload 在文件缺失时会让整个脚本编译失败，
# 那样整间房都进不去。缺图时各自回退到原来那套程序绘制。
const BOOK_W := 32
const BOOK_H := 18
const SOFA_W := 64
const SOFA_H := 54
const CHAIR_W := 22
const CHAIR_H := 26

static var _books_tex: Texture2D = null
static var _seats_tex: Texture2D = null
static var _books_probed := false
static var _seats_probed := false


static func books_tex() -> Texture2D:
	if not _books_probed:
		_books_probed = true
		if ResourceLoader.exists("res://assets/room_books.png"):
			_books_tex = load("res://assets/room_books.png")
	return _books_tex


static func seats_tex() -> Texture2D:
	if not _seats_probed:
		_seats_probed = true
		if ResourceLoader.exists("res://assets/room_seats.png"):
			_seats_tex = load("res://assets/room_seats.png")
	return _seats_tex

# 各类家具的挤出高度（像素，局部 8px/格空间）
const RISE_WALL := 13.0
const RISE_TABLE := 8.0
const RISE_DESK := 9.0
const RISE_BOARD := 8.0
const RISE_BOX := 7.0

var kind: String = "table"
var cell := Rect2()
## 亮房（图书馆自习空间）：墙/桌面换成浅色，宿舍与活动室保持原样。
var bright := false
## 同类道具换款式用的下标：沙发/扶手椅选哪一张、摊开的书选哪一色。
## 由房间数据里的 "v" 字段带进来，默认 0。
var variant: int = 0
## 桌面小物（书 / 水杯 / 笔记本 / 电脑 / 笔筒 / 台灯）。由数据挂在桌子 prop 上，
## 跟桌面一起画；只有图书馆的自习桌带这个字段，其它房间的桌子保持空数组。
var items: Array = []


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
		"window":
			_window(o, w, h)
		"rail":
			_rail(o, w, h)
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
		"sofa_sprite":
			_sofa_sprite(o, w, h)
		"armchair":
			_armchair(o, w, h)
		"bed":
			_bed(o, w, h)
		"plant":
			_plant(o, w, h)
		"cushion":
			_cushion(o, w, h)
		"door":
			_door(o, w, h)
		"elevator":
			_elevator(o, w, h)
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


# ---------------------------------------------------------------- 中庭护栏

## 中庭四边的矮玻璃护栏：亮房里是浅蓝白，暗房里是灰金属。
## 横向段（w>=h）画一根顶杆 + 等距立柱；纵向段反过来画一根侧杆 + 横档。
## 它带碰撞但不画成实墙 —— 中庭要透得出去，才有「镂空」的感觉。
func _rail(o: Vector2, w: float, h: float) -> void:
	var glass := Color(0.82, 0.92, 0.96, 0.55) if bright else Color(0.30, 0.36, 0.42, 0.80)
	var bar := Color("f7fcff") if bright else Color("8794a0")
	var post := Color(0.62, 0.77, 0.85, 0.85) if bright else Color("5c6873")
	draw_rect(Rect2(o.x, o.y + h - 2.0, w, 2.0), Color(0, 0, 0, 0.20))
	if w >= h:
		draw_rect(Rect2(o.x, o.y - 5.0, w, h + 5.0), glass)
		draw_rect(Rect2(o.x, o.y - 6.0, w, 2.0), bar)
		draw_rect(Rect2(o.x, o.y - 3.0, w, 1.0), post)
		var xx := o.x
		while xx < o.x + w:
			draw_rect(Rect2(xx, o.y - 6.0, 2.0, h + 6.0), post)
			xx += 12.0
	else:
		draw_rect(Rect2(o.x, o.y, w, h), glass)
		draw_rect(Rect2(o.x, o.y, 2.0, h), bar)
		var yy := o.y
		while yy < o.y + h:
			draw_rect(Rect2(o.x, yy, w, 2.0), post)
			yy += 12.0


# ---------------------------------------------------------------- 隔断墙

func _wall(o: Vector2, w: float, h: float) -> void:
	_shadow(o, w, h)
	# 亮房的墙是米白涂料，暗房是深灰隔板 —— 同一套挤出画法，只换色
	var face := Color("b9c6d2") if bright else Color("39414b")
	var face_lo := Color("a3b3c1") if bright else Color("2b323b")
	var top := Color("e6eef4") if bright else Color("5a6470")
	var top_hi := Color("ffffff") if bright else Color("7f8b99")
	var top_l := Color("f2f7fb") if bright else Color("69737f")
	var top_r := Color("c3d0db") if bright else Color("4b535e")
	# 正面（背光）
	draw_rect(Rect2(o.x, o.y + h - RISE_WALL, w, RISE_WALL), face)
	draw_rect(Rect2(o.x, o.y + h - RISE_WALL, w, 1.0), face_lo)
	# 顶面（受光）
	draw_rect(Rect2(o.x, o.y - RISE_WALL, w, h), top)
	draw_rect(Rect2(o.x, o.y - RISE_WALL, w, 1.0), top_hi)
	draw_rect(Rect2(o.x, o.y - RISE_WALL, 1.0, h), top_l)
	draw_rect(Rect2(o.x + w - 1.0, o.y - RISE_WALL, 1.0, h), top_r)
	# 顶面的板缝：每 16px 一道，看得出是拼起来的隔板
	var xx := 16.0
	while xx < w - 2.0:
		draw_rect(Rect2(o.x + xx, o.y - RISE_WALL, 1.0, h), Color(0, 0, 0, 0.12))
		xx += 16.0


## 落地窗：贴在墙内侧、往上长出一截亮玻璃。不画落地阴影（窗不是家具），
## 也不参与碰撞。只用在 bright 房间，暗房里没有这个 kind。
func _window(o: Vector2, w: float, h: float) -> void:
	var top := o.y - 16.0
	var wh := h + 16.0
	# 外框
	draw_rect(Rect2(o.x, top, w, wh), Color("f4f8fb"))
	# 玻璃：上半是天空、下半略暖（窗外地面反光）
	draw_rect(Rect2(o.x + 2.0, top + 2.0, w - 4.0, wh - 4.0), Color("bfe3f5"))
	draw_rect(Rect2(o.x + 2.0, top + 2.0, w - 4.0, wh * 0.42), Color("e2f4ff"))
	draw_rect(Rect2(o.x + 2.0, top + wh * 0.62, w - 4.0, wh * 0.22), Color("d7ecdf"))
	# 窗棂：竖向每 24px 一道 + 中间一道横档
	var xx := o.x + 24.0
	while xx < o.x + w - 4.0:
		draw_rect(Rect2(xx, top + 2.0, 2.0, wh - 4.0), Color("f4f8fb"))
		xx += 24.0
	draw_rect(Rect2(o.x + 2.0, top + wh * 0.5, w - 4.0, 2.0), Color("f4f8fb"))
	# 窗台：一条亮边把窗和地板接起来
	draw_rect(Rect2(o.x - 1.0, o.y + h - 2.0, w + 2.0, 2.0), Color("ffffff"))


# ---------------------------------------------------------------- 桌子

func _table(o: Vector2, w: float, h: float) -> void:
	_shadow(o, w, h)
	# 亮房是浅枫木自习桌，暗房是深胡桃木 —— 木纹画法两边共用
	var side := Color("9c8560") if bright else Color("4a3a28")
	var side_lo := Color("7e6b4c") if bright else Color("3a2d1e")
	var top := Color("dcc39a") if bright else Color("7a6144")
	var top_hi := Color("f0dcb8") if bright else Color("9c7f5b")
	var top_l := Color("e8d2ac") if bright else Color("8a6f4e")
	var top_r := Color("b89e78") if bright else Color("5f4a33")
	# 桌体侧面
	draw_rect(Rect2(o.x, o.y + h - RISE_TABLE, w, RISE_TABLE), side)
	draw_rect(Rect2(o.x, o.y + h - RISE_TABLE, w, 1.0), side_lo)
	# 桌面
	draw_rect(Rect2(o.x, o.y - RISE_TABLE, w, h), top)
	draw_rect(Rect2(o.x, o.y - RISE_TABLE, w, 1.0), top_hi)
	draw_rect(Rect2(o.x, o.y - RISE_TABLE, 1.0, h), top_l)
	draw_rect(Rect2(o.x + w - 1.0, o.y - RISE_TABLE, 1.0, h), top_r)
	# 木纹
	var yy := o.y - RISE_TABLE + 5.0
	while yy < o.y - RISE_TABLE + h - 3.0:
		draw_rect(Rect2(o.x + 4.0, yy, w - 8.0, 1.0), Color(0.10, 0.08, 0.06, 0.22))
		yy += 6.0
	# 桌面小物：同一个节点、同一次 _draw()，永远压在桌面上、又不参与 y-sort。
	# 独立 prop 的底边 y 比桌子小会被桌面盖掉；抬 z_index 又会盖住站在桌前的人。
	for it in items:
		if it is Dictionary:
			_desktop_item(it, o)


# ---------------------------------------------------------------- 桌面小物
#
# 图书馆每张桌一套不同的书 / 水杯 / 摊开的笔记本 / 笔记本电脑 / 笔筒 / 小台灯。
# 尺寸都在 7~14px（人物约 18px 高），用实线色块画，不引入任何素材。
# 坐标是「相对桌子 rect 左上角的像素」：桌面顶面画在 o.y-RISE_TABLE，
# 所以 py 取 -5.5~0.5 正好落在桌面靠里的那半边。

func _desktop_item(it: Dictionary, o: Vector2) -> void:
	var r := Rect2(o.x + float(it.get("px", 0.0)), o.y + float(it.get("py", -4.0)),
		float(it.get("pw", 10.0)), float(it.get("ph", 8.0)))
	var tints := [Color("b8544a"), Color("3f7396"), Color("5c8a58"),
		Color("c4933c"), Color("7a5a9c")]
	var t := int(it.get("t", 0)) % tints.size()
	var c: Color = tints[t]
	match String(it.get("k", "book")):
		"book":
			_d_book(r, c, t)
		"bookopen":
			_d_bookopen(r, t)
		"cup":
			_d_cup(r, c)
		"laptop":
			_d_laptop(r, c)
		"notebook":
			_d_notebook(r, c)
		"pen":
			_d_pen(r, c, t)
		"lamp":
			_d_lamp(r)


## 书堆：三本横叠，封面颜色错开，每本露一道书页白边
func _d_book(r: Rect2, c: Color, t: int) -> void:
	var shades := [c, c.darkened(0.24), c.lightened(0.16)]
	var step := maxf(2.0, r.size.y / 3.4)
	for i in range(3):
		var yy := r.position.y + float(i) * step
		var off := float((i + t) % 2)
		draw_rect(Rect2(r.position.x + off, yy, r.size.x - off, 2.3), shades[i])
		draw_rect(Rect2(r.position.x + off + 1.0, yy + 1.4, r.size.x - off - 2.0, 0.7), Color("f3ecdc"))
		draw_rect(Rect2(r.position.x + off, yy, r.size.x - off, 0.6), Color(1, 1, 1, 0.25))


## 摊开的旧书（外部素材，四色可选）。桌面小物里比程序画的半开书更像
## 「有人正在读这一页」，休息区的茶几上各放一本。
## 素材缺失时退回画一本摊开的笔记本 —— 尺寸对得上，不会留下空位。
func _d_bookopen(r: Rect2, t: int) -> void:
	var tex := books_tex()
	if tex == null:
		_d_notebook(r, Color("b8544a"))
		return
	var idx := absi(t) % 4
	draw_texture_rect_region(tex, r, Rect2(float(idx * BOOK_W), 0.0, BOOK_W, BOOK_H))


## 水杯：白瓷杯身 + 有色饮品 + 杯口 + 把手
func _d_cup(r: Rect2, c: Color) -> void:
	var bw := r.size.x - 2.5
	draw_rect(Rect2(r.position.x + 0.5, r.position.y + 1.5, bw, r.size.y - 2.0), Color("e9f1f3"))
	draw_rect(Rect2(r.position.x + 0.5, r.position.y + 1.5, 1.0, r.size.y - 2.0), Color("ffffff"))
	draw_rect(Rect2(r.position.x + bw - 0.5, r.position.y + 2.0, 1.2, r.size.y - 3.0), Color("a9bcc4"))
	draw_rect(Rect2(r.position.x + 0.5, r.position.y + 1.5, bw, 1.2), c.darkened(0.12))
	draw_rect(Rect2(r.position.x + 0.2, r.position.y, bw + 0.6, 1.5), Color("ffffff"))
	draw_rect(Rect2(r.position.x + r.size.x - 2.0, r.position.y + 3.0, 1.8, 3.2), Color("d8e4e8"))


## 笔记本电脑：立起来的屏幕 + 键盘底座
func _d_laptop(r: Rect2, c: Color) -> void:
	var sw := r.size.x - 1.0
	var sh := r.size.y * 0.62
	draw_rect(Rect2(r.position.x + 0.5, r.position.y, sw, sh), Color("3a464f"))
	draw_rect(Rect2(r.position.x + 1.5, r.position.y + 1.0, sw - 2.0, sh - 2.0), Color("d5ecf5"))
	draw_rect(Rect2(r.position.x + 1.5, r.position.y + 1.0, sw - 2.0, 1.2), c)
	var ky := r.position.y + sh + 0.6
	draw_rect(Rect2(r.position.x, ky, r.size.x, r.size.y - sh - 0.6), Color("b7c6cd"))
	draw_rect(Rect2(r.position.x + 1.0, ky + 0.6, r.size.x - 2.0, 1.0), Color("8d9ea8"))


## 摊开的笔记本：有色封面边 + 中缝 + 两页横线
func _d_notebook(r: Rect2, c: Color) -> void:
	draw_rect(Rect2(r.position.x, r.position.y, r.size.x, r.size.y - 1.0), Color("f6f2e7"))
	draw_rect(Rect2(r.position.x, r.position.y, r.size.x, 0.8), Color("ffffff"))
	draw_rect(Rect2(r.position.x, r.position.y, 2.0, r.size.y - 1.0), c)
	draw_rect(Rect2(r.position.x + r.size.x * 0.5 - 0.5, r.position.y + 1.0, 1.0, r.size.y - 2.0), Color("c9c2b2"))
	for i in range(2):
		var yy := r.position.y + 2.4 + float(i) * 2.0
		draw_rect(Rect2(r.position.x + 3.0, yy, r.size.x * 0.35, 0.7), Color(0.20, 0.26, 0.32, 0.42))
		draw_rect(Rect2(r.position.x + r.size.x * 0.5 + 2.0, yy, r.size.x * 0.36, 0.7),
			Color(0.20, 0.26, 0.32, 0.32))


## 笔筒：三支不同颜色的笔从筒口伸出来
func _d_pen(r: Rect2, c: Color, t: int) -> void:
	var colors := [c, Color("d0a03c"), Color("4a6f9c")]
	for i in range(3):
		draw_rect(Rect2(r.position.x + 1.5 + float(i) * 2.0,
			r.position.y - 1.0 + float(i % 2) * 1.5, 1.2, 5.0), colors[(t + i) % colors.size()])
	draw_rect(Rect2(r.position.x + 0.8, r.position.y + 3.0, r.size.x - 1.6, r.size.y - 3.5), Color("627887"))
	draw_rect(Rect2(r.position.x + 0.8, r.position.y + 3.0, r.size.x - 1.6, 0.8), Color("a8bcc6"))


## 小台灯：底座 + 立杆 + 暖色灯罩（亮房里只给一点暖，不刺眼）
func _d_lamp(r: Rect2) -> void:
	var cx := r.position.x + r.size.x * 0.5
	draw_rect(Rect2(cx - 0.6, r.position.y + 3.0, 1.2, r.size.y - 4.0), Color("7d8b95"))
	draw_rect(Rect2(r.position.x + 1.0, r.position.y + r.size.y - 1.6, r.size.x - 2.0, 1.6), Color("596a75"))
	draw_rect(Rect2(r.position.x + 1.0, r.position.y + 1.0, r.size.x - 2.0, 3.0), Color("f1dca9"))
	draw_rect(Rect2(r.position.x + 2.2, r.position.y, r.size.x - 4.4, 1.2), Color("fff3d0"))
	draw_rect(Rect2(r.position.x + 1.0, r.position.y + 4.0, r.size.x - 2.0, 0.8),
		Color(1.0, 0.85, 0.52, 0.45))


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

	# 亮房用浅蓝灰布椅，暗房用深灰电竞椅。椅子是画面里数量最多的物件，
	# 不跟着换色的话 26 把深色椅子会把整间亮房戳成一片黑点。
	var foot_c := Color("8b9299") if bright else Color("22262c")
	var base_c := Color("767e86") if bright else Color("1b1f24")
	var rim_c := Color("7d8b99") if bright else Color("2b3038")
	var seat_c := Color("a9bcc9") if bright else Color("4a545f")
	var hi_c := Color("d5e4ee") if bright else Color("5c6774")
	var inner_c := Color("98adbc") if bright else Color("3b434e")
	var front_c := Color("6d7c89") if bright else Color("21262c")

	# 椅脚：立柱 + 底盘（五爪椅在这个尺寸上分不出来）
	draw_rect(Rect2(cx - 2.0, o.y + seat_h, 4.0, foot - 1.5), foot_c)
	draw_rect(Rect2(cx - 5.0, o.y + h - 1.5, 10.0, 1.5), base_c)

	# 坐垫比占地左右各宽 1px：椅背 13px、坐垫 18px，两侧各露 2px 坐垫，
	# 才不会被误读成「一个箱子」。
	var sx := o.x - 1.0
	var sw := w + 2.0
	draw_rect(Rect2(sx, o.y, sw, seat_h), rim_c)                         # 外沿（暗）
	draw_rect(Rect2(sx + 1.0, o.y, sw - 2.0, seat_h - 2.0), seat_c)
	draw_rect(Rect2(sx + 1.0, o.y, sw - 2.0, 1.0), hi_c)                 # 受光边
	draw_rect(Rect2(sx + 2.0, o.y + 2.0, sw - 4.0, seat_h - 4.0), inner_c)
	# 前沿压暗，坐垫才有厚度
	draw_rect(Rect2(sx + 1.0, o.y + seat_h - 2.0, sw - 2.0, 2.0), front_c)


## 椅背：一块立起来的软包板，比坐垫高、比人窄 —— 坐着时正好挡住臀腿、
## 露出头和肩膀，这才是「坐在椅子上」的读法。
func _chair_back(o: Vector2, w: float, h: float) -> void:
	var cx := o.x + w * 0.5
	var top := o.y + 1.0
	var bot := o.y + h - 1.5
	if bot - top < 5.0:
		bot = top + 5.0
	var body := Color("7d8b99") if bright else Color("333a45")
	var hi := Color("d5e4ee") if bright else Color("6d7a89")
	var lo := Color("5f7180") if bright else Color("1f242a")

	# 连接件（椅背插进坐垫那一截）
	draw_rect(Rect2(cx - 2.0, bot, 4.0, 1.5),
		Color("5f7180") if bright else Color("1d2126"))

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


# ---------------------------------------------------------------- 电梯门

## 电梯门：嵌在东墙里的一樘金属双开滑门，门洞就是墙上那段缺口。
## 视角是俯视 2.5D，所以门和西端那扇玻璃门一样平贴画在墙带里；
## 用金属色 + 中缝 + 门楣到站小屏跟普通门区分开。
## 门南侧贴墙凸出一块呼梯面板（一颗亮着的按钮），比整扇门更像电梯。
func _elevator(o: Vector2, w: float, h: float) -> void:
	var recess := Color("171c22")
	var frame := Color("2c333b")
	var leaf_hi := Color("9aa7b4")
	var leaf := Color("7a8692")
	var leaf_lo := Color("5d6873")

	# 门洞（墙被切开的那一段）：先铺一层暗，门缝里才有"井道"的深度
	draw_rect(Rect2(o.x, o.y, w, h), recess)
	# 门套：四周一圈，把门和砌体分开
	draw_rect(Rect2(o.x, o.y, w, 1.0), frame)
	draw_rect(Rect2(o.x, o.y + h - 1.0, w, 1.0), frame)
	draw_rect(Rect2(o.x, o.y, 1.0, h), frame)
	draw_rect(Rect2(o.x + w - 1.0, o.y, 1.0, h), frame)

	# 两扇门沿着墙（南北向）并排：俯视看就是上下两块金属板
	var half := (h - 2.0) * 0.5
	for k in range(2):
		var dy := o.y + 1.0 + float(k) * (half + 0.5)
		draw_rect(Rect2(o.x + 1.0, dy, w - 2.0, half), leaf)
		draw_rect(Rect2(o.x + 1.0, dy, w - 2.0, 1.0), leaf_hi)          # 上沿反光
		draw_rect(Rect2(o.x + 1.0, dy + half - 1.0, w - 2.0, 1.0), leaf_lo)
	# 中缝（两扇门合上的那道线）
	draw_rect(Rect2(o.x + 1.0, o.y + h * 0.5 - 0.6, w - 2.0, 1.2), Color("0f1318"))
	# 朝走廊这一侧（西沿）再压一道窄高光，金属感靠它
	draw_rect(Rect2(o.x + 1.0, o.y + 2.0, 1.0, h - 4.0), leaf_hi.darkened(0.10))

	# 门楣到站屏：一条暗底 + 一段绿光
	var sw := w - 6.0
	draw_rect(Rect2(o.x + 3.0, o.y + 1.5, sw, 2.5), Color("10151a"))
	draw_rect(Rect2(o.x + 3.5, o.y + 2.2, sw - 1.0, 1.2), Color(0.34, 0.92, 0.52, 1.0))

	# 呼梯面板：贴墙凸出到走廊一侧、门的中下部，一颗亮着的按钮 + 上/下箭头
	var px := o.x - 6.0
	var py := o.y + h - 15.0
	draw_rect(Rect2(px + 0.5, py + 0.5, 6.0, 11.0), Color(0, 0, 0, 0.28))   # 投影
	draw_rect(Rect2(px, py, 6.0, 11.0), Color("2b333c"))
	draw_rect(Rect2(px, py, 6.0, 1.0), Color("49545f"))
	draw_rect(Rect2(px + 1.2, py + 1.6, 3.6, 3.4), Color("4a5560"))          # 上行键
	draw_rect(Rect2(px + 1.2, py + 6.0, 3.6, 3.4), Color("4a5560"))          # 下行键
	# 上行键亮着（暖黄），下行键留个暗点 —— 站在门口就是"正在呼梯"
	draw_rect(Rect2(px + 2.0, py + 2.5, 2.0, 1.8), Color(1.0, 0.82, 0.36, 1.0))
	draw_rect(Rect2(px + 2.0, py + 7.0, 2.0, 1.6), Color(0.30, 0.35, 0.40, 1.0))


# ---------------------------------------------------------------- 沙发

## 朝南（面朝镜头）的沙发：靠背立在 rect 北沿，座面在它前面，
## 两端各一块扶手。休息区里正对着门口，进来第一眼就看见。
func _sofa(o: Vector2, w: float, h: float) -> void:
	var arm := clampf(w * 0.10, 2.0, 5.0)
	var back_h := clampf(h * 0.72, 6.0, 12.0)
	var body := Color("7fa8b8") if bright else Color("6b4f6f")
	var hi := Color("a9cbd7") if bright else Color("8b6a90")
	var lo := Color("5f8497") if bright else Color("4e3a52")
	var seat := Color("8fb9c7") if bright else Color("7d5d81")
	var seat_hi := Color("b5d8e2") if bright else Color("95739a")
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
	draw_rect(Rect2(o.x + arm, o.y + 1.0, w - arm * 2.0, h - 1.0), seat)
	draw_rect(Rect2(o.x + arm, o.y + 1.0, w - arm * 2.0, 1.0), seat_hi)
	draw_rect(Rect2(o.x + arm, o.y + h - 2.0, w - arm * 2.0, 2.0), lo)
	# 坐垫分两块
	draw_rect(Rect2(o.x + arm + (w - arm * 2.0) * 0.5 - 0.5, o.y + 3.0, 1.0, h - 6.0),
		Color(0, 0, 0, 0.14))

	# 扶手：比座面高一点，两侧各一块
	for sx in [o.x, o.x + w - arm]:
		draw_rect(Rect2(sx, o.y - 5.0, arm, h + 5.0), Color("5e4462"))
		draw_rect(Rect2(sx, o.y - 5.0, arm, 1.0), Color("7d5d81"))
		draw_rect(Rect2(sx + (0.0 if sx == o.x else arm - 1.0), o.y - 5.0, 1.0, h + 5.0), lo)


# ---------------------------------------------------------------- 素材沙发 / 扶手椅
#
# 图书馆休息区换成了外部素材：一套三人沙发 + 四把扶手椅，源图是粗黑边手绘，
# 缩到 64x54 / 22x26 之后轮廓还立得住，正好和亮房的浅色地板配。
# 素材缺失时退回上面那套程序绘制的 _sofa / _chair_seat，房间不会破相。

func _sofa_sprite(o: Vector2, w: float, h: float) -> void:
	var tex := seats_tex()
	if tex == null:
		_sofa(o, w, h)
		return
	_shadow(o, w, h, 3.0)
	var row := clampi(variant, 0, 1)
	# 素材自带沙发腿，落脚线就在图片下沿 —— 贴 rect 底边、水平居中，
	# y-sort 拿 position.y 比较时和玩家按脚底排序的规则一致。
	var dw := float(SOFA_W)
	var dh := float(SOFA_H)
	draw_texture_rect_region(
		tex,
		Rect2(o.x + (w - dw) * 0.5, o.y + h - dh, dw, dh),
		Rect2(0.0, float(row) * SOFA_H, SOFA_W, SOFA_H))


func _armchair(o: Vector2, w: float, h: float) -> void:
	var tex := seats_tex()
	if tex == null:
		_chair_seat(o, w, h)
		_chair_back(o, w, h)
		return
	_shadow(o, w, h, 1.5)
	var idx := clampi(variant, 0, 3)
	draw_texture_rect_region(
		tex,
		Rect2(o.x + (w - float(CHAIR_W)) * 0.5, o.y + h - float(CHAIR_H),
			float(CHAIR_W), float(CHAIR_H)),
		Rect2(float(idx * CHAIR_W), float(SOFA_H), CHAIR_W, CHAIR_H))


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
	draw_rect(Rect2(o.x, o.y - 2.0, w, h), Color("7fa8b8") if bright else Color("5a4a6e"))
	draw_rect(Rect2(o.x, o.y - 2.0, w, 1.0), Color("b5d8e2") if bright else Color("7a6890"))
	draw_rect(Rect2(o.x, o.y + h - 2.0, w, 2.0), Color("5f8497") if bright else Color("453a55"))
	draw_rect(Rect2(o.x + 2.0, o.y - 1.0, w - 4.0, h - 4.0), Color(0, 0, 0, 0.10))
