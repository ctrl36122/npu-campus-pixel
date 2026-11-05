extends CharacterBody2D
## One player's avatar. The server owns every avatar (multiplayer authority 1)
## and is the only machine whose movement counts.
##
## How a move travels, every network tick (30 per second):
## 1. The owning client samples its input into a numbered command, moves right
##    away (prediction), and sends every unacknowledged command to the server.
## 2. The server checks each command, simulates at most one per tick, and
##    publishes server_state = {seq, position} through the synchronizer.
## 3. The owning client compares that with what it predicted for the same seq.
##    If they differ, it snaps to the server's answer and replays the commands
##    the server has not processed yet (reconciliation).
## 4. Everyone else draws this avatar 100 ms in the past, interpolating between
##    server positions (RemoteSmoother), so remote players move smoothly.

## 局部速度。Players 空间已归一成校园局部坐标（视觉再被 campus 放大 2 倍），
## 全局速度 = 110 × 2 = 220px/s，和旧的 0.5 空间时代一致
const SPEED: float = 110.0
const EMOTES: Array[String] = ["Hello!", "Here!", "Thanks!", "Help!"]
## 渲染平滑：移动跑在 30 Hz 的网络 tick 上，画面却是 60 fps 画的。
## 直接把 position 画出来，等于「每两帧跳一步」，看着就是在抽搐。
## 这里让精灵和相机滞后一点点再平滑追上，把阶跃摊平成连续移动。
## 30 的时间常数约一个 tick（33ms），滞后只有几像素，肉眼察觉不到。
const RENDER_CHASE: float = 30.0
## 被楼挡住时角色自身的不透明度（楼 0.45，人 0.55，两者叠加仍可辨认）
const OCCL_ALPHA: float = 0.55
## 相机缩放：1.2 是 Player.tscn 里的默认视距。
## 0.55 时一屏约 145 格（和网页版默认视野一致），3.0 时能看清单栋楼的窗户。
## 显示调试：XGD_ZOOM=0.8 可指定初始缩放（截图用），正常玩走 ZOOM_BASE。
const ZOOM_BASE: float = 1.05
const ZOOM_MIN: float = 0.55
const ZOOM_MAX: float = 3.0
const ZOOM_STEP: float = 1.14
## 角色缩放——「人和楼的比例」唯一的旋钮。
## 角色挂在校园层下面，屏幕尺寸 = ACTOR_SCALE × CAMPUS_SCALE × zoom，
## 所以这个值越小，人越矮、楼越显宽（校园本身不动，只是相对尺度变了）。
## 0.375 ≈ 2.2 格高（偏大）；0.27 ≈ 1.5 格高（站在楼前比例接近真实）。
## 调太小（<0.2）五官会糊，因为原画只有 32×48。
## 调试：XGD_ACTOR_SCALE=0.22 / 0.3 可临时指定（截图对尺度用）。
const ACTOR_SCALE: float = 0.27
## One colour per roster slot. The roster is the same on every machine, so every
## window agrees on who is who.
const COLORS: Array[Color] = [Color("5b8cff"), Color("ff9f43"), Color("2ed573"), Color("ff6b9d")]

## sit_dir 的 1..4 对应的朝向名（顺序和图集的 *_sit 动画一致）
const SIT_DIRS: Array[String] = ["down", "left", "right", "up"]
## 精灵锚点：帧高 48、居中，offset 上移半帧 → 脚底正好落在节点原点。
## 躺下时改成 (0,0)，让身体绕自己中心转 90°，压在床垫中间。
const SPRITE_OFFSET := Vector2(0, -24)

var owner_peer_id: int = 0
var is_local_player: bool = false
@export var round_id: int = 0
@export var server_position: Vector2 = Vector2.ZERO
@export var facing: float = 0.0
@export var server_state: Dictionary = {}
## 角色外观 id（adam/ash/lucy/nancy），由服务器按注册时上报的值下发
@export var hero_id: String = "adam"

## 坐姿：0 = 站着，1..4 = 坐着并面朝 SIT_DIRS 里对应方向。
## 用整数而不是字符串，是因为要过 MultiplayerSynchronizer 的属性同步。
## 坐着期间禁止移动（本地预测与服务端模拟走同一个判断），否则会出现
## 「人一动不动但位置在椅子周围飘」。
@export var sit_dir: int = 0

## 是否在宿舍房间里（导出变量，随同步器广播）：房间内的人只和同层的人互相可见，
## 校园里的人一律不显示房间里的人。以前进房只是本地传送、房间内又完全不发位置包，
## 服务端那份还停在校园门口 —— 于是「在宿舍里看不见别人，别人也看不见你」。
@export var room_inside: bool = false
## 在房间里时的楼层号（1..5）；不在房间就是 0。
@export var room_floor: int = 0

## 是否正坐在校园小船上（不上同步器：船位/占用由 Arena 的船状态广播，
## 这里只影响本地/服务端的移动模拟：船上不做物理移动，位置由 Arena 每帧写）。
var on_boat: bool = false

