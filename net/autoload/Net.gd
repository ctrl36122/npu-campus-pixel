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

const ChatGuard := preload("res://net/chat_guard.gd")
## 系统提示用的「发言人」。客户端聊天面板见到它就渲染成灰色的系统行，
## 不去名单里找对应玩家、也不弹头顶气泡。
const SYS_SPEAKER := "[系统]"

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

# ---------------------------------------------------------------- 聊天内容管理
## 被禁言的 uid。用 uid 而不是昵称：昵称随时能改，uid 才是本机固定的身份。
var _muted: Dictionary = {}
## uid -> 上一条消息的 ticks（刷屏节流）
var _last_msg_ms: Dictionary = {}
## uid -> 上一条内容 / 连续重复次数（复读机拦截）
var _last_text: Dictionary = {}
var _last_text_n: Dictionary = {}
## 管理员 uid 白名单，来自环境变量 XGD_ADMIN（逗号分隔）
var _admin_uids: PackedStringArray = []
## XGD_ADMIN 没配时，第一个连上来的玩家兜底当管理员（小圈子共玩的默认约定）
var _fallback_admin_uid: String = ""
## 本地是否已被禁言。服务端下发 @MUTED 后置位，聊天框据此在发送前就拦住，
## 而不是「先显示成自己发出去了、其实别人收不到」。
var local_muted: bool = false


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
	_load_admin()
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
	# 没配 XGD_ADMIN 时，第一个进来的人自动成为管理员（小圈子共玩不需要额外配置）。
	if _admin_uids.is_empty() and _fallback_admin_uid.is_empty():
		_fallback_admin_uid = safe_uid
		print("[net] 未配置 XGD_ADMIN，%s 作为第一个玩家自动成为管理员" % safe_name)
	_publish_roster()
	_send_history_to(sender)          # 新来的人先看到刚才在聊什么
	_sync_claims.rpc_id(sender, room_claims)   # 以及现有的房间认领公告
	# 好友切片（谁是他的好友 / 谁在等他接受）—— 房间门禁要靠它判断能不能开门
	if not _social_loaded:
		_load_social()
	_ensure_social(safe_uid, safe_name)
	_push_social_to(sender)


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
	if OS.has_environment("XGD_DEBUG"):
		print("[net] post_message sender=%d registered=%s text=%s" % [
			sender, str(peers.has(sender)), text])
	if not peers.has(sender):
		return
	note_received([text])
	var speaker: String = str(peers[sender]["name"])
	var clean := text.left(160)

	# 以 / 开头的是管理命令：只交给服务端执行，绝不进公共聊天。
	# 客户端本地那一趟（call_local）直接返回，指令原文不会出现在自己的聊天框里。
	# 复用现有 RPC、不新增通道 —— 旧客户端连新服务端不会 checksum failed。
	if clean.begins_with("/"):
		if is_server():
			_handle_command(sender, clean)
		return

	# 违规词打码。客户端发送前已经过一遍同样的 filter（等长替换，幂等），
	# 这里再兜一次，防止有人绕开客户端直接 rpc 上来。
	var safe := ChatGuard.filter(clean)
	if safe != clean and is_server():
		_notice_to(sender, "消息里有不当用语，已用 * 代替")

	# 只有服务端落盘（客户端各有一份副本，写多了会互相覆盖）
	if is_server():
		if not _accept_message(sender, safe):
			return          # 被禁言 / 刷屏 / 复读，已经单独回执过了
		_record_chat(speaker, safe)
		# 关键：Godot 的 rpc() 从客户端只发到服务器，服务端**不会**自动转发给别人。
		# 以前少了这一步，客户端发的消息只有它自己和主机看得到 —— 别人那边聊天框
		# 一片空白（主机自己说的话却正常，因为主机 rpc() 直接发给所有客户端）。
		if sender != my_id():
			for id in multiplayer.get_peers():
				if int(id) != sender:
					_relay_message.rpc_id(int(id), speaker, safe)
	message_received.emit(speaker, safe)


