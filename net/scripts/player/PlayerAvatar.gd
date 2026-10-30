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
const ZOOM_BASE: float = 1.2
const ZOOM_MIN: float = 0.55
const ZOOM_MAX: float = 3.0
const ZOOM_STEP: float = 1.14
## One colour per roster slot. The roster is the same on every machine, so every
## window agrees on who is who.
const COLORS: Array[Color] = [Color("5b8cff"), Color("ff9f43"), Color("2ed573"), Color("ff6b9d")]

## sit_dir 的 1..4 对应的朝向名（顺序和图集的 *_sit 动画一致）
const SIT_DIRS: Array[String] = ["down", "left", "right", "up"]

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
## 被楼挡住时为 true（Arena 每帧设置）：楼和人都变半透明，经典 RPG 做法
var _occluded: bool = false
## 当前不透明度，向目标平滑逼近（走过楼边不该「啪」一下变透）
var _occl_a: float = 1.0
## 进宿舍空间期间本地权威：服务器不知道你在房间里，临时冻结对自己位置的 reconcile，
## 否则服务器每帧把人拉回校园，而相机 limit 卡在房间内 → 你被困在房间边界外、看不到自己。
var _room_freeze := false
var _stand_req_at := 0.0


## 被楼挡住 → 精灵调淡（名牌保持不透明，方便找人）
func set_occluded(v: bool) -> void:
	_occluded = v


func _enter_tree() -> void:
	owner_peer_id = str(name).to_int()
	set_multiplayer_authority(1)


func _ready() -> void:
	if OS.has_environment("XGD_ZOOM"):
		_cam_zoom_target = clampf(OS.get_environment("XGD_ZOOM").to_float(), ZOOM_MIN, ZOOM_MAX)
	scale = Vector2(0.375, 0.375)
	$Name.add_theme_font_size_override("font_size", 11)
	bubble.add_theme_font_size_override("font_size", 12)
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
		cam.limit_right = 6784           # ⚠️ limit 用全局坐标（世界全局 = 局部×2），别改成局部值
		cam.limit_bottom = 12800
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


## 坐到椅子上。pos 是座位点（人物脚底），dir_name 取 down/left/right/up。
## 会先 teleport 吸附过去，再切坐姿动画。
##
## ⚠️ 必须同时关掉碰撞体：椅子本身是实心的（world/room 里都有 StaticBody2D），
## 人一坐到椅子上就和它重叠，物理会把人推开 —— 表现是「刚坐下就被弹到旁边」。
## 站起来时再打开，走路照样会被椅子挡住。
func sit_at(pos: Vector2, dir_name: String) -> void:
	var i := SIT_DIRS.find(dir_name)
	sit_dir = (i if i >= 0 else 0) + 1
	teleport_to(pos)
	_set_collision(false)
	_apply_sit_anim()


func stand_up() -> void:
	if sit_dir == 0:
		return
	sit_dir = 0
	_set_collision(true)
	_update_visual()


## 坐下后按方向键 → 起身。本地立刻生效，同时告诉服务端（座位状态它说了算）。
## 400ms 节流：起身要等广播回来，期间每一帧都会走到这里，不挡就会刷 RPC。
func _request_stand() -> void:
	var now := float(Time.get_ticks_msec())
	if now - _stand_req_at < 400.0:
		return
	_stand_req_at = now
	stand_up()
	Net.sit_down(0, Vector2.ZERO)


func _set_collision(on: bool) -> void:
	var cs := get_node_or_null("CollisionShape2D")
	if cs != null:
		cs.set_deferred("disabled", not on)


## 坐姿是单帧动画（loop=0），切换时才 play，免得每帧重置
func _apply_sit_anim() -> void:
	if sprite == null:
		return
	var anim := StringName(SIT_DIRS[clampi(sit_dir - 1, 0, SIT_DIRS.size() - 1)] + "_sit")
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
		if buffer.entries.size() < InputBufferScript.CAPACITY:
			var command: Dictionary = input.sample(self, next_seq, tick)
			if ui_blocked:                       # 设置面板打开时冻结移动
				command["x"] = 0.0
				command["y"] = 0.0
			next_seq += 1
			if not Net.is_server():
				_apply_movement(command)
			buffer.push(command, position)
		if Net.is_server():
			for command in buffer.pending():
				_accept_command(owner_peer_id, command)
		else:
			# Resend everything unacknowledged: unreliable packets can be lost.
			Net.send_to(1, self, &"_push_inputs", [buffer.pending()])
	if Net.is_server():
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
	var direction: Vector2 = Vector2(float(command.get("x", 0.0)), float(command.get("y", 0.0))).limit_length()
	# 坐着就不动。本地预测和服务端模拟都走这个函数，一处判断两边一致，
	# 否则会出现「自己看着没动、别人看着在椅子上蹭」。
	if sit_dir != 0:
		# 按方向键 = 想走，那就站起来。不然玩家坐下后按 WASD 毫无反应，
		# 十个里有九个会以为卡死了。本地先起，手感不用等一个 RTT。
		if direction.length() > 0.1 and is_local_player:
			_request_stand()
		velocity = Vector2.ZERO
		_moving = false
		return
	var speed: float = SPEED
	if bool(command.get("sprint", false)):
		speed *= 1.55
	velocity = direction * speed
	var before := position
	move_and_collide(velocity * NetTick.DELTA)
	var moved := position - before
	# 物理位置已经前移，视觉位置留在原处（_render_lag 抵消掉这一步），
	# 再由 _process 平滑追上去 —— 30Hz 的阶跃就变成了连续移动。
	_render_lag -= moved
	# 视觉方向跟着实际输入走（服务端模拟时同样会更新，保证远端看到的朝向一致）
	if direction.length() > 0.01:
		_face_dir = direction.normalized()
		# 撞墙/家具被挡住、实际没挪动 → 不播行走动画，否则会「原地踏步」
		# （宿舍里家具密，走几步就贴上去、动画却一直循环，看着就像卡死了）。
		# 仍保持 _face_dir，所以角色会面朝挡住他的那面墙、站定，而不是诡异地空走。
		_moving = moved.length() > 0.5
	else:
		_moving = false


func _process(delta: float) -> void:
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