const HeroDB := preload("res://scripts/sandbox/hero_db.gd")
## 下面三个用 preload 而不是全局类名：无头导入时 global_script_class_cache 可能为空
const PlayerInputScript := preload("res://net/scripts/player/PlayerInput.gd")
const InputBufferScript := preload("res://net/scripts/player/InputBuffer.gd")
const RemoteSmootherScript := preload("res://net/scripts/player/RemoteSmoother.gd")

@onready var visual: Node2D = $Visual
@onready var sprite: AnimatedSprite2D = $Visual/Sprite
@onready var bubble: Label = $Bubble

var input = PlayerInputScript.new()
var next_seq: int = 1
var processed_seq: int = 0
var commands: Dictionary = {}
var last_seen_seq: int = -1
var smoother = RemoteSmootherScript.new()
var buffer = InputBufferScript.new()
var simulation_budget: int = 0
var correction_offset: Vector2 = Vector2.ZERO
## 视觉朝向 / 是否在走动（本地用输入方向，远端用位置差推断）
var _face_dir: Vector2 = Vector2.DOWN
var _moving: bool = false
var _last_pos: Vector2 = Vector2.ZERO
var _applied_hero: String = ""
var _emote_timer: SceneTreeTimer
var _bubble_timer: SceneTreeTimer
## 界面面板打开时置 true：本地输入被清零，人物站着不动（避免打字时人乱跑）
var ui_blocked: bool = false
## 相机缩放目标值（滚轮改这个，_process 里平滑逼近）
var _cam_zoom_target: float = ZOOM_BASE
## 精灵/相机相对物理位置的滞后量（tick 阶跃的平滑缓冲）
var _render_lag: Vector2 = Vector2.ZERO
## 上一次 _apply_movement 实际挪了多远（像素）。渲染时按这个长度线性追平滞后，
## 保证视觉在一个 tick 内匀速追上物理位置 —— 只靠指数 lerp 永远差一截，
## 稳态滞后 + 每 tick 补一次 = 走起来一抖一抖（活动室里最明显）。
var _step_len: float = 0.0
## 被楼挡住时为 true（Arena 每帧设置）：楼和人都变半透明，经典 RPG 做法
var _occluded: bool = false
## 当前不透明度，向目标平滑逼近（走过楼边不该「啪」一下变透）
var _occl_a: float = 1.0
## 进宿舍空间期间本地权威：服务器不知道你在房间里，临时冻结对自己位置的 reconcile，
## 否则服务器每帧把人拉回校园，而相机 limit 卡在房间内 → 你被困在房间边界外、看不到自己。
var _room_freeze := false

## 连续多少个 tick「按着方向键却一步没挪」才触发脱困（8 × 33ms ≈ 0.27s）。
## 正常撞墙会被切向滑动救掉，不会走到这一步；只有卡进碰撞体里才需要蹭出去。
const STUCK_TICKS := 8
var _stuck_ticks := 0


## 被楼挡住 → 精灵调淡（名牌保持不透明，方便找人）
func set_occluded(v: bool) -> void:
	_occluded = v


func _enter_tree() -> void:
	owner_peer_id = str(name).to_int()
	set_multiplayer_authority(1)


func _ready() -> void:
	if OS.has_environment("XGD_ZOOM"):
		_cam_zoom_target = clampf(OS.get_environment("XGD_ZOOM").to_float(), ZOOM_MIN, ZOOM_MAX)
	# 角色在校园层里的缩放（校园层再乘 CAMPUS_SCALE，所以 0.375 × 2 = 屏幕上 0.75 倍原画）
	var actor_sc := ACTOR_SCALE
	if OS.has_environment("XGD_ACTOR_SCALE"):
		actor_sc = clampf(OS.get_environment("XGD_ACTOR_SCALE").to_float(), 0.08, 1.0)
	scale = Vector2(actor_sc, actor_sc)
	# 名牌/气泡跟着节点一起被缩放，人越小字越小 —— 这里按比例把字号补回去，
	# 保证不管 ACTOR_SCALE 调到多少，字在屏幕上始终是 11/12 号那么大。
	var font_k := 0.375 / actor_sc
	$Name.add_theme_font_size_override("font_size", int(round(11.0 * font_k)))
	bubble.add_theme_font_size_override("font_size", int(round(12.0 * font_k)))
	is_local_player = owner_peer_id == Net.my_id()
	SessionFlow.configure_sync($Sync)
	_update_name()
	Net.roster_changed.connect(_update_name)
	Net.emote_received.connect(_on_emote)
	$Camera.enabled = is_local_player
	if is_local_player:
		# 相机限制在校园范围内，走到地图边缘不会看到世界外的空白
		var cam: Camera2D = $Camera
		cam.limit_left = 0
		cam.limit_top = 0
		# ⚠️ limit 用全局坐标（世界全局 = 局部 × CAMPUS_SCALE），别改成局部值
		var cs := 2.0
		if OS.has_environment("XGD_CAMPUS_SCALE"):
			cs = clampf(OS.get_environment("XGD_CAMPUS_SCALE").to_float(), 1.0, 8.0)
		cam.limit_right = int(3392.0 * cs)
		cam.limit_bottom = int(6400.0 * cs)
	NetTick.network_tick.connect(_on_tick)