## 服务端转发别人的聊天。客户端收到后走和本地一样的气泡 + 列表逻辑。
@rpc("authority", "call_remote", "reliable", 0)
func _relay_message(speaker: String, text: String) -> void:
	note_received([text])
	message_received.emit(speaker, text)


# ---------------------------------------------------------------- 聊天内容管理
## 管理员白名单来自环境变量 XGD_ADMIN（服务器上写进 systemd 的 Environment=）。
## 没配置就由第一个连上来的玩家兜底 —— 校园里自己开房那套本来就没服务器可配。
func _load_admin() -> void:
	_admin_uids = PackedStringArray()
	for part in OS.get_environment("XGD_ADMIN").split(",", false):
		var u := part.strip_edges()
		if not u.is_empty():
			_admin_uids.append(u)
	if not _admin_uids.is_empty():
		print("[net] 管理员 uid：", ", ".join(_admin_uids))


func _is_admin(uid: String) -> bool:
	if uid.is_empty():
		return false
	if _admin_uids.has(uid):
		return true
	if not _admin_uids.is_empty():
		return false
	if not _fallback_admin_uid.is_empty():
		return uid == _fallback_admin_uid
	# 还没有任何客户端连上来（单机预览 / 自己开房当主机）：主机本人就是管理员。
	# 不补这条的话，主机在单机模式下用不了任何管理命令 —— _register 只在
	# 客户端加入时触发，主机自己从不经过它。
	return is_server() and uid == local_uid


## 服务端：这条消息放不放行。不放行时已经给发送者回了提示。
func _accept_message(sender: int, text: String) -> bool:
	var uid := str(peers.get(sender, {}).get("uid", ""))
	if _muted.has(uid):
		_notice_to(sender, "@MUTED")        # 客户端收到后置 local_muted 并提示
		return false
	var now := Time.get_ticks_msec()
	if ChatGuard.too_fast(int(_last_msg_ms.get(uid, 0)), now):
		_notice_to(sender, "说慢一点，别刷屏")
		return false
	_last_msg_ms[uid] = now
	if str(_last_text.get(uid, "")) == text:
		var n := int(_last_text_n.get(uid, 0)) + 1
		_last_text_n[uid] = n
		if n >= ChatGuard.REPEAT_LIMIT:
			_last_text_n[uid] = 1
			_notice_to(sender, "同一句话别连着发")
			return false
	else:
		_last_text[uid] = text
		_last_text_n[uid] = 1
	return true


## 服务端：解析 / 开头的管理命令。/help 所有人可用，其余只有管理员。
func _handle_command(sender: int, raw: String) -> void:
	var parts := raw.strip_edges().split(" ", false)
	if parts.is_empty():
		return
	var cmd := str(parts[0]).to_lower()
	var arg := ""
	if parts.size() > 1:
		arg = " ".join(PackedStringArray(parts.slice(1))).strip_edges()
	var uid := str(peers.get(sender, {}).get("uid", ""))

	print("[net] 收到命令 %s（来自 %s / uid %s）" % [
		cmd, str(peers.get(sender, {}).get("name", "?")), uid])

	if cmd == "/help":
		_notice_to(sender, "好友：/friends 列表 · /friend 昵称 加好友 · /accept 昵称 · /deny 昵称 · /unfriend 昵称")
		_notice_to(sender, "管理员：/who 在线名单 · /mute 昵称 · /unmute 昵称 · /clear 清空聊天记录")
		return
	# 好友命令人人可用，必须在管理员检查之前分流
	if FRIEND_CMDS.has(cmd):
		_handle_friend_command(sender, cmd, arg)
		return
	if not _is_admin(uid):
		_notice_to(sender, "这条命令只有管理员能用。")
		return

	match cmd:
		"/who":
			var lines := PackedStringArray()
			for id in peers:
				lines.append("%s(uid %s)" % [
					str(peers[id].get("name", "?")), str(peers[id].get("uid", "?"))])
			_notice_to(sender, "在线 %d 人：%s" % [peers.size(), " · ".join(lines)])
		"/mute":
			var t1 := _find_peer_by_name(arg)
			if t1 <= 0:
				_notice_to(sender, "找不到这个昵称：%s" % arg)
				return
			_muted[str(peers[t1].get("uid", ""))] = true
			_mute_state_to(t1)
			print("[net] 禁言 %s" % str(peers[t1].get("name", "?")))
			_broadcast_notice("%s 已被禁言" % str(peers[t1].get("name", "?")))
		"/unmute":
			var t2 := _find_peer_by_name(arg)
			if t2 <= 0:
				_notice_to(sender, "找不到这个昵称：%s" % arg)
				return
			_muted.erase(str(peers[t2].get("uid", "")))
			_mute_state_to(t2)
			print("[net] 解除禁言 %s" % str(peers[t2].get("name", "?")))
			_broadcast_notice("%s 的禁言已解除" % str(peers[t2].get("name", "?")))
		"/clear":
			if not _chat_loaded:
				_load_chat_log()
			_chat_log.clear()
			_save_chat_log()
			print("[net] 聊天记录已清空（操作者 %s）" % str(peers.get(sender, {}).get("name", "?")))
			_broadcast_notice("@CLEAR")     # 客户端收到后清空自己的聊天面板
			_broadcast_notice("聊天记录已清空")
		_:
			_notice_to(sender, "没有这个命令：%s（/help 查看）" % cmd)


