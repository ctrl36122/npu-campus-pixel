extends Node
## The connection: hosting, joining, the roster of players, ready-up, chat and
## emotes. This is the only script that creates or closes the ENet peer.
##
## The server (peer id 1) is the authority for everything. Clients send
## requests; the server checks each one and publishes the result.
##
## Session-control RPCs here go straight out. Application messages (chat,
## emotes) go through send_to(), which routes them through NetDebug so the lag
## dial (F4) can delay or drop them for testing.

const DEFAULT_PORT: int = 7654
## 房间人数上限（含主机）。ENet 理论支持上千 peer，这里取一个校园同屏不拥挤、
## 性能稳妥的值；想再放开直接改这一行即可（出生环与名单都会自动跟着走）。
const MAX_PLAYERS: int = 32

## Emitted on this machine once it is fully in a session: right away when
## hosting, and once the server has accepted us when joining.
signal session_ready
## Emitted whenever the session ends, with a reason to show the player.
signal session_closed(reason: String)
## Emitted when anyone joins, leaves, renames or changes ready state.
signal roster_changed
## Server only: a peer is leaving. Clean up its avatar before it is removed.
signal peer_leaving(id: int)
signal message_received(speaker: String, text: String)
## 服务端补发的历史聊天（新加入的人会收到最近几十条）。和 message_received 分开，
## 这样客户端可以只把它塞进聊天面板、不弹头顶气泡。
signal history_received(speaker: String, text: String, unix_time: int)
signal emote_received(id: int, index: int)
## 联机信息变了（比如 UPnP 探测出结果），设置面板据此刷新「联机地址」那栏
signal info_changed

var last_error: String = ""
var local_name: String = "Player"
## 本地选好的角色外观 id（随注册上报，服务器用它决定每个人的贴图）
var local_hero: String = "adam"
## peer id -> {"name": String, "uid": String, "ready": bool}. The server owns
## this; clients receive copies through _receive_roster().
var peers: Dictionary = {}
var local_uid: String = ""
var session_id: String = ""
var _registered: bool = false
## True when started with --server: a headless host with no player of its own.
var is_dedicated: bool = false
## 单机会话（网页版）：浏览器里没有 UDP，ENet 建不了服务器，于是用
## OfflineMultiplayerPeer 假装自己是主机 —— Arena 的生成/同步逻辑照常按
## 「我是 server(peer 1)」跑，只是不会有别的玩家连进来。
var _offline: bool = false
## 本次会话走的是 WebSocket（浏览器只能连 WS，连不了 ENet/UDP）。
var _ws: bool = false
## 服务端 WebSocket 监听端口。反向代理（Caddy/nginx）把 443 的 TLS 解开后转发到这里。
const WS_PORT_DEFAULT: int = 9080
var _ws_port: int = WS_PORT_DEFAULT
var port_mapper: Node
## 当主机时：UPnP 映射到的公网地址（异地玩家填这个 IP 就能连进来）。
## 拿不到就是空串，原因写在 wan_status 里。
var public_address: String = ""
var wan_status: String = ""


## 网页导出、或显式加了 XGD_OFFLINE=1 时走单机（桌面也能用这个变量预演网页行为）
func is_offline() -> bool:
	return OS.has_feature("web") or OS.has_environment("XGD_OFFLINE")


## 命令行开关：
##   --server            专用服务器（无界面、只跑世界逻辑，可以给别人当主机）
##   --ws-port=9080      改 WebSocket 监听端口
func _parse_cmdline() -> void:
	for a in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if a == "--server":
			is_dedicated = true
		elif a.begins_with("--ws-port="):
			_ws_port = int(a.get_slice("=", 1))


## 玩家唯一 ID：第一次启动生成一次，之后永久固定（存 user://xgd_uid.cfg）。
## 以前是「时间戳+随机数」每次启动都变，换会话就成了另一个人 —— 服务器没法认人。
## 格式做成 xgd-7f3a2b：短、好念、能当面报给别人。
const UID_PATH := "user://xgd_uid.cfg"
## 去掉容易看错的字符（0/o、1/l/i）
const UID_ALPHABET := "23456789abcdefghjkmnpqrstuvwxyz"