func _update_name() -> void:
	$Name.text = str(Net.peers.get(owner_peer_id, {}).get("name", "Player"))


## 头顶聊天气泡（别人说话时弹出来，几秒后自动消失）
func show_bubble(text: String, seconds: float = 3.2) -> void:
	if bubble == null:
		return
	bubble.text = text
	bubble.visible = true
	_bubble_timer = get_tree().create_timer(seconds)
	var t := _bubble_timer
	t.timeout.connect(func():
		if _bubble_timer == t:
			bubble.visible = false)


## 传送（地图点选）。清掉预测缓冲，否则本地还会按旧指令继续往前跑。
func teleport_to(pos: Vector2) -> void:
	position = pos
	server_position = pos
	server_state = {"seq": processed_seq, "position": pos}
	buffer.entries.clear()
	correction_offset = Vector2.ZERO
	_render_lag = Vector2.ZERO
	_step_len = 0.0


## 进 / 出房间、换层时调用：把「我在房间里 + 第几层 + 落在哪」告诉服务端。
## 服务端是权威，它把这份状态写进自己的 avatar 再广播给所有人：
##   · 同层的人 -> 显示你，位置继续每 tick 用 _push_room_pose 推过去
##   · 不同层 / 还在校园的人 -> 隐藏你
## 以前进房只改了本地坐标，房间内又不发包，别人那边你还站在楼门口。
func set_room_state(inside: bool, floor_n: int, pos: Vector2) -> void:
	room_inside = inside
	room_floor = clampi(floor_n, 1, 99) if inside else 0
	teleport_to(pos)
	if Net.is_server():
		_publish_pose(pos)
	elif Net.has_session():
		Net.send_to(1, self, &"_room_state", [room_inside, room_floor, pos])


## 客户端 -> 服务端：登记进房 / 出房。坐标是 Objects 局部坐标（房间与 Players 同一空间）。
@rpc("any_peer", "call_remote", "reliable", 0)
func _room_state(inside: bool, floor_n: int, pos: Vector2) -> void:
	if not Net.is_server():
		return
	if multiplayer.get_remote_sender_id() != owner_peer_id:
		return
	room_inside = inside
	room_floor = clampi(floor_n, 1, 99) if inside else 0
	teleport_to(pos)
	sit_dir = 0
	# 进/出房这次传送本身也要让远端看到：teleport_to 写的 seq 是 processed_seq
	# （和上一份校园快照相同值），远端判「seq 没变」会跳过 —— 这里再发布一份新序号。
	if Net.is_server():
		_publish_pose(pos)


## 上 / 下校园小船。on = true：吸附到船位、关闭碰撞（水面是实心碰撞，人站在船上
## 不能再被水推），后续位置由 Arena 每帧写在 position 上；
## on = false：恢复碰撞并像起床一样先找空位（岸边可能有长椅/树/花坛，防止嵌进去）。
func set_boat_state(on: bool, pos: Vector2) -> void:
	on_boat = on
	sit_dir = 0
	_local_pose = 0
	if sprite != null:
		sprite.rotation = 0.0
		sprite.offset = SPRITE_OFFSET
	if visual != null:
		visual.z_index = 0
	teleport_to(pos)
	_set_collision(not on)
	if on:
		velocity = Vector2.ZERO
	else:
		_step_out()
	_update_visual()
	# 服务端是权威：上/下船这次传送立刻广播一份（负 seq，远端一定认作新快照）
	if Net.is_server():
		_publish_pose(position)


## 房间内的姿态发布序号。校园里 server_state.seq 用 processed_seq（服务端每模拟
## 一条命令就 +1），房间内服务端不模拟命令、processed_seq 永远不动 —— 远端靠
## 「seq 变了」才把新位置喂给 RemoteSmoother，序号不动 = 远端永远冻在进房位置，
## 这就是「校园里同步、宿舍里别人看你不动」的真凶。
## 用负向递增（-1, -2, …）和校园的正数 seq 永不相撞：出房后 seq 回到
## processed_seq，值必然不同，远端一定能看到出房传送。
var _pose_seq: int = 0


## 服务端发布一份房间内姿态：序号自增，保证远端每次都当「新快照」收。
func _publish_pose(pos: Vector2) -> void:
	_pose_seq -= 1
	server_position = pos
	server_state = {"seq": _pose_seq, "position": pos}


## 客户端 -> 服务端：房间内每 tick 的位置 / 姿势。
## 房间内不做服务端模拟（服务端没有房间几何），但位置必须转出去，
## 否则同房间的人只能看到一个定在门口的木头人。
@rpc("any_peer", "call_remote", "unreliable_ordered", 3)
func _push_room_pose(pos: Vector2, dir: int) -> void:
	if not Net.is_server():
		return
	if multiplayer.get_remote_sender_id() != owner_peer_id:
		return
	if not (room_inside or on_boat):
		return                      # 没登记进房/上船就不接受，防止乱传坐标
	position = pos
	_publish_pose(pos)
	sit_dir = clampi(dir, 0, 8)