func _find_peer_by_name(name: String) -> int:
	var want := name.strip_edges()
	if want.is_empty():
		return 0
	for id in peers:
		if str(peers[id].get("name", "")) == want:
			return int(id)
	return 0


func _mute_state_to(peer: int) -> void:
	var uid := str(peers.get(peer, {}).get("uid", ""))
	_notice_to(peer, "@MUTED" if _muted.has(uid) else "@UNMUTED")


## 给某个人发一条系统提示。走现有的 _relay_message 通道，不新增 RPC。
func _notice_to(peer: int, msg: String) -> void:
	if peer <= 0:
		return
	if is_server() and peer == my_id():
		message_received.emit(SYS_SPEAKER, msg)
	else:
		_relay_message.rpc_id(peer, SYS_SPEAKER, msg)


## 服务端：给所有人发系统提示（本机玩家自己也要收到一份）
func _broadcast_notice(msg: String) -> void:
	if not is_server():
		return
	message_received.emit(SYS_SPEAKER, msg)
	for id in multiplayer.get_peers():
		_relay_message.rpc_id(int(id), SYS_SPEAKER, msg)


# ---------------------------------------------------------------- 好友系统
## 好友关系是**服务端权威**的社交图，按 uid 存（uid 是本机首次启动随机生成、
## 落在 user://xgd_uid.cfg 的那个 ID）。不能塞进 peers —— peers 是「这次联机
## 里在线的人」，人一下线就没了，而好友要跨会话记住，所以单独一张表 + 落盘。
##
## 四种状态：
##   "friend"  双向已成立
##   "out"     我发出的请求，等对方接受
##   "in"      对方发出的请求，等我接受
##   "blocked" 我拉黑了他
##
## 客户端只拿「以自己为中心」的切片（my_friends），全量 _social 只存在服务端。
signal social_changed
## other_uid -> {"name": String, "state": String}，只含与我相关的条目
var my_friends: Dictionary = {}
## 服务端专用的全量图：uid -> {"name": String, "friends": {other_uid: state}}
var _social: Dictionary = {}
var _social_loaded := false
const SOCIAL_PATH := "user://social.json"
const FRIEND_CMDS := ["/friend", "/accept", "/deny", "/unfriend", "/friends"]


## 好友状态查询。门禁判定（宿舍门）就靠它。
func friend_state(uid: String) -> String:
	if uid.is_empty():
		return ""
	return String((my_friends.get(uid, {}) as Dictionary).get("state", ""))


func is_friend(uid: String) -> bool:
	return friend_state(uid) == "friend"


## 待我接受的请求：[{"uid": String, "name": String}]，好友面板渲染用。
func friend_requests() -> Array:
	var out: Array = []
	for u in my_friends:
		if String((my_friends[u] as Dictionary).get("state", "")) == "in":
			out.append({
				"uid": String(u),
				"name": String((my_friends[u] as Dictionary).get("name", "?")),
			})
	out.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	return out