func _load_uid() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(UID_PATH) == OK:
		var saved := str(cfg.get_value("me", "uid", "")).strip_edges()
		if saved.length() >= 6:
			local_uid = saved
			return
	var code := ""
	for i in 6:
		code += UID_ALPHABET[randi() % UID_ALPHABET.length()]
	local_uid = "xgd-" + code
	cfg.set_value("me", "uid", local_uid)
	cfg.save(UID_PATH)
	print("[net] 已生成玩家 ID：", local_uid)


func _ready() -> void:
	_parse_cmdline()
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(func(): leave_game("Connection failed. Check the address and UDP port."))
	multiplayer.server_disconnected.connect(func(): leave_game("The host disconnected. Start a new session from the lobby."))
	_load_uid()
	multiplayer.peer_disconnected.connect(_peer_disconnected)
	port_mapper = preload("res://net/scripts/net/PortMapper.gd").new()
	add_child(port_mapper)
	port_mapper.mapping_finished.connect(_on_upnp)


## Start a server on `port`. A listen server keeps one slot for its own player;
## a dedicated server gives every slot to clients. UPnP asks the router to open
## the port for internet play; leave it off for LAN and local testing.
func host_game(port: int = DEFAULT_PORT, max_players: int = MAX_PLAYERS, use_upnp: bool = false) -> Error:
	leave_game()
	# 网页版：浏览器开不了 UDP 服务器，用 OfflineMultiplayerPeer 起一个「本地主机」，
	# multiplayer.is_server() 仍为 true、id=1，Arena 里所有逻辑都不用改。
	if is_offline():
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
		_offline = true
		session_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
		peers[1] = {"name": local_name, "uid": local_uid, "hero": local_hero, "ready": false, "floor": 1}
		_registered = true
		roster_changed.emit()
		print("[net] 单机会话（web / XGD_OFFLINE）")
		session_ready.emit()
		return OK
	# 专用服务器 / 显式要求 WS：浏览器连不了 UDP，服务端必须说 WebSocket。
	# TLS 不在这里做（Godot 没有内置 TLS 服务端），由前面的 Caddy/nginx 解开后
	# 把明文 ws 转发到本机的 _ws_port。
	if is_dedicated or OS.has_environment("XGD_WS_SERVER"):
		var wsp := WebSocketMultiplayerPeer.new()
		# 专用服务器前面必然有一层反向代理（Caddy/nginx 把 443 解开再转 9080），
		# 所以只监听本机就够 —— 绑 0.0.0.0 会让 9080 直接对公网敞开，
		# 绕过代理的 TLS 和限流，等于多开一扇没人看的门。
		# 裸机直连（没有反代）可以用 XGD_WS_BIND=0.0.0.0 覆盖。
		var bind := "127.0.0.1" if is_dedicated else "*"
		if OS.has_environment("XGD_WS_BIND"):
			bind = OS.get_environment("XGD_WS_BIND")
		var werr: Error = wsp.create_server(_ws_port, bind)
		if werr != OK:
			last_error = "无法在 TCP %s:%d 上开 WebSocket（错误 %d）" % [bind, _ws_port, werr]
			print("[net] ", last_error)
			return werr
		multiplayer.multiplayer_peer = wsp
		_ws = true
		session_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
		if not is_dedicated:
			peers[1] = {"name": local_name, "uid": local_uid, "hero": local_hero, "ready": false, "floor": 1}
		_registered = true
		roster_changed.emit()
		print("[net] hosting WebSocket :%d（上限 %d 人）" % [_ws_port, max_players])
		session_ready.emit()
		return OK
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var slots: int = maxi(max_players - 1, 1)
	if is_dedicated:
		slots = max_players
	var err: Error = peer.create_server(port, slots)
	if err != OK:
		last_error = "Could not listen on UDP %d (error %d)." % [port, err]
		return err
	multiplayer.multiplayer_peer = peer
	session_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
	if not is_dedicated:
		peers[1] = {"name": local_name, "uid": local_uid, "hero": local_hero, "ready": false, "floor": 1}
	_registered = true
	roster_changed.emit()
	print("[net] hosting UDP %d, authority %d" % [port, my_id()])
	if use_upnp:
		port_mapper.request_mapping(port)
	session_ready.emit()
	return OK