## 客户端 -> 服务端：起身落点。
##
## 起身时客户端会做 _step_out（从床/椅子/长椅的碰撞体里找最近的空地），这个结果
## 服务端算不出来 —— 它手里的副本没跟着挪过，物理状态也不完全等于客户端那一刻的。
## 不接这一步的后果：服务端 position 停在座位中心，而它每模拟一条命令就广播一份
## 新快照；客户端被拉回座位、本地预测再挪出去，每 tick 来回 = 抽搐。
## （2026-11-05 实测：只有纯客户端会抽，房主自己起身不抽，就是因为这条链路断了。）
@rpc("any_peer", "call_remote", "reliable", 0)
func _report_standup(pos: Vector2) -> void:
	if not Net.is_server():
		return
	if multiplayer.get_remote_sender_id() != owner_peer_id:
		return
	if room_inside or on_boat:
		return                      # 房间 / 船上各走各的同步通道，别串味
	if not pos.is_finite():
		return
	# 起身前那几条还没被模拟的旧命令是从座位出发的位移，从新落点再走一遍
	# 会凭空多走一段；客户端那边 buffer 已经在 teleport_to 里清空了，这里对称清掉。
	commands.clear()
	position = pos
	server_position = pos
	teleport_to(pos)
	_publish_pose(pos)


## 坐到椅子上。pos 是座位点（人物脚底），dir_name 取 down/left/right/up。
## 会先 teleport 吸附过去，再切坐姿动画。
##
## ⚠️ 必须同时关掉碰撞体：椅子本身是实心的（world/room 里都有 StaticBody2D），
## 人一坐到椅子上就和它重叠，物理会把人推开 —— 表现是「刚坐下就被弹到旁边」。
## 站起来时再打开，走路照样会被椅子挡住。
func sit_at(pos: Vector2, dir_name: String) -> void:
	var i := SIT_DIRS.find(dir_name)
	sit_dir = (i if i >= 0 else 0) + 1
	if is_local_player:
		_local_pose = sit_dir
	teleport_to(pos)
	_set_collision(false)
	_apply_sit_anim()


## 躺着：sit_dir 5..8 表示躺下（5 + SIT_DIRS 的朝向下标），沿用同一个整型好走属性同步。
const LIE_BASE := 5

## 本机自己摆的姿势（0 = 没摆）。sit_dir 是要走属性同步的，服务器那份还是 0 时，
## 每个同步包都会把本地刚坐下的姿势按回去 —— 一按 E 坐下/躺下，下一帧就站起来。
## 服务器版本比客户端旧、坐/躺这两个 RPC 直接被丢时，就是「椅子和床完全没反应」。
## 所以本地再存一份，每帧贴回去（见 _hold_local_pose），直到真的起身。
var _local_pose: int = 0


## 每帧把本机自己摆的姿势贴回 sit_dir（同步包改回去就再改回来）
##
## ⚠️ 「起身」也必须管。房间/船上（_room_freeze）本地是唯一权威，位置不走属性同步
## （Player.tscn 里 position 的 replication_mode = NEVER），姿势 sit_dir 却是 ALWAYS
## —— 每 33ms 无条件从服务器覆盖回来，而服务器那份由 _push_room_pose（unreliable）
## 推进，天然落后一个 RTT，丢包时干脆停在旧姿势。
## 以前这里 `_local_pose == 0` 就早退，于是唯一的「归零」动作完全不设防：
## 人刚站起来就被旧包按回坐姿 → _apply_movement 见 sit_dir != 0 把速度清零 →
## 下一 tick 又站回来 → 走走停停，看着就是抽搐卡顿。
## 校园里不犯，是因为起身走 Net.sit_down 的 reliable RPC，服务器会立刻归零。
func _hold_local_pose() -> void:
	if not is_local_player:
		return
	var want: int = _local_pose
	# 校园里起身交给服务器裁决，本地不抢权威（否则会和服务端回包打架）
	if want == 0 and not _room_freeze:
		return
	if sit_dir == want:
		return
	sit_dir = want
	if want == 0:
		# 起身：躺姿把整个精灵转过来了，得转回去；站/走帧交给随后的 _update_visual
		if sprite != null:
			sprite.rotation = 0.0
			sprite.offset = SPRITE_OFFSET
		_update_visual()
	else:
		_apply_sit_anim()