## 已是好友的列表（含离线）：[{"uid", "name"}]。
func friend_list() -> Array:
	var out: Array = []
	for u in my_friends:
		if String((my_friends[u] as Dictionary).get("state", "")) == "friend":
			out.append({
				"uid": String(u),
				"name": String((my_friends[u] as Dictionary).get("name", "?")),
			})
	out.sort_custom(func(a, b): return String(a["name"]) < String(b["name"]))
	return out


## 好友的 uid 集合 —— 门禁判定每帧都要问，别每次都建数组。
func friend_uids() -> Dictionary:
	var out: Dictionary = {}
	for u in my_friends:
		if String((my_friends[u] as Dictionary).get("state", "")) == "friend":
			out[String(u)] = true
	return out


# --- 客户端入口：一律走现有的 post_message 命令通道 --------------------------
## 为什么要绕命令通道而不是新 RPC：RPC 方法一改，旧客户端连新服务端就可能
## checksum failed，所有人必须同时升级。命令走 post_message、回执走
## _relay_message，都是老通道，旧客户端最多看不懂那几行提示。
func friend_request(target_uid: String) -> void:
	_friend_cmd("/friend", target_uid)


func friend_accept(target_uid: String) -> void:
	_friend_cmd("/accept", target_uid)


func friend_deny(target_uid: String) -> void:
	_friend_cmd("/deny", target_uid)


func friend_remove(target_uid: String) -> void:
	_friend_cmd("/unfriend", target_uid)


func friend_refresh() -> void:
	_friend_cmd("/friends", "")


func _friend_cmd(cmd: String, arg: String) -> void:
	if not has_session():
		message_received.emit(SYS_SPEAKER, "好友功能要联机才能用（单机模式没有别人）。")
		return
	var line := cmd if arg.is_empty() else "%s %s" % [cmd, arg]
	post_message.rpc(line)


# --- 服务端：解析命令 -------------------------------------------------------
func _handle_friend_command(sender: int, cmd: String, arg: String) -> void:
	var actor_uid := str(peers.get(sender, {}).get("uid", ""))
	var actor_name := str(peers.get(sender, {}).get("name", "?"))
	if actor_uid.is_empty():
		return
	if not _social_loaded:
		_load_social()
	_ensure_social(actor_uid, actor_name)      # 顺手把昵称刷新到表里

	if cmd == "/friends":
		_notice_to(sender, _friend_summary(actor_uid))
		return

	var target := _resolve_uid(arg)
	if target.is_empty():
		_notice_to(sender, "找不到这个人：%s（可以输昵称，也可以输 uid）" % arg)
		return
	if target == actor_uid:
		_notice_to(sender, "不能对自己做这个操作。")
		return
	_ensure_social(target, "")

	match cmd:
		"/friend":
			_notice_to(sender, _friend_request(actor_uid, actor_name, target, sender))
		"/accept":
			_notice_to(sender, _friend_accept(actor_uid, target))
		"/deny":
			_notice_to(sender, _friend_drop(actor_uid, target, "已拒绝 %s 的好友请求。" % _social_name(target)))
		"/unfriend":
			_notice_to(sender, _friend_drop(actor_uid, target, "已和 %s 解除好友关系。" % _social_name(target)))


## 返回提示文本；顺手把该推的都推出去。
func _friend_request(actor_uid: String, actor_name: String, target: String, sender: int) -> String:
	var a: Dictionary = _social[actor_uid]["friends"]
	var b: Dictionary = _social[target]["friends"]
	var st_a := String(a.get(target, ""))
	var st_b := String(b.get(actor_uid, ""))
	if st_a == "friend":
		return "你们已经是好友了。"
	# 对方也正等着我接受 → 直接成了，省一次来回（两个人都点了「加好友」的场景）
	if st_b == "in":
		a[target] = "friend"
		b[actor_uid] = "friend"
		_save_social()
		_push_social_both(actor_uid, target)
		_notice_to(sender, "你和 %s 成为好友了。" % _social_name(target))
		_notify_uid(target, "%s 通过了你的好友请求，现在是好友了。" % actor_name)
		return ""
	if st_a == "out":
		return "你已经发过请求了，等 %s 回应。" % _social_name(target)
	a[target] = "out"
	b[actor_uid] = "in"
	_save_social()
	_push_social_both(actor_uid, target)
	_notify_uid(target, "@FRIENDREQ|%s|%s" % [actor_uid, actor_name])
	print("[net] 好友请求 %s -> %s" % [actor_name, _social_name(target)])
	return "好友请求已发给 %s，等对方接受。" % _social_name(target)


