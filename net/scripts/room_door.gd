extends Node2D
## 宿舍房间门 —— 会开、会关、会锁的一樘双扇玻璃滑门。
##
## 为什么要单独一个节点：原来门只是 room_prop 里的一个静态 "door" 画法，
## 画完就再也不动了。现在它要按「谁站在门口」实时开合，还得在锁着的时候
## 挡住人（房间是私人空间），静态绘制做不到这两件事。
##
## 坐标与 room_prop 一致：节点原点在门洞**底边中心**，内部按 8px/格 画，
## 这样它和墙、家具一样参与 objects 的 y 排序 —— 人站在走廊里会被门挡住，
## 走到门内则画在门后面。
##
## 动画：两扇门往左右滑进墙里（俯视 2.5D 下最自然的一种，电梯门也是这个路子），
## 打开时门洞里透出房间的暖光。锁着时门缝中央挂一把琥珀色小锁。

const TS := 8.0
## 开/关一次用多久。0.4s 左右刚好 —— 太快像瞬移，太慢人已经走过去了门还没开
const OPEN_TIME := 0.40
## 门开到底时门板剩下的可见比例（留一条窄边，像真的滑进门套里）
const SLIDE_MIN := 0.08
## 门板可见比例低于这个值就算"打开了"，放行
const PASS_AT := 0.55

var cell := Rect2()          # 门洞矩形（格）
var side := "n"              # 房间在门的哪一侧：n = 北（门在走廊北墙），s = 南
var claim_index := -1        # 对应 room_doors 里的 index，Arena 按它查认领
var owner_uid := ""
var owner_name := ""
var locked := false

var _t := 0.0                # 动画值：0 全关 / 1 全开
var _target := 0.0
var _blocked := true
var _body: StaticBody2D
var _shape: CollisionShape2D
var _warn_flash := 0.0       # 被推了一下（没权限）时闪一下锁标


## 由 Room 在搭场景时调用。rect 是格坐标；side 传 "n"/"s"。
func setup(idx: int, rect: Rect2, side_kind: String) -> void:
	claim_index = idx
	cell = rect
	side = side_kind
	position = Vector2(rect.get_center().x * TS, rect.end.y * TS)
	name = "Door_%d" % idx

	_body = StaticBody2D.new()
	_body.name = "Barrier"
	_body.collision_layer = 1        # 玩家 mask=1，撞得上
	_body.collision_mask = 0
	_shape = CollisionShape2D.new()
	var rs := RectangleShape2D.new()
	# 比门洞窄 2px：贴着门框站着时不会被自己这扇门的碰撞"夹住"
	rs.size = Vector2(maxf(rect.size.x * TS - 2.0, 4.0), rect.size.y * TS)
	_shape.shape = rs
	_shape.position = Vector2(0.0, -rect.size.y * TS * 0.5)
	_shape.disabled = false
	_body.add_child(_shape)
	add_child(_body)
	queue_redraw()


## 目标状态（true = 开）。真正的开合是动画，不是瞬切。
func set_open(v: bool) -> void:
	_target = 1.0 if v else 0.0


func is_open() -> bool:
	return _target > 0.5


## 门板已经让开了多少（0..1），Arena 用它判断人到底能不能过去
func open_ratio() -> float:
	return _t


func set_locked(v: bool) -> void:
	if locked == v:
		return
	locked = v
	if locked and _target > 0.0:
		set_open(false)          # 上锁的同时关门
	queue_redraw()


## 没权限的人试图进门时调用：锁标闪一下，配一行提示
func warn() -> void:
	_warn_flash = 1.0


func _process(delta: float) -> void:
	if _warn_flash > 0.0:
		_warn_flash = maxf(0.0, _warn_flash - delta * 2.2)
		queue_redraw()
	if is_equal_approx(_t, _target):
		return
	_t = move_toward(_t, _target, delta / OPEN_TIME)
	queue_redraw()
	# 门开到一半就放行：等动画播完才让过，人会先在门口顿一下
	var want_block := _t < PASS_AT
	if want_block != _blocked:
		_blocked = want_block
		if is_instance_valid(_shape):
			_shape.set_deferred("disabled", not want_block)


