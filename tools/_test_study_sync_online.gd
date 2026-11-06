extends SceneTree
## 图书馆（7 层）联机动作实时性实测：两个进程，都用 wall clock 毫秒打点。
##
##   XGD_SYNC_PAIR=1：主机移动 / 客户端看（验「别人眼里看到你」的完整渲染链路）
##   XGD_SYNC_PAIR=2：客户端移动 / 主机看（验 _push_room_pose 上报链路）
##   每对里先起主机端（XGD_SYNC_ROLE 按 pair 决定），等它打印 HOST_READY 再起另一端。
##
## 不加载 online_boot（探针自己建会话，SessionFlow 在 session_ready 里建世界），
## 所以不会去连公共服。两个进程必须不同 APPDATA，且**绝对不要设 XGD_OFFLINE**
## （那会走 OfflineMultiplayerPeer，联机链路根本不成立）。
##
## 断言数据都在采样时缓存：对端可能先退出、远端 avatar 会被销毁，
## 直接在对端消失后读属性只会得到 null，测出来的是探针生命周期不是同步质量。

const PORT := 7656
const FLOOR := 7
const STEP := 60.0
const STEPS := 6
const GAP_MS := 900
const MIN_SEEN := 4                 # headless 双进程同机抢 CPU 会漏几帧，别卡太死

var net: Node
var role := ""
var pair := 1
var is_host := false
var world
var me
var remote
var started := false
var entered := false
var t0 := 0
var step := -1
var next_at := 0
var base_x := 0.0
var peer_ready := false
var last_seq := 0
var last_x := -999999.0
var state_seen: Dictionary = {}     # 目标 x -> server_state 到达的 wall ms
var rendered: Dictionary = {}       # 目标 x -> 渲染位置追平的 wall ms
var seq_times: Array[int] = []
var frames := 0
var floor_seen_at := 0
var visible_seen_at := 0
# 缓存断言依据
var a_roster_floor := -1
var a_inside := false
var a_room_floor := -1
var a_visible := false
var checks := 0
var fails: Array[String] = []
var done := false
var last_diag := 0


func _wall() -> int:
	return int(round(Time.get_unix_time_from_system() * 1000.0))


func _ms() -> int:
	return Time.get_ticks_msec() - t0


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _initialize() -> void:
	t0 = Time.get_ticks_msec()
	role = OS.get_environment("XGD_SYNC_ROLE")
	if OS.get_environment("XGD_SYNC_PAIR") == "2":
		pair = 2
	net = root.get_node_or_null("Net")
	if net == null or role.is_empty():
		print("[sync] 结果 FAIL：缺 Net 或 XGD_SYNC_ROLE")
		done = true
		quit(1)


func _find_avatars() -> void:
	var sf := root.get_node_or_null("SessionFlow")
	if sf != null and world == null:
		world = sf.get("world")
	if world == null:
		return
	var need_remote := role == "watcher"
	if me != null and is_instance_valid(me) \
			and (not need_remote or (remote != null and is_instance_valid(remote))):
		return
	for n in root.find_children("*", "CharacterBody2D", true, false):
		if bool(n.get("is_local_player")):
			me = n
		elif pair == 2:
			if int(n.get("owner_peer_id")) != 1:
				remote = n
		elif int(n.get("owner_peer_id")) == 1:
			remote = n


func _finish() -> bool:
	if role == "watcher":
		var ps: Dictionary = net.get("peers")
		if a_roster_floor < 0 and int(ps.get(1, {}).get("floor", -1)) == FLOOR:
			a_roster_floor = FLOOR
		_ok(a_roster_floor == FLOOR, "主机楼层在名单里是 7", str(a_roster_floor))
		_ok(a_inside, "对方角色 room_inside 同步成 true")
		_ok(a_room_floor == FLOOR, "对方角色 room_floor 同步成 7", str(a_room_floor))
		_ok(a_visible, "同层可见：对方角色没被隐藏")
		_ok(state_seen.size() >= MIN_SEEN, "server_state 收到位置变化（>=%d）" % MIN_SEEN,
			str(state_seen.size()))
		_ok(rendered.size() >= MIN_SEEN, "渲染/权威位置追平（>=%d）" % MIN_SEEN,
			str(rendered.size()))
		_ok(floor_seen_at > 0, "room_floor 确实同步到位",
			("wall=%d" % floor_seen_at) if floor_seen_at > 0 else "没同步")
		_ok(visible_seen_at > 0, "角色确实变可见",
			("wall=%d" % visible_seen_at) if visible_seen_at > 0 else "一直隐藏")
		var gaps: Array[int] = []
		for i in range(1, seq_times.size()):
			gaps.append(seq_times[i] - seq_times[i - 1])
		gaps.sort()
		var med := 0
		if not gaps.is_empty():
			med = gaps[gaps.size() / 2]
		print("[sync] STAT frames=%d seq_changes=%d gap_min=%d gap_med=%d gap_max=%d" %
			[frames, seq_times.size(),
			gaps.front() if not gaps.is_empty() else -1, med,
			gaps.back() if not gaps.is_empty() else -1])
	else:
		_ok(peer_ready, "对端楼层同步成 7（同层可见前提）")
		_ok(step + 1 == STEPS, "发满 %d 次位置变化" % STEPS, str(step + 1))
	done = true
	if fails.is_empty() and checks > 0:
		print("[sync] 结果 PASS：%s pair=%d %d 项" % [role, pair, checks])
		quit(0)
	else:
		print("[sync] 结果 FAIL：%s %s" % [role, ", ".join(fails)])
		quit(1)
	return true