func stand_up() -> void:
	_local_pose = 0
	if sit_dir == 0:
		return
	sit_dir = 0
	# 躺姿把整个精灵转过来了，起身必须转回去（锚点也要还原，否则人会往上跳半帧）
	if sprite != null:
		sprite.rotation = 0.0
		sprite.offset = SPRITE_OFFSET
	_set_collision(true)
	# 躺着时碰撞是关掉的，人正好停在床的碰撞体里面；恢复碰撞后如果直接把
	# 控制权交回去，人就是「嵌在床里」的状态 —— move_and_collide 从重叠出发
	# 往哪个方向都推不动，玩家会觉得一起来就卡死、只能重开。
	# 所以起身时先找一个能站人的空位挪过去。
	#
	# 落点只由「操作这个人的那一端」决定。服务端手里那份远端 avatar 是纯模拟副本，
	# 它既不知道客户端当时的碰撞状态，也从没跟着做过 _step_out —— 在这儿再挑一次
	# 只会挑出另一个点，广播回去就是左右拉扯（这正是「一起身就抽搐」的第二种成因）。
	var authoritative_here := is_local_player or not Net.is_server()
	if authoritative_here:
		_step_out()
		# 清掉预测缓冲、把 server_state 指向新落点：起身这一下位置是跳变的，
		# 旧缓冲里的指令是从座位出发的，留着会被重放成人往前冲一段。
		teleport_to(position)
	_update_visual()
	if Net.is_server():
		# 房主自己起身：本地就是权威，直接发布一份新快照。
		if is_local_player:
			_publish_pose(position)
	elif Net.has_session():
		# ⚠️ 客户端必须把落点报给服务端。少了这一步，服务端那份 position 还停在
		# 座位中心，而它每模拟一条命令就广播一次快照 —— 客户端刚挪出来就被拉回、
		# 本地预测又挪出去，反复拉扯 = 抽搐（2026-11-05 复现，纯客户端才出现）。
		Net.send_to(1, self, &"_report_standup", [position])


## 躺到床上。pos 是床上的落点（人物中心），dir_name 是躺的方向。
func lay_at(pos: Vector2, dir_name: String) -> void:
	var i := SIT_DIRS.find(dir_name)
	sit_dir = LIE_BASE + (i if i >= 0 else 0)
	if is_local_player:
		_local_pose = sit_dir
	teleport_to(pos)
	_set_collision(false)
	_apply_sit_anim()


## 是否在躺着（含，本地/远端都读这个判断）
func is_lying() -> bool:
	return sit_dir >= LIE_BASE


func _set_collision(on: bool) -> void:
	var cs := get_node_or_null("CollisionShape2D")
	if cs != null:
		cs.set_deferred("disabled", not on)


## 坐/躺都是单帧静止帧，切换时才 play，免得每帧重置。
## 躺着时把整个精灵转 90°，锚点挪到身体中心，人就「横」在床垫上；
## 之前只是把坐姿帧竖着摆在床面上，看着像是站在床上，很怪。
func _apply_sit_anim() -> void:
	if sprite == null:
		return
	var lying: bool = sit_dir >= LIE_BASE
	sprite.rotation = -PI * 0.5 if lying else 0.0
	# 站立/坐姿的锚点在脚下（帧高 48，居中后 offset 上移半帧）；
	# 躺下时把锚点归零，让身体绕自己中心横过来，正好压在床垫中间。
	sprite.offset = Vector2.ZERO if lying else SPRITE_OFFSET
	# 躺下时人整个陷在床的轮廓里，按 y 排序会被床垫整个盖住 ——
	# 抬一层 z 序，让躺着的人画在家具上面（起身/坐椅子都还原）。
	if visual != null:
		visual.z_index = 1 if lying else 0
	var i: int = sit_dir - LIE_BASE if lying else sit_dir - 1
	var anim := StringName(SIT_DIRS[clampi(i, 0, SIT_DIRS.size() - 1)] + "_sit")
	if sprite.animation != anim:
		sprite.animation = anim
		sprite.play()


## 按 hero_id 换角色贴图（服务器下发的值变了才重新加载）
func _apply_hero() -> void:
	if _applied_hero == hero_id or sprite == null:
		return
	var h = HeroDB.by_id(hero_id)
	if h.is_empty():
		return
	_applied_hero = hero_id
	sprite.sprite_frames = load(str(h["frames"]))


## 四方向贴图动画：本地玩家看输入方向，远端玩家看位置差
func _update_visual() -> void:
	if not is_local_player:
		var moved: Vector2 = position - _last_pos
		if moved.length() > 0.4:
			_face_dir = moved.normalized()
			_moving = true
		else:
			_moving = false
	_last_pos = position
	_apply_hero()
	if sprite == null:
		return
	# 坐着时无论输入如何都用坐姿帧
	if sit_dir != 0:
		_apply_sit_anim()
		return
	var dir_name := "down"
	if _face_dir != Vector2.ZERO:
		if absf(_face_dir.x) >= absf(_face_dir.y):
			dir_name = "right" if _face_dir.x > 0.0 else "left"
		else:
			dir_name = "down" if _face_dir.y > 0.0 else "up"
	var anim_name := StringName(dir_name + ("_walk" if _moving else "_idle"))
	if sprite.animation != anim_name:
		sprite.animation = anim_name
	if not sprite.is_playing():
		sprite.play()


func _on_emote(id: int, index: int) -> void:
	if id != owner_peer_id:
		return
	$Name.text = EMOTES[index]
	_emote_timer = get_tree().create_timer(1.5)
	var this_timer := _emote_timer
	this_timer.timeout.connect(func():
		if _emote_timer == this_timer:
			_update_name())