## Connect to a server. session_ready fires later, once the server accepts us.
## 地址可以是 "ws://host/ws" / "wss://host/ws"（网页版、或连专用服务器），
## 也可以是纯 IP（局域网 ENet，exe 之间用）。
func join_game(address: String = "127.0.0.1", port: int = DEFAULT_PORT) -> Error:
	leave_game()
	if address.begins_with("ws://") or address.begins_with("wss://"):
		var wsp := WebSocketMultiplayerPeer.new()
		var werr: Error = wsp.create_client(address)
		if werr != OK:
			last_error = "无法连接 %s（错误 %d）" % [address, werr]
			return werr
		multiplayer.multiplayer_peer = wsp
		_ws = true
		return OK
	var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port)
	if err != OK:
		last_error = "Could not begin connection (error %d)." % err
		return err
	multiplayer.multiplayer_peer = peer
	return OK


func _connected() -> void:
	_register.rpc_id(1, local_name, local_uid, local_hero)


func has_session() -> bool:
	if _offline:
		return true
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	return peer != null and not peer is OfflineMultiplayerPeer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func is_connecting() -> bool:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	return peer != null and not peer is OfflineMultiplayerPeer and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTING


func is_server() -> bool:
	return has_session() and multiplayer.is_server()


func my_id() -> int:
	return multiplayer.get_unique_id() if has_session() else 0


## Close the connection and reset everything. Safe to call at any time.
func leave_game(reason: String = "") -> void:
	if is_instance_valid(port_mapper):
		port_mapper.release()
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	last_error = reason
	_offline = false
	_ws = false
	public_address = ""
	wan_status = ""
	peers.clear()
	session_id = ""
	_registered = false
	roster_changed.emit()
	session_closed.emit(reason)


func peer_count() -> int:
	return peers.size()


# ---------------------------------------------------------------- 异地联机辅助
## UPnP 结果：成功就记住公网地址，失败把原因翻译成人话给设置面板显示。
## 注意「路由器上游也是私有地址」= 运营商大内网（CGNAT），这种情况做端口映射
## 也没用，别人从公网找不到你 —— 只能换网络或用中继服务器。
func _on_upnp(ok: bool, msg: String) -> void:
	if ok:
		var idx := msg.find(" at ")
		public_address = msg.substr(idx + 4).get_slice(":", 0).strip_edges()
		wan_status = "已自动开端口"
	else:
		public_address = ""
		if msg.contains("No usable UPnP"):
			wan_status = "路由器不支持自动开端口"
		elif msg.contains("refused"):
			wan_status = "路由器拒绝了端口映射"
		elif msg.contains("private/shared"):
			wan_status = "你的网络没有独立公网 IP"
		else:
			wan_status = "自动开端口失败"
	print("[net] UPnP：", wan_status, " ", public_address)
	info_changed.emit()


## 本机在局域网里的地址（同 WiFi 的玩伴填这个）
func lan_address() -> String:
	for a in IP.get_local_addresses():
		if a.contains(":") or a.begins_with("127.") or a.begins_with("169.254."):
			continue
		var p := a.split(".")
		if p.size() != 4:
			continue
		var a0 := int(p[0])
		var a1 := int(p[1])
		if a0 == 192 or a0 == 10 or (a0 == 172 and a1 >= 16 and a1 <= 31):
			return a
	return ""


