extends Node2D
## 校园水域里的小船：纯程序绘制的像素木船（零素材），带轻微摇晃、划桨与尾迹。
##
## 位置有两套来源：
##   · 本机玩家正在划这艘船 -> Arena 每帧直接写 position（本地权威，手感不延迟）；
##   · 其他船 -> 服务端把船位广播下来，这里对着 net_pos 做插值，避免 30Hz 阶跃。
##
## 小船参与 Objects 的 y 排序，所以岸上的人站在船边时，船和人的前后关系
## 和楼/树一致；玩家上船后脚底比船心略靠南，会画在船体上面。

const BOB_AMP := 0.9          # 上下浮动幅度（局部像素）
const BOB_SPEED := 2.1        # 浮动速度
const CHASE := 12.0           # 远端船位的平滑追赶速度

var index: int = -1
var is_riding: bool = false   # 本机玩家正在划这艘（位置由 Arena 直接写）
var occupied: bool = false
var moving: bool = false
## 船头方向（只取四个正交方向，像素画法旋转 90° 保持锐利）
var dir := Vector2.RIGHT

var _net_pos := Vector2.ZERO
var _t := 0.0
var _phase := 0.0

var _hull := PackedVector2Array()
var _deck := PackedVector2Array()
var _flag := PackedVector2Array()


func _ready() -> void:
	# 俯视视角的小木船：船头朝右，船身中间是座板，两侧伸出双桨。
	_hull = PackedVector2Array([
		Vector2(-15, -3), Vector2(-12, -6.5), Vector2(7, -6.5), Vector2(15, 0),
		Vector2(7, 6.5), Vector2(-12, 6.5), Vector2(-15, 3),
	])
	_deck = PackedVector2Array([
		Vector2(-12.6, -2.6), Vector2(-10.4, -4.6), Vector2(6.0, -4.6),
		Vector2(12.6, 0), Vector2(6.0, 4.6), Vector2(-10.4, 4.6), Vector2(-12.6, 2.6),
	])
	_flag = PackedVector2Array([
		Vector2(-12, -10), Vector2(-12, -6), Vector2(-6.5, -8.0),
	])


## Arena 在小船挂进场景后调用：index 与所有机器上的船位表一一对应。
func setup(i: int, pos: Vector2) -> void:
	index = i
	position = pos
	_net_pos = pos
	_phase = float(i) * 1.7
	queue_redraw()


func set_occupied(v: bool) -> void:
	if occupied == v:
		return
	occupied = v
	queue_redraw()


## 本机正在划：Arena 每帧写位置，这里只更新朝向/划桨状态。
func apply_local(pos: Vector2, moving_now: bool, dirx: float, diry: float) -> void:
	position = pos
	_net_pos = pos
	moving = moving_now
	_set_dir(dirx, diry)


func set_riding(v: bool) -> void:
	is_riding = v


## 服务端广播的权威船位：交给 _process 平滑追赶；跳得太远（补发快照）直接吸附。
func set_net(pos: Vector2, moving_now: bool, dirx: float, diry: float) -> void:
	if pos.distance_to(_net_pos) > 160.0:
		position = pos
	_net_pos = pos
	moving = moving_now
	_set_dir(dirx, diry)


## 可靠消息（上下船 / 新玩家补发）带来的位置：直接吸附，不做插值。
func snap(pos: Vector2, dirx: float, diry: float) -> void:
	position = pos
	_net_pos = pos
	_set_dir(dirx, diry)


## 把方向量化到四个正交朝向。斜着划时取分量更大的轴，
## 船的立绘不会出现非 90° 旋转的锯齿。
func _set_dir(dirx: float, diry: float) -> void:
	if absf(dirx) < 0.05 and absf(diry) < 0.05:
		return
	if absf(dirx) >= absf(diry):
		dir = Vector2(1.0 if dirx >= 0.0 else -1.0, 0.0)
	else:
		dir = Vector2(0.0, 1.0 if diry >= 0.0 else -1.0)


func _process(delta: float) -> void:
	if not is_riding:
		position = position.lerp(_net_pos, minf(delta * CHASE, 1.0))
	_t += delta
	queue_redraw()


func _draw() -> void:
	var bob: float = sin(_t * BOB_SPEED + _phase) * BOB_AMP
	# 船头朝当前划行方向：右/下/左/上分别旋转 0° / 90° / 180° / -90°
	var ang := 0.0
	if dir.x < -0.5:
		ang = PI
	elif dir.y < -0.5:
		ang = -PI * 0.5
	elif dir.y > 0.5:
		ang = PI * 0.5
	draw_set_transform(Vector2(0.0, bob), ang, Vector2.ONE)

	# 船底在水里的暗影（水面上的浮空感靠它压住）
	draw_rect(Rect2(-14.0, 2.5, 28.0, 4.0), Color(0.02, 0.07, 0.10, 0.32))

	# 船体：深色描边 + 木色甲板
	draw_colored_polygon(_hull, Color("3a2317"))
	draw_colored_polygon(_deck, Color("9a6434"))
	draw_polyline(_deck, Color("c8925a"), 1.0)
	# 甲板木条
	draw_line(Vector2(-9.0, -2.4), Vector2(8.5, -2.4), Color("6f4524"), 1.0)
	draw_line(Vector2(-9.0, 2.4), Vector2(8.5, 2.4), Color("6f4524"), 1.0)

	# 两块座板
	draw_rect(Rect2(-7.0, -5.0, 2.6, 10.0), Color("c08a50"))
	draw_rect(Rect2(4.4, -5.0, 2.6, 10.0), Color("c08a50"))

	# 双桨：划动时轻微摆动
	var swing: float = sin(_t * 6.2) * 1.4 if moving else 0.0
	draw_line(Vector2(-3.0, -6.0), Vector2(-11.0, -10.5 - swing), Color("d9b57c"), 1.4)
	draw_line(Vector2(-3.0, 6.0), Vector2(-11.0, 10.5 + swing), Color("d9b57c"), 1.4)

	# 船尾有人时挂一面小旗，远处也能看出这艘被占了
	if occupied:
		draw_rect(Rect2(-12.0, -10.0, 1.4, 4.6), Color("6b4526"))
		draw_colored_polygon(_flag, Color("58c8e8"))

	# 船尾尾迹：划动时在船后拖出三道浅色水纹
	if moving:
		var a := 0.20 + 0.14 * absf(sin(_t * 5.0 + _phase))
		var col := Color(0.80, 0.93, 1.0, a)
		draw_line(Vector2(-17.0, -3.0), Vector2(-24.0, -5.0), col, 1.0)
		draw_line(Vector2(-17.0, 0.0), Vector2(-26.0, 0.0), col, 1.0)
		draw_line(Vector2(-17.0, 3.0), Vector2(-24.0, 5.0), col, 1.0)