func _process(_d: float) -> bool:
	if done:
		return true
	frames += 1
	# 到点统一收尾：主机多留 2 秒，保证它最后退出，不会掐断对端连接。
	if started and _ms() > (24000 if is_host else 22000):
		return _finish()
	if not started:
		started = true
		is_host = (role == "mover" and pair == 1) or (role == "watcher" and pair == 2)
		if is_host:
			print("[sync] HOST_START wall=%d" % _wall())
			var e: int = net.call("host_game", PORT)
			print("[sync] host_game=%d wall=%d" % [e, _wall()])
		else:
			var e2: int = net.call("join_game", "127.0.0.1", PORT)
			print("[sync] join_game=%d wall=%d" % [e2, _wall()])
		return false

	_find_avatars()
	if world == null or me == null:
		if _ms() - last_diag > 2000:
			last_diag = _ms()
			print("[sync] DIAG role=%s has_session=%s world=%s me=%s t=%d" %
				[role, str(net.call("has_session")), str(world != null),
				str(me != null and is_instance_valid(me)), _ms()])
		return false
	if not entered:
		var ok: bool = bool(world.call("enter_room", "res://assets/rooms/study_space.json", FLOOR))
		if not ok:
			return false
		entered = true
		base_x = (me as Node2D).position.x
		print("[sync] ENTERED role=%s pair=%d floor=%d wall=%d x=%.1f" %
			[role, pair, FLOOR, _wall(), base_x])
		if is_host:
			print("[sync] HOST_READY wall=%d" % _wall())
		if role == "mover":
			next_at = _ms() + 1500
		return false

	if role == "mover":
		return _tick_mover()
	return _tick_watcher()


func _tick_mover() -> bool:
	var ps: Dictionary = net.get("peers")
	for id in ps:
		var is_other_side := (int(id) != 1) if pair == 1 else (int(id) == 1)
		if is_other_side and int(ps[id].get("floor", 0)) == FLOOR:
			peer_ready = true
	if peer_ready and step + 1 < STEPS and _ms() >= next_at:
		step += 1
		var x := base_x + float(step + 1) * STEP
		# 房间内主机每 tick 把 position 写进 server_state，客户端每 tick 走
		# _push_room_pose 上报 —— 直接挪本地坐标就是在模拟「走动」。
		(me as Node2D).position.x = x
		print("[sync] SEND k=%d wall=%d x=%.1f" % [step, _wall(), x])
		next_at = _ms() + GAP_MS
	return false


func _tick_watcher() -> bool:
	if remote == null or not is_instance_valid(remote):
		return false
	var ps: Dictionary = net.get("peers")
	if int(ps.get(1, {}).get("floor", -1)) == FLOOR:
		a_roster_floor = FLOOR
	if bool(remote.get("room_inside")):
		a_inside = true
	if int(remote.get("room_floor")) == FLOOR:
		a_room_floor = FLOOR
		if floor_seen_at == 0:
			floor_seen_at = _wall()
			print("[sync] FLOOR7 wall=%d" % floor_seen_at)
	if bool((remote as Node2D).visible):
		a_visible = true
		if visible_seen_at == 0:
			visible_seen_at = _wall()
			print("[sync] VISIBLE wall=%d" % visible_seen_at)

	var st: Dictionary = remote.get("server_state")
	var seq := int(st.get("seq", 0))
	var sv: Vector2 = st.get("position", Vector2.ZERO)
	if seq != last_seq:
		last_seq = seq
		seq_times.append(_wall())
		if absf(sv.x - last_x) > 0.5:
			last_x = sv.x
			state_seen[sv.x] = _wall()
			print("[sync] STATE wall=%d x=%.1f seq=%d" % [_wall(), sv.x, seq])
	var px: float = (remote as Node2D).position.x
	for x in state_seen.keys():
		if rendered.has(x):
			continue
		if absf(px - float(x)) < 4.0:
			rendered[x] = _wall()
			print("[sync] RENDER wall=%d x=%.1f" % [_wall(), float(x)])
	return false