## 设置面板里显示的联机信息（含可复制给别人的地址）
func net_info_text() -> String:
	if not has_session():
		return "尚未联机"
	if not is_server():
		return "你连的是别人的校园。\n想让别人连你：让对方当主机，你在「服务器地址」里填他的 IP。"
	var lines: Array[String] = []
	var lan := lan_address()
	if lan != "":
		lines.append("同一 WiFi → %s:%d" % [lan, DEFAULT_PORT])
	if public_address != "":
		lines.append("异地直连 → %s:%d" % [public_address, DEFAULT_PORT])
	else:
		lines.append("异地直连 → 不可用（%s）" % (wan_status if wan_status != "" else "正在探测…"))
	return "\n".join(lines)


# --- Joining: the server validates every registration ---------------------

## Sent by a newly connected client. The server rejects anyone already
## registered, or reusing another player's uid, and cleans the display name.
@rpc("any_peer", "call_remote", "reliable", 0)
func _register(display_name: String, uid: String, hero: String = "adam") -> void:
	if not is_server():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if not multiplayer.get_peers().has(sender) or peers.has(sender):
		return
	# ENet 服务端靠 create_server 的 slots 限流；WebSocket 没这个概念（也没法拒绝
	# 已握手的连接），所以在这里挡：满了就不登记，他自己会停在「正在进入校园」。
	if peers.size() >= MAX_PLAYERS:
		print("[net] 房间已满（%d），拒绝 peer %d" % [MAX_PLAYERS, sender])
		return
	var safe_uid: String = uid.left(80)
	for entry in peers.values():
		if entry["uid"] == safe_uid:
			return
	var safe_name: String = display_name.strip_edges().left(24)
	if safe_name.is_empty():
		safe_name = "Player"
	peers[sender] = {"name": safe_name, "uid": safe_uid, "hero": hero, "ready": false, "floor": 1}
	_publish_roster()
	_send_history_to(sender)          # 新来的人先看到刚才在聊什么
	_sync_claims.rpc_id(sender, room_claims)   # 以及现有的房间认领公告


func _publish_roster() -> void:
	if not is_server():
		return
	roster_changed.emit()
	_receive_roster.rpc(peers, session_id)


## The server's copy of the roster, pushed to every client. Only the server
## (the multiplayer authority) can call this.
@rpc("authority", "call_remote", "reliable", 0)
func _receive_roster(snapshot: Dictionary, session: String) -> void:
	peers = snapshot.duplicate(true)
	session_id = session
	roster_changed.emit()
	if not _registered and peers.has(my_id()):
		_registered = true
		session_ready.emit()
	_dedupe_my_name()


## 客户端：发现自己的昵称和别人撞了，就自动加后缀。
## 同机双开共用同一个 user:// 存档时会撞名，不处理的话两个名牌叠在一起分不清。
func _dedupe_my_name() -> void:
	if is_server() or not peers.has(my_id()):
		return
	var mine: String = str(peers[my_id()].get("name", ""))
	if mine.is_empty():
		return
	for id in peers:
		if int(id) == my_id():
			continue
		if str(peers[id].get("name", "")) == mine:
			set_my_name("%s·%02d" % [mine, my_id() % 100])
			return


func _peer_disconnected(id: int) -> void:
	if not is_server() or not peers.has(id):
		return
	# Remove the avatar first, then the roster entry.
	peer_leaving.emit(id)
	peers.erase(id)
	_publish_roster()


# --- Application messages (these go through the lag dial) ------------------

## Send an RPC to one peer (0 = everyone) through NetDebug, so the F4 dial can
## delay or drop it. A message from an old session is never delivered.
func send_to(target: int, node: Node, method: StringName, args: Array = []) -> void:
	if not has_session() or not is_instance_valid(node):
		return
	var epoch: String = session_id
	NetDebug.send(args, func(values: Array):
		if session_id == epoch:
			dispatch(target, node, method, values))


func dispatch(target: int, node: Node, method: StringName, args: Array) -> void:
	if not has_session() or not is_instance_valid(node) or not node.is_inside_tree():
		return
	if target != 0 and target != my_id() and not multiplayer.get_peers().has(target):
		return
	var call_args: Array = [target, method]
	call_args.append_array(args)
	node.callv("rpc_id", call_args)