func _friend_accept(actor_uid: String, target: String) -> String:
	var a: Dictionary = _social[actor_uid]["friends"]
	var b: Dictionary = _social[target]["friends"]
	if String(a.get(target, "")) != "in":
		return "%s 没给你发过好友请求。" % _social_name(target)
	a[target] = "friend"
	b[actor_uid] = "friend"
	_save_social()
	_push_social_both(actor_uid, target)
	_notify_uid(target, "%s 通过了你的好友请求，现在是好友了。" % _social_name(actor_uid))
	return "已和 %s 成为好友。" % _social_name(target)


## 拒绝请求 / 删除好友：两边条目一起清掉（单向残留会让对方一直挂着「已发送」）。
func _friend_drop(actor_uid: String, target: String, ok_msg: String) -> String:
	var a: Dictionary = _social[actor_uid]["friends"]
	var b: Dictionary = _social[target]["friends"]
	if not a.has(target) and not b.has(actor_uid):
		return "你们本来就不是好友。"
	a.erase(target)
	b.erase(actor_uid)
	_save_social()
	_push_social_both(actor_uid, target)
	return ok_msg


# --- 服务端：社交图维护 -----------------------------------------------------
func _ensure_social(uid: String, nm: String) -> Dictionary:
	if uid.is_empty():
		return {}
	# 主机（listen server）自己不在 peers 里 —— 它从不经过 _register，
	# 名字只能从 local_name 补。不补的话，别人看到的房主名是空串。
	var use := nm
	if use.is_empty() and uid == local_uid:
		use = local_name
	if not _social.has(uid):
		_social[uid] = {"name": use, "friends": {}}
	elif not use.is_empty() and String(_social[uid].get("name", "")) != use:
		_social[uid]["name"] = use    # 改过昵称的人，下次连上来就同步过去
	return _social[uid]


func _social_name(uid: String) -> String:
	var nm := String((_social.get(uid, {}) as Dictionary).get("name", ""))
	if not nm.is_empty():
		return nm
	if uid == local_uid and is_server():
		return local_name              # 同上：主机自己在 _social 里可能还没名字
	# 表里没名字就看看在不在线
	for id in peers:
		if str(peers[id].get("uid", "")) == uid:
			return str(peers[id].get("name", "?"))
	return uid


## 昵称或 uid → uid。先精确 uid，再在线昵称，最后离线好友的昵称。
func _resolve_uid(arg: String) -> String:
	var a := arg.strip_edges()
	if a.is_empty():
		return ""
	if _social.has(a):
		return a
	for id in peers:
		if str(peers[id].get("name", "")) == a:
			return str(peers[id].get("uid", ""))
	for u in _social:
		if String((_social[u] as Dictionary).get("name", "")) == a:
			return String(u)
	return ""


func _friend_summary(uid: String) -> String:
	var fs: Dictionary = _social.get(uid, {}).get("friends", {})
	if fs.is_empty():
		return "还没有好友。走到同学旁边按 E，或在聊天框输入 /friend 昵称。"
	var ok := PackedStringArray()
	var wait_in := PackedStringArray()
	var wait_out := PackedStringArray()
	for o in fs:
		var st := String(fs[o])
		var nm := _social_name(String(o))
		var online := _uid_online(String(o))
		match st:
			"friend":
				ok.append("%s%s" % [nm, "" if online else "（离线）"])
			"in":
				wait_in.append(nm)
			"out":
				wait_out.append(nm)
	var parts := PackedStringArray()
	parts.append("好友 %d 人：%s" % [ok.size(), "、".join(ok) if ok.size() > 0 else "无"])
	if wait_in.size() > 0:
		parts.append("待你接受：%s（/accept 昵称）" % "、".join(wait_in))
	if wait_out.size() > 0:
		parts.append("等待对方接受：%s" % "、".join(wait_out))
	return " · ".join(parts)