func _draw() -> void:
	var w := cell.size.x * TS
	var h := cell.size.y * TS
	if w < 2.0 or h < 2.0:
		return
	var o := Vector2(-w * 0.5, -h)        # 门洞左上角（局部）
	var t := _ease(_t)

	var frame := Color("59646f")
	var recess := Color("10151b")
	var glass_a := Color("1a2830")
	var glass_b := Color("26404e")

	# ── 门洞：先铺一层暗，门缝里才有「厚度」 ──
	draw_rect(Rect2(o.x, o.y, w, h), recess)

	# ── 打开时门内透出的暖光：越开越亮，光从房间那一侧漫出来 ──
	if t > 0.02:
		var warm := Color(1.0, 0.86, 0.62, 0.34 * t)
		draw_rect(Rect2(o.x + 1.0, o.y + 1.0, w - 2.0, h - 2.0), warm)
		# 房间那一侧的边缘更亮（灯就在里面）
		var edge_y := o.y + 1.0 if side == "n" else o.y + h - 3.0
		draw_rect(Rect2(o.x + 1.0, edge_y, w - 2.0, 2.0), Color(1.0, 0.90, 0.72, 0.30 * t))

	# ── 门套：固定不动，四周一圈 ──
	draw_rect(Rect2(o.x, o.y, w, 1.5), frame.lightened(0.18))
	draw_rect(Rect2(o.x, o.y + h - 1.5, w, 1.5), frame.darkened(0.28))
	draw_rect(Rect2(o.x, o.y, 1.5, h), frame)
	draw_rect(Rect2(o.x + w - 1.5, o.y, 1.5, h), frame)

	# ── 两扇门板：关闭时各占一半，打开时向两侧滑进墙里 ──
	var inner_x := o.x + 1.5
	var inner_w := w - 3.0
	var half := inner_w * 0.5
	var leaf_w := half * lerpf(1.0, SLIDE_MIN, t)
	var leaf_h := h - 3.0
	var leaf_y := o.y + 1.5
	_draw_leaf(Rect2(inner_x, leaf_y, leaf_w, leaf_h), glass_a, glass_b, true)
	_draw_leaf(Rect2(inner_x + inner_w - leaf_w, leaf_y, leaf_w, leaf_h), glass_a, glass_b, false)

	# ── 中缝 + 拉手：只有门快合上时才画（开着的时候中缝本来就不存在） ──
	if t < 0.45:
		var a := 1.0 - t / 0.45
		var cx := o.x + w * 0.5
		draw_rect(Rect2(cx - 0.5, o.y + 2.0, 1.0, h - 4.0), Color(0.02, 0.03, 0.04, 0.85 * a))
		var hh := h * 0.30
		draw_rect(Rect2(cx - 3.0, o.y + h * 0.5 - hh * 0.5, 1.4, hh), Color(0.55, 0.60, 0.66, a))
		draw_rect(Rect2(cx + 1.6, o.y + h * 0.5 - hh * 0.5, 1.4, hh), Color(0.55, 0.60, 0.66, a))

	# ── 锁标：锁着就挂在门缝中间 ──
	if locked:
		var cx2 := o.x + w * 0.5
		var cy2 := o.y + h * 0.5
		var amber := Color("d8a13a")
		var bright := Color("f2c862")
		if _warn_flash > 0.0:
			# 被推门时整把锁闪成橙红
			var k := _warn_flash
			amber = amber.lerp(Color("ff6a3d"), k)
			bright = bright.lerp(Color("ffb08a"), k)
		# 锁梁
		draw_rect(Rect2(cx2 - 1.6, cy2 - 4.6, 3.2, 1.0), amber)
		draw_rect(Rect2(cx2 - 1.6, cy2 - 4.6, 1.0, 3.4), amber)
		draw_rect(Rect2(cx2 + 0.6, cy2 - 4.6, 1.0, 3.4), amber)
		# 锁体
		draw_rect(Rect2(cx2 - 3.0, cy2 - 1.2, 6.0, 5.0), amber)
		draw_rect(Rect2(cx2 - 3.0, cy2 - 1.2, 6.0, 1.0), bright)
		# 锁孔
		draw_rect(Rect2(cx2 - 0.5, cy2 + 0.6, 1.0, 2.2), Color(0.09, 0.06, 0.02, 1.0))


## 单扇门板：玻璃两层 + 斜反光 + 外框高光。from_left 决定反光往哪边斜。
func _draw_leaf(r: Rect2, dark: Color, light: Color, from_left: bool) -> void:
	if r.size.x < 0.6:
		return
	draw_rect(r, dark)
	if r.size.x > 3.0:
		draw_rect(Rect2(r.position.x + 1.0, r.position.y + 1.0, r.size.x - 2.0, r.size.y - 2.0), light)
	# 上沿一道亮边，玻璃才不像一块平色
	draw_rect(Rect2(r.position.x, r.position.y, r.size.x, 1.0), Color(1, 1, 1, 0.10))
	# 斜反光
	if r.size.x > 4.0:
		var x0 := r.position.x + (1.5 if from_left else 1.5)
		draw_line(
			Vector2(x0, r.end.y - 1.5),
			Vector2(minf(x0 + r.size.x * 0.7, r.end.x - 1.0), r.position.y + 1.5),
			Color(1, 1, 1, 0.09), 1.0)


func _ease(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)