func broadcast(node: Node, method: StringName, args: Array = []) -> void:
	send_to(0, node, method, args)


## Count a received application message for the network inspector (F3).
func note_received(args: Array = []) -> void:
	NetDebug.received_messages += 1
	NetDebug.received_payload_bytes += var_to_bytes(args).size()


## Chat. Every receiver checks that the sender is a registered player and cuts
## the text to 160 characters, so no client can post as someone else.
## 注意：调用方必须用 `post_message.rpc(text)` —— 直接 `Net.post_message(text)`
## 只是本地函数调用，消息不会离开本机（以前就是这么坏的）。
@rpc("any_peer", "call_local", "reliable", 0)
func post_message(text: String) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = my_id()
	if not peers.has(sender):
		return
	note_received([text])
	var speaker: String = str(peers[sender]["name"])
	var clean := text.left(160)
	# 只有服务端落盘（客户端各有一份副本，写多了会互相覆盖）
	if is_server():
		_record_chat(speaker, clean)
	message_received.emit(speaker, clean)


# ---------------------------------------------------------------- 聊天落盘
## 服务端把聊天记录写进 user://chat_log.json：重启不丢、新来的人能看到刚才在聊什么。
## 客户端不需要这份文件（加入时会由服务端补发），所以只在 is_server() 时读写。
const CHAT_LOG_PATH := "user://chat_log.json"
const CHAT_KEEP := 500          # 文件里最多留多少条
const CHAT_SEND_ON_JOIN := 40   # 新人加入时补发最近多少条
var _chat_log: Array = []
var _chat_loaded := false