func _unhandled_input(event: InputEvent) -> void:
	if not is_local_player:
		return
	# 滚轮缩放镜头。UI（设置面板 / 全屏地图）会先吃掉落在自己身上的滚轮，
	# 所以这里不会被「正在看地图」的情况误触发。
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom_step(ZOOM_STEP)
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom_step(1.0 / ZOOM_STEP)
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("emote"):
		Net.emote(0)
		get_viewport().set_input_as_handled()


## 按倍率改视距（滚轮/按钮都走这里）
func zoom_step(factor: float) -> void:
	# 量化到 0.05 的整数倍：像素风在非整数缩放下容易闪烁
	_cam_zoom_target = clampf(snappedf(_cam_zoom_target * factor, 0.05), ZOOM_MIN, ZOOM_MAX)


## 回到默认视距
func zoom_reset() -> void:
	_cam_zoom_target = ZOOM_BASE


func _on_tick(tick: int) -> void:
	if GameState.phase != GameState.Phase.IN_RUN:
		return
	if is_local_player:
		if _room_freeze:
			# 房间内是「本地权威」：服务器根本不知道宿舍空间的存在，坐标体系完全不同，
			# 所以这里既不进预测缓冲也不发包（发包只会让服务器上的人在校园里乱走）。
			#
			# 以前的做法是照常 push 进 buffer、只跳过 reconcile —— 但 buffer 只在
			# reconcile 里确认，等于只进不出：64 条（30Hz 下约 2 秒）塞满之后
			# `buffer.entries.size() < CAPACITY` 恒为假，连输入都不再采样了。
			# 人定在原地、_moving 还停在 true，动画一直循环 —— 这就是
			# 「在宿舍走几步就卡住、却什么都没碰到」的真凶（和碰撞无关）。
			var local_command: Dictionary = input.sample(self, 0, tick)
			if ui_blocked:                       # 设置面板打开时冻结移动
				local_command["x"] = 0.0
				local_command["y"] = 0.0
			_apply_movement(local_command)
			# 位置仍然要给别人看：房间内不跑服务端模拟，但每 tick 把坐标推给服务端，
			# 服务端写进自己的 avatar 再随同步器广播（同房间的人才看得见你走动）。
			if Net.is_server():
				_publish_pose(position)
			elif Net.has_session():
				# 上报本地权威姿势（_local_pose），不要用 sit_dir —— 后者可能刚被
				# 服务器的旧包覆盖，拿它回传等于把错值又推回服务器，形成自我维持的锁死。
				Net.send_to(1, self, &"_push_room_pose", [position, _local_pose])
		elif buffer.entries.size() < InputBufferScript.CAPACITY:
			var command: Dictionary = input.sample(self, next_seq, tick)
			if ui_blocked:                       # 设置面板打开时冻结移动
				command["x"] = 0.0
				command["y"] = 0.0
			next_seq += 1
			if not Net.is_server():
				_apply_movement(command)
			buffer.push(command, position)
		# 房间内不进网络链路：没有要发的命令，也没有要等服务器回的确认
		if not _room_freeze:
			if Net.is_server():
				for command in buffer.pending():
					_accept_command(owner_peer_id, command)
			else:
				# Resend everything unacknowledged: unreliable packets can be lost.
				Net.send_to(1, self, &"_push_inputs", [buffer.pending()])
	if Net.is_server() and not _room_freeze:
		# One command is one fixed movement step. The server grants movement
		# time (one step per tick, a little banked for jitter), so a client that
		# floods commands cannot move faster than everyone else.
		simulation_budget = mini(simulation_budget + 1, 6)
		while simulation_budget > 0 and commands.has(processed_seq + 1):
			var seq: int = processed_seq + 1
			_simulate(commands[seq])
			commands.erase(seq)
			processed_seq = seq
			simulation_budget -= 1
		server_state = {"seq": processed_seq, "position": position}
		server_position = position
		if is_local_player:
			buffer.drop_through(processed_seq)


## Client -> server input batch. Unreliable but ordered, on its own channel (1)
## so a lost packet never stalls chat or the roster.
@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _push_inputs(batch: Array) -> void:
	if not Net.is_server() or batch.size() > InputBufferScript.CAPACITY:
		return
	Net.note_received([batch])
	for value in batch:
		if value is Dictionary:
			_accept_command(multiplayer.get_remote_sender_id(), value)


## Server-side validation. A command is dropped if it comes from anyone but the
## avatar's owner, belongs to another round, is a duplicate or far outside the
## expected sequence window, contains NaN or infinity, or asks to move faster
## than full stick.
func _accept_command(sender: int, command: Dictionary) -> bool:
	if not Net.is_server() or sender != owner_peer_id:
		return false
	if int(command.get("round", -1)) != round_id:
		return false
	var seq: int = int(command.get("seq", 0))
	if seq <= processed_seq or seq > processed_seq + 64 or commands.has(seq):
		return false
	var direction: Vector2 = Vector2(float(command.get("x", 0.0)), float(command.get("y", 0.0)))
	var angle: float = float(command.get("aim", 0.0))
	if not direction.is_finite() or not is_finite(angle):
		return false
	if direction.length() > 1.001:
		return false
	commands[seq] = {"seq": seq, "x": direction.x, "y": direction.y, "aim": angle,
		"sprint": bool(command.get("sprint", false))}
	return true