func _uid_online(uid: String) -> bool:
	for id in peers:
		if str(peers[id].get("uid", "")) == uid:
			return true
	return false


## 给某个 uid 发系统提示（在线才发得出，离线就当没发生 —— 好友请求本身已经
## 存在表里，他下次上线拉 /friends 就能看到）。
func _notify_uid(uid: String, msg: String) -> void:
	for id in peers:
		if str(peers[id].get("uid", "")) == uid:
			_notice_to(int(id), msg)
			return


func _push_social_both(a: String, b: String) -> void:
	_push_social_to_uid(a)
	_push_social_to_uid(b)


func _push_social_to_uid(uid: String) -> void:
	for id in peers:
		if str(peers[id].get("uid", "")) == uid:
			_push_social_to(int(id))
			return


func _push_social_to(peer: int) -> void:
	if not is_server() or peer <= 0:
		return
	var uid := str(peers.get(peer, {}).get("uid", ""))
	if uid.is_empty():
		return
	if peer == my_id():
		_apply_social(_social_slice(uid))
	else:
		_sync_social.rpc_id(peer, _social_slice(uid))


## 某人的朋友圈切片：[other_uid: {"name", "state"}]
func _social_slice(uid: String) -> Dictionary:
	var out: Dictionary = {}
	var fs: Dictionary = _social.get(uid, {}).get("friends", {})
	for o in fs:
		out[String(o)] = {
			"name": _social_name(String(o)),
			"state": String(fs[o]),
		}
	return out


@rpc("authority", "call_remote", "reliable", 1)
func _sync_social(snapshot: Dictionary) -> void:
	_apply_social(snapshot)


func _apply_social(snapshot: Dictionary) -> void:
	my_friends = snapshot.duplicate(true)
	social_changed.emit()