func _load_chat_log() -> void:
	_chat_loaded = true
	if not FileAccess.file_exists(CHAT_LOG_PATH):
		return
	var f := FileAccess.open(CHAT_LOG_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Array:
		_chat_log = parsed


func _save_chat_log() -> void:
	var f := FileAccess.open(CHAT_LOG_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[net] 聊天记录写不进去：%s" % CHAT_LOG_PATH)
		return
	f.store_string(JSON.stringify(_chat_log))
	f.close()


func _record_chat(speaker: String, text: String) -> void:
	if not _chat_loaded:
		_load_chat_log()
	_chat_log.append({
		"n": speaker,
		"m": text,
		"t": int(Time.get_unix_time_from_system()),
	})
	while _chat_log.size() > CHAT_KEEP:
		_chat_log.pop_front()
	_save_chat_log()


## 新玩家登记成功后，服务端把最近几十条历史补发给他
func _send_history_to(peer_id: int) -> void:
	if not _chat_loaded:
		_load_chat_log()
	if _chat_log.is_empty():
		return
	var from: int = maxi(0, _chat_log.size() - CHAT_SEND_ON_JOIN)
	_push_history.rpc_id(peer_id, _chat_log.slice(from))


@rpc("authority", "call_remote", "reliable", 1)
func _push_history(items: Array) -> void:
	print("[net] 收到补发的聊天历史 ", items.size(), " 条")
	for it in items:
		if not (it is Dictionary):
			continue
		history_received.emit(str(it.get("n", "?")), str(it.get("m", "")), int(it.get("t", 0)))


## A quick emote over your head. Unreliable on its own channel (2): losing one
## does not matter, and it never waits behind chat or movement.
func emote(index: int) -> void:
	if not has_session():
		return
	emote_received.emit(my_id(), clampi(index, 0, 3))
	broadcast(self, &"_show_emote", [clampi(index, 0, 3)])


@rpc("any_peer", "call_remote", "unreliable", 2)
func _show_emote(index: int) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	if peers.has(sender):
		emote_received.emit(sender, clampi(index, 0, 3))


# --- 坐椅子 ---------------------------------------------------------------

## id, 坐姿方向（0 = 站起来），座位世界坐标
signal seat_changed(id: int, dir: int, pos: Vector2)

## 上次坐下/起身的时间戳（秒），兼作防刷：0.25s 内只认一次
var _seat_gate: Dictionary = {}


## 坐下 / 起身。dir：1..4 = 坐下（面朝 down/left/right/up），5..8 = 躺下，0 = 起身。
##
## 客户端**先在本地生效**再发请求：座位只是自己的姿势，位置也已经由自己算好。
## 以前客户端纯等服务端回包，而服务端的 _request_seat 只改了它自己那份、
## 根本没广播 —— 结果客户端按 E 完全没反应（椅子坐不下、床躺不下）。
func sit_down(dir: int, pos: Vector2) -> void:
	var d: int = clampi(dir, 0, 8)
	if not has_session():
		seat_changed.emit(my_id(), d, pos)          # 单机：自己说了算
		return
	if is_server():
		_apply_seat(1, d, pos)
		broadcast(self, &"_show_seat", [1, d, pos])
		return
	seat_changed.emit(my_id(), d, pos)              # 本地先落地（界面立刻响应）
	_request_seat.rpc_id(1, d, pos)                 # 再请服务端裁定并广播给别人


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_seat(dir: int, pos: Vector2) -> void:
	if not is_server():
		return
	var id: int = multiplayer.get_remote_sender_id()
	# 这里以前 clamp 到 0..4，5..8 的躺姿被削成「面朝上的坐姿」—— 床等于废了
	var d: int = clampi(dir, 0, 8)
	_apply_seat(id, d, pos)
	# 转发给所有人（含发起者）：以前这里不广播，别人看不到你坐下，
	# 你自己也收不到任何确认，表现就是「按 E 没反应」。
	broadcast(self, &"_show_seat", [id, d, pos])


## 服务端：改这个玩家的座位状态并推给所有人
func _apply_seat(id: int, dir: int, pos: Vector2) -> void:
	if not peers.has(id):
		return
	var now := float(Time.get_ticks_msec()) / 1000.0
	if now - float(_seat_gate.get(id, -9.0)) < 0.25:
		return
	_seat_gate[id] = now
	seat_changed.emit(id, dir, pos)


## 收到某人的姿势变化。参数兼容两种形状，方便新旧服务端混跑：
##   新：(玩家 id, 姿势, 坐标)   旧：(姿势, 坐标)，只可能是服务端自己
@rpc("any_peer", "call_remote", "reliable", 0)
func _show_seat(a: Variant, b: Variant, c: Variant = null) -> void:
	var id := 1
	var dir := 0
	var pos := Vector2.ZERO
	if c == null:
		dir = int(a)
		pos = Vector2(b)
	else:
		id = int(a)
		dir = int(b)
		pos = Vector2(c)
	if not peers.has(id):
		return
	seat_changed.emit(id, clampi(dir, 0, 8), pos)


# --- 楼层 ---------------------------------------------------------------
## 每层宿舍布局完全相同，所以「换层」不搬几何，只改每个玩家所在的楼层号。
## 楼层号挂在 roster 里（peers[id]["floor"]）随名单一起同步：同层的人才互相可见，
## 异层的人互相隐藏 —— 既省内存（只实例化一份房间），联机也不会穿帮。
## 本机自己的楼层变化用 set_my_floor() 请求，服务端裁定后广播。
func set_my_floor(n: int) -> void:
	var f: int = clampi(n, 1, 99)
	if is_server():
		_apply_floor(1, f)
	elif has_session():
		_request_floor.rpc_id(1, f)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_floor(n: int) -> void:
	if is_server():
		_apply_floor(multiplayer.get_remote_sender_id(), n)


func _apply_floor(id: int, n: int) -> void:
	if not is_server() or not peers.has(id):
		return
	peers[id]["floor"] = clampi(n, 1, 99)
	_publish_roster()


## 某个玩家现在在第几层（1 起）。没登记就按 1 层。
func floor_of(id: int) -> int:
	return int(peers.get(id, {}).get("floor", 1))


# --- 房间认领公告 -------------------------------------------------------
## "floor:room" -> {"name": String, "uid": String, "note": String}。
## 服务端权威，客户端只发请求；note 是房主写的门口公告（自我介绍），可缺省。
signal room_claims_changed
var room_claims: Dictionary = {}


## 认领 / 取消某间房（name 为空 = 取消）。
## **客户端也先本地落地**：等服务端回包才改界面，一旦对面是旧版服务端（这个 RPC
## 它不认识，包直接被丢掉），就会变成「提示说认领成功、牌子上还是空房」。
## 先写本地再发请求，界面永远和操作一致；服务端随后广播的全量快照会覆盖它。
func claim_room(floor_n: int, room_idx: int, display_name: String) -> void:
	var nm: String = display_name.strip_edges().left(24)
	if not has_session():
		_write_claim(local_uid, floor_n, room_idx, nm)
		return
	if is_server():
		_write_claim(local_uid, floor_n, room_idx, nm)
		_sync_claims.rpc(room_claims)
		return
	_write_claim(local_uid, floor_n, room_idx, nm)
	_request_claim.rpc_id(1, floor_n, room_idx, nm)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_claim(n: int, r: int, nm: String) -> void:
	if not is_server():
		return
	_apply_claim(multiplayer.get_remote_sender_id(), n, r, nm.strip_edges().left(24))
	_sync_claims.rpc(room_claims)


## 服务端：写入认领。**一个人同时只能有一间**：认领新房间会自动退掉他之前的房间。
## 已被别人的 uid 认领的房不抢；name 为空则取消。
func _apply_claim(peer_id: int, n: int, r: int, nm: String) -> void:
	var uid := local_uid if peer_id <= 1 else str(peers.get(peer_id, {}).get("uid", ""))
	_write_claim(uid, n, r, nm)


## 真正改 room_claims 的地方（服务端裁定和客户端本地预写共用一套规则）。
## 返回 true 表示这次改动确实生效了 —— 调用方据此判断「是不是真认领到」，
## 而不是靠“我发过请求了”就报成功。
func _write_claim(uid: String, n: int, r: int, nm: String) -> bool:
	if n < 1 or r < 0 or uid.is_empty():
		return false
	var key := "%d:%d" % [n, r]
	var cur: Dictionary = room_claims.get(key, {})
	if not cur.is_empty() and String(cur.get("uid", "")) != uid:
		return false                   # 是别人的房间，不允许覆盖
	if nm.is_empty():
		if cur.is_empty():
			return false
		room_claims.erase(key)
	else:
		# 退掉同一 uid 名下的其它房间（「每个人只能同时占有一个房间」）
		for k in room_claims.keys():
			if String(k) == key:
				continue
			if String(Dictionary(room_claims[k]).get("uid", "")) == uid:
				room_claims.erase(k)
		room_claims[key] = {"name": nm, "uid": uid}
	room_claims_changed.emit()
	return true


## 某个 uid 现在认领的是哪间房，返回 "楼层:房号"；没有就返回 ""。
func claim_of_uid(uid: String) -> String:
	if uid.is_empty():
		return ""
	for k in room_claims.keys():
		if String(Dictionary(room_claims[k]).get("uid", "")) == uid:
			return String(k)
	return ""


## 本机认领的房间 "楼层:房号"（没认领则空），用来决定「这次从哪儿出生」
func my_claim() -> String:
	return claim_of_uid(local_uid)


@rpc("authority", "call_remote", "reliable", 0)
func _sync_claims(snapshot: Dictionary) -> void:
	room_claims = snapshot.duplicate(true)
	room_claims_changed.emit()


## 房主改写自家门口的公告（自我介绍）。只有认领人本人能写；空串 = 擦掉。
## 公告跟着认领走：撕下公告（取消认领）时整条记录一并消失。
func set_room_note(room_idx: int, note: String) -> void:
	var txt: String = _clean_note(note)
	if not has_session():
		_apply_note(local_uid, room_idx, txt)
		return
	if is_server():
		_apply_note(local_uid, room_idx, txt)
		_sync_claims.rpc(room_claims)
		return
	# 客户端同样先本地写，理由和 claim_room 一样（旧服务端会把请求丢掉）
	_apply_note(local_uid, room_idx, txt)
	_request_note.rpc_id(1, room_idx, txt)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_note(r: int, note: String) -> void:
	if not is_server():
		return
	var uid := str(peers.get(multiplayer.get_remote_sender_id(), {}).get("uid", ""))
	_apply_note(uid, r, _clean_note(note))
	_sync_claims.rpc(room_claims)


## 公告正文清洗：多行保留换行（面板里本来就按多行展示），去掉首尾空白，
## 长度上限 160 字 —— 一间宿舍的门板写得下一小段自我介绍就够。
func _clean_note(note: String) -> String:
	return note.replace("\r", "").replace("\u0000", "").strip_edges().left(160)


## 服务端：把 note 写进该 uid 名下那间房的认领记录。没认领过房间的写不进去。
func _apply_note(uid: String, r: int, note: String) -> void:
	if uid.is_empty() or r < 0:
		return
	var key := claim_of_uid(uid)
	if key.is_empty():
		return
	var cur: Dictionary = room_claims[key]
	if note.is_empty():
		cur.erase("note")
	else:
		cur["note"] = note
	room_claims[key] = cur
	room_claims_changed.emit()


# --- Ready-up lobby -------------------------------------------------------

func set_ready(value: bool) -> void:
	if is_server():
		_apply_ready(1, value)
	elif has_session():
		_request_ready.rpc_id(1, value)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_ready(value: bool) -> void:
	if is_server():
		_apply_ready(multiplayer.get_remote_sender_id(), value)


## Server only. Ready state can only change in the lobby, and only for a
## registered player. A dedicated server starts the round when all are ready.
func _apply_ready(id: int, value: bool) -> void:
	if peers.has(id) and GameState.phase == GameState.Phase.LOBBY:
		peers[id]["ready"] = value
		_publish_roster()
		if is_dedicated and can_start():
			SessionFlow.start_run()


## True on the server when every player is ready and has loaded the world.
func can_start() -> bool:
	if not is_server() or peers.is_empty() or GameState.phase != GameState.Phase.LOBBY:
		return false
	for id in peers:
		if not bool(peers[id].get("ready", false)) or not SessionFlow.world_ready.has(id):
			return false
	return true


func reset_readiness() -> void:
	if not is_server():
		return
	for id in peers:
		peers[id]["ready"] = false
	_publish_roster()


# --- 在线改名 / 换装（常驻世界里随时可改，不用断线重连）-------------------

## 改自己的昵称。主机直接改，客户端发请求由主机校验后广播。
func set_my_name(new_name: String) -> void:
	var clean: String = new_name.strip_edges().left(24)
	if clean.is_empty():
		return
	if is_server():
		_apply_name(1, clean)
	elif has_session():
		_request_name.rpc_id(1, clean)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_name(new_name: String) -> void:
	if is_server():
		_apply_name(multiplayer.get_remote_sender_id(), new_name)


func _apply_name(id: int, new_name: String) -> void:
	if not peers.has(id) or not is_server():
		return
	var clean: String = new_name.strip_edges().left(24)
	if clean.is_empty():
		return
	peers[id]["name"] = clean
	_publish_roster()


## 换自己的外观。avatar 的 hero_id 已加入 SceneReplicationConfig，改了会自动同步。
func set_my_hero(hero: String) -> void:
	if hero.is_empty():
		return
	local_hero = hero
	if is_server():
		_apply_hero(1, hero)
	elif has_session():
		_request_hero.rpc_id(1, hero)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_hero(hero: String) -> void:
	if is_server():
		_apply_hero(multiplayer.get_remote_sender_id(), hero)


func _apply_hero(id: int, hero: String) -> void:
	if not peers.has(id) or not is_server():
		return
	peers[id]["hero"] = hero
	_publish_roster()
	if is_instance_valid(SessionFlow.world) and SessionFlow.world.has_method("set_hero_of"):
		SessionFlow.world.set_hero_of(id, hero)