func _simulate(command: Dictionary) -> void:
	_apply_movement(command)
	facing = float(command.get("aim", facing))


## The one movement function, shared by the server's simulation, the client's
## prediction and the replay during reconciliation. If these ever differed, the
## client would be corrected every tick.
func _apply_movement(command: Dictionary) -> void:
	# 在船上：位置由 Arena 每帧贴在船位，本地输入只驱动船、不再驱动角色本身。
	# 服务端/客户端走同一个判断，不会出现「自己看着在船上、服务端把人往水里推」。
	if on_boat:
		velocity = Vector2.ZERO
		_moving = false
		_step_len = 0.0
		return
	var direction: Vector2 = Vector2(float(command.get("x", 0.0)), float(command.get("y", 0.0))).limit_length()
	# 坐 / 躺状态下方向键不再响应（以前按方向键会自动起身，容易误触把刚坐下的
	# 人带离椅子）。必须再按一次 E 站起来，起身后才能继续移动。
	if sit_dir != 0:
		velocity = Vector2.ZERO
		_moving = false
		_step_len = 0.0
		return
	var speed: float = SPEED
	if bool(command.get("sprint", false)):
		speed *= 1.55
	velocity = direction * speed
	var before := position
	# move_and_collide 撞上东西就停、不沿墙滑：宿舍家具密，斜着蹭到床/桌子/门框
	# 就会直接顶死，玩家按着方向键却一步不动 —— 手感上就是「卡在原地」。
	# 这里手动做一次切向滑动（用碰撞返回的 remainder 投影到墙面），
	# 仍然是固定步长的纯数学运算，服务端/客户端各自跑结果一致。
	var motion: Vector2 = velocity * NetTick.DELTA
	var hit := move_and_collide(motion)
	if hit != null:
		var n: Vector2 = hit.get_normal()
		var rem: Vector2 = hit.get_remainder()
		if n.length() > 0.01 and rem.length() > 0.01:
			var slide: Vector2 = rem.slide(n)
			if slide.length() > 0.01:
				move_and_collide(slide)
	var moved := position - before
	# 物理位置已经前移，视觉位置留在原处（_render_lag 抵消掉这一步），
	# 再由 _process 平滑追上去 —— 30Hz 的阶跃就变成了连续移动。
	_render_lag -= moved
	# 记下这一步的实际长度：_process 拿它当「这一 tick 要追多少」的基准，
	# 正好在一个 tick 内匀速追平（斜率恒定 = 视觉匀速，不会被指数 lerp 拖出锯齿）。
	_step_len = moved.length()
	# ⚠️ 必须在这里立刻把视觉位置也挪回去。
	# 物理位置是这一 tick 一次性跳过去的，补偿量 _render_lag 也是同一步到位；
	# 如果只等下一个渲染帧再写 visual.position，就会出现「这一帧人物猛地前进
	# 1.8px、下一帧又退回来」——每 tick 一次，就是玩家说的抽搐。
	# 写完 visual 之后，帧间再由 _process 线性追平，位置才是连续单调的。
	if visual != null:
		visual.position = correction_offset + _render_lag
	# 视觉方向跟着实际输入走（服务端模拟时同样会更新，保证远端看到的朝向一致）
	if direction.length() > 0.01:
		_face_dir = direction.normalized()
		# 撞墙/家具被挡住、实际没挪动 → 不播行走动画，否则会「原地踏步」
		# （宿舍里家具密，走几步就贴上去、动画却一直循环，看着就像卡死了）。
		# 仍保持 _face_dir，所以角色会面朝挡住他的那面墙、站定，而不是诡异地空走。
		_moving = moved.length() > 0.5
		# 还动不了：如果人其实嵌在家具/墙里（碰撞体互相重叠），
		# 任何方向的 move_and_collide 都推不动，就会永久定住。攒几个 tick 后挪出去。
		# 注意必须真查重叠：单纯「顶着墙走不动」是物理上正常的，
		# 那种情况去推人只会让人在墙边来回抖，比站着不动还难受。
		if not _moving:
			if _overlaps():
				_stuck_ticks += 1
				if _stuck_ticks >= STUCK_TICKS:
					_stuck_ticks = 0
					_step_out()
			else:
				_stuck_ticks = 0
		else:
			_stuck_ticks = 0
	else:
		_moving = false
		_stuck_ticks = 0
		_step_len = 0.0


## 人物碰撞体是否正和房间/建筑的实体重叠（被挤进家具里了）。
func _overlaps() -> bool:
	return not _free_at(global_position)


## 把碰撞体整体摆到 world_pos 时是否为空。
## 用物理空间查询而不是 test_move：人已经嵌在碰撞体里时，
## test_move 从重叠状态出发永远返回「撞」，判断不出哪边是空地。
func _free_at(world_pos: Vector2) -> bool:
	var cs := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if cs == null or cs.shape == null:
		return true
	var off: Vector2 = cs.global_position - global_position
	var t: Transform2D = cs.global_transform
	t.origin = world_pos + off
	var q := PhysicsShapeQueryParameters2D.new()
	q.shape = cs.shape
	q.transform = t
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return get_world_2d().direct_space_state.intersect_shape(q, 1).is_empty()