# --- 好友落盘（服务端） -----------------------------------------------------
func _load_social() -> void:
	_social_loaded = true
	if not is_server():
		return                        # 客户端不落这张表，等 _sync_social 下发
	if not FileAccess.file_exists(SOCIAL_PATH):
		return
	var f := FileAccess.open(SOCIAL_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_social = parsed
		print("[net] 好友表已载入：%d 个 uid" % _social.size())


func _save_social() -> void:
	if not is_server():
		return
	var f := FileAccess.open(SOCIAL_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[net] 好友表写不进去：%s" % SOCIAL_PATH)
		return
	f.store_string(JSON.stringify(_social))
	f.close()


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
## 本机自己那间房的本地镜像（含公告正文）：{"floor", "index", "name", "note"}。
## 用途是「退出重进还在」——服务端只把认领存在内存里，重启就没了；旧版服务端
## 更是直接丢掉认领请求。本地存一份，进游戏先贴回去，服务端认下来之后以它为准。
var my_room_cache: Dictionary = {}
## 刚主动退掉的房间 "楼层:房号"。服务器快照里可能还留着它（旧版服务端不认退房请求），
## 记下来别再把那间当成「我的房间」，否则退房后又会被存档写回去。
var void_claim: String = ""


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
		if uid == local_uid:
			my_room_cache = {}
			void_claim = key              # 别让服务器的旧快照把它当成我的房
	else:
		# 退掉同一 uid 名下的其它房间（「每个人只能同时占有一个房间」）
		for k in room_claims.keys():
			if String(k) == key:
				continue
			if String(Dictionary(room_claims[k]).get("uid", "")) == uid:
				room_claims.erase(k)
		room_claims[key] = {"name": nm, "uid": uid}
		if uid == local_uid:
			# 记进本地镜像（公告正文跟着走），退出重进还能贴回来
			my_room_cache = {
				"floor": n, "index": r, "name": nm,
				"note": String(my_room_cache.get("note", "")),
			}
			void_claim = ""
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


## 本机认领的房间 "楼层:房号"（没认领则空），用来决定「这次从哪儿出生」。
## 本地镜像里那间优先：旧版服务端不认认领请求，它的快照里可能还留着我以前的房间，
## 按插入顺序取第一个匹配 uid 的 key 会取到旧房 —— 存档和出生点就退回上一间了。
func my_claim() -> String:
	if not my_room_cache.is_empty():
		var k := "%d:%d" % [int(my_room_cache.get("floor", 0)), int(my_room_cache.get("index", -1))]
		if String(Dictionary(room_claims.get(k, {})).get("uid", "")) == local_uid:
			return k
	if not void_claim.is_empty():
		if String(Dictionary(room_claims.get(void_claim, {})).get("uid", "")) == local_uid:
			return ""            # 我刚退掉、服务器还没清掉：就当没认领
		void_claim = ""          # 服务器那边已经没了，标记作废
	return claim_of_uid(local_uid)


@rpc("authority", "call_remote", "reliable", 0)
func _sync_claims(snapshot: Dictionary) -> void:
	room_claims = snapshot.duplicate(true)
	_restore_cached_claim()
	room_claims_changed.emit()


## 用本地镜像兜底：服务端快照里没有「我的房间」时把它补回去。
## 旧版服务端根本不认认领请求，每收到一次快照就会把本地刚贴的公告冲掉 ——
## 补回来之后，牌子/公告正文至少在本机是对的。房间被别人占了则以服务端为准。
func _restore_cached_claim() -> void:
	# 主动退掉的房不该再从服务器旧快照里冒出来（门牌上会挂着我的名字）
	if not void_claim.is_empty() and String(Dictionary(room_claims.get(void_claim, {})).get("uid", "")) == local_uid:
		room_claims.erase(void_claim)
	if my_room_cache.is_empty() or local_uid.is_empty():
		return
	var key := "%d:%d" % [int(my_room_cache.get("floor", 0)), int(my_room_cache.get("index", -1))]
	var cur: Dictionary = room_claims.get(key, {})
	var owner := String(cur.get("uid", ""))
	if not owner.is_empty() and owner != local_uid:
		my_room_cache = {}                 # 被别人占了：本地这份作废
		return
	if cur.is_empty():
		room_claims[key] = {"name": String(my_room_cache.get("name", local_name)), "uid": local_uid}
	var note := String(my_room_cache.get("note", ""))
	if not note.is_empty():
		room_claims[key]["note"] = note
	# 一人一间：服务器的旧快照里可能还留着我以前占的房间（旧版服务端不认新请求），
	# 不清掉的话门牌上会同时挂着我两个名字，my_claim 也可能取到旧的那间。
	for k in room_claims.keys():
		if String(k) == key:
			continue
		if String(Dictionary(room_claims[k]).get("uid", "")) == local_uid:
			room_claims.erase(k)


## 启动时把本地存档里那间房灌进 Net（还没连上服务器也能显示自己的牌子/公告）
## ⚠️ 只在内容真的变了才走一遍恢复+广播：调用链是
## _save_my_room → set_cached_room → room_claims_changed → _refresh_door_plates
## → _remember_my_home → _save_my_room …，不挡住就是无限递归（踩过栈溢出）。
func set_cached_room(floor_n: int, idx: int, name: String, note: String) -> void:
	if floor_n < 1 or idx < 0:
		return
	var clean := _clean_note(note)
	var same: bool = int(my_room_cache.get("floor", 0)) == floor_n \
		and int(my_room_cache.get("index", -1)) == idx \
		and String(my_room_cache.get("note", "")) == clean
	my_room_cache = {"floor": floor_n, "index": idx, "name": name, "note": clean}
	if same:
		return
	_restore_cached_claim()
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
	if uid == local_uid and not my_room_cache.is_empty():
		my_room_cache["note"] = note        # 本地镜像同步更新，退出重进还能读回来
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