## 从碰撞体里挪出来：由近到远环形找第一个能站人的点。
## 起床（碰撞从关闭恢复）后必须调一次 —— 躺着的位置就在床上，
## 不挪出来人物会直接卡死在床里，按什么方向都走不动。
func _step_out() -> bool:
	if _free_at(global_position):
		return false                                  # 本来就没嵌进去
	var dirs: Array[Vector2] = [
		Vector2.DOWN, Vector2.UP, Vector2.LEFT, Vector2.RIGHT,
		Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1),
	]
	for r in [6.0, 12.0, 20.0, 30.0, 44.0, 60.0]:
		for d in dirs:
			var p: Vector2 = global_position + (d as Vector2).normalized() * r
			if _free_at(p):
				global_position = p
				return true
	return false


func _process(delta: float) -> void:
	_hold_local_pose()
	_update_visual()
	_update_camera_zoom(delta)
	if not Net.is_server():
		var seq: int = int(server_state.get("seq", 0))
		var authoritative: Vector2 = server_state.get("position", server_position)
		if seq != last_seen_seq:
			last_seen_seq = seq
			if is_local_player:
				# 进房间期间本地权威：服务器不知道你在宿舍空间里，不能让它把人拉回校园
				# （否则相机 limit 卡在房间内，你会被卡在房间边界外、屏幕上只剩地板边角）。
				if not _room_freeze:
					_reconcile(seq, authoritative)
			smoother.push(authoritative, Time.get_ticks_msec())
		if not is_local_player:
			position = smoother.sample(Time.get_ticks_msec(), position)
		# Ease the visual into a correction instead of teleporting the sprite.
		correction_offset = correction_offset.lerp(Vector2.ZERO, minf(delta * 12.0, 1.0))
	# 视觉平滑：主机自己也要走这段（原来 Net.is_server() 直接 return，
	# 于是开房间的那个人看到的自己反而是最抖的）。
	#
	# 用「线性追平」而不是指数 lerp。物理位置每 tick（30Hz）跳一次，指数衰减
	# 每帧只追一部分，永远追不平：稳态滞后 + 每 tick 补跳一次 = 走起来一缩一缩
	# （在活动室这种空旷地面走直线时最明显，宿舍里老撞家具反而不容易看出来）。
	# 这里按上一步的实际长度算「这一 tick 该追多少」，视觉速度恒定，
	# 位移阶跃被填成连续匀速 —— 位置对得上，画面也不抖。
	var _chase: float = 0.0
	if _step_len > 0.001:
		_chase = (_step_len / maxf(NetTick.DELTA, 0.001)) * delta
		_render_lag = _render_lag.move_toward(Vector2.ZERO, _chase)
	else:
		# 站住了：残余滞后指数收回，别一下子吸过去
		_render_lag = _render_lag.lerp(Vector2.ZERO, minf(delta * RENDER_CHASE, 1.0))
	visual.position = correction_offset + _render_lag
	# 被楼挡住时自己也淡到 0.55：楼 0.45 + 人 0.55 叠起来能看清轮廓和位置
	_occl_a = move_toward(_occl_a, OCCL_ALPHA if _occluded else 1.0, delta * 4.0)
	visual.modulate.a = _occl_a
	_update_camera_follow()


## 相机对齐到「视觉位置」而不是物理位置。
## 精灵和相机同步滞后，角色在屏幕上就是稳稳居中的（差一点点就会来回晃）。
func _update_camera_follow() -> void:
	if not is_local_player:
		return
	var cam: Camera2D = $Camera
	cam.global_position = visual.global_position


## 视距平滑逼近目标值（滚一格不要整屏跳一下）
func _update_camera_zoom(delta: float) -> void:
	if not is_local_player:
		return
	var cam: Camera2D = $Camera
	var want: float = _cam_zoom_target
	var cur: float = cam.zoom.x
	if absf(want - cur) < 0.002:
		return
	var z: float = lerpf(cur, want, minf(delta * 14.0, 1.0))
	if absf(want - z) < 0.008:
		z = want
	cam.zoom = Vector2(z, z)


func _reconcile(seq: int, authoritative: Vector2) -> void:
	var predicted: Variant = buffer.predicted_at(seq)
	buffer.drop_through(seq)
	if predicted != null and authoritative.distance_to(predicted) < 0.05:
		return
	var before: Vector2 = position
	if predicted != null:
		NetDebug.reconciliations += 1
		NetDebug.last_correction = authoritative.distance_to(predicted)
	position = authoritative
	for entry in buffer.entries:
		_apply_movement(entry["command"])
		entry["position"] = position
	correction_offset += before - position
	if correction_offset.length() > RemoteSmootherScript.SNAP_DISTANCE:
		correction_offset = Vector2.ZERO
