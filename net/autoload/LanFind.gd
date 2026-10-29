extends Node
## 局域网自动发现 —— 让「打开游戏就在线」不需要任何人手填 IP。
##
## 协议（UDP 7655，与游戏端口 7654 分开）：
##   客户端 → 主机   "XGD?REQ"
##   主机 → 客户端   "XGD!OK|<游戏端口>|<主机昵称>"
##
## 端口分配的关键：主机 bind 固定的 7655 当应答器，客户端 bind 系统分配的随机端口去探测。
## 如果两边都 bind 7655，同机双开会抢端口、第二个进程直接失败。
##
## 探测目标一次发多个：127.0.0.1（同机）、受限广播、每个本机网段的 /24 广播、以及本机 IP 单播。
## 只发广播不够稳——Windows 防火墙和不少路由器会拦 UDP 广播，单播兜底。

const DISCOVER_PORT: int = 7655
const REQ := "XGD?REQ"
const RES_PREFIX := "XGD!OK"

var _responder: PacketPeerUDP = null
var _resp_port: int = 7654
var _resp_name: String = ""

var _prober: PacketPeerUDP = null
var _probe_left: float = 0.0
var _found_ip: String = ""
var _found_port: int = 7654
var _found_name: String = ""


func _process(delta: float) -> void:
	_poll_responder()
	if _prober != null:
		_poll_prober()
		_probe_left -= delta
		if _probe_left <= 0.0:
			_stop_prober()


func _exit_tree() -> void:
	stop_responder()
	_stop_prober()


# ---------------------------------------------------------------- 主机侧：应答
## 开始在本机宣告「我是主机」。必须在 host_game() 成功后调用。
func start_responder(enet_port: int, host_name: String) -> void:
	stop_responder()
	var s := PacketPeerUDP.new()
	var err: int = s.bind(DISCOVER_PORT, "*")
	if err != OK:
		# 端口被占（另一个实例已经在当主机）——不致命，只是别人发现不了我
		push_warning("[LanFind] 无法监听 UDP %d（错误 %d），局域网自动发现不可用" % [DISCOVER_PORT, err])
		return
	_responder = s
	_resp_port = enet_port
	_resp_name = host_name


func stop_responder() -> void:
	if _responder != null:
		_responder.close()
	_responder = null


func _poll_responder() -> void:
	if _responder == null:
		return
	while _responder.get_available_packet_count() > 0:
		var pkt: PackedByteArray = _responder.get_packet()
		if pkt.get_string_from_utf8() != REQ:
			continue
		var ip: String = _responder.get_packet_ip()
		var port: int = _responder.get_packet_port()
		if ip.is_empty() or port <= 0:
			continue
		_responder.set_dest_address(ip, port)
		var body := "%s|%d|%s" % [RES_PREFIX, _resp_port, _resp_name]
		_responder.put_packet(body.to_utf8_buffer())


# ---------------------------------------------------------------- 客户端侧：探测
## 发出一次探测，最多等 timeout 秒。结果用 found_ip() / found_port() 取。
func probe(timeout: float = 1.4) -> void:
	_stop_prober()
	var p := PacketPeerUDP.new()
	var ok := false
	if p.bind(0, "*") == OK:
		ok = true
	else:
		for _i in 12:
			if p.bind(20000 + randi() % 20000, "*") == OK:
				ok = true
				break
	if not ok:
		push_warning("[LanFind] 无法分配探测端口，局域网自动发现不可用")
		return
	p.set_broadcast_enabled(true)
	_prober = p
	_found_ip = ""
	_probe_left = timeout
	for addr in _targets():
		p.set_dest_address(addr, DISCOVER_PORT)
		p.put_packet(REQ.to_utf8_buffer())


func has_result() -> bool:
	return not _found_ip.is_empty()


func found_ip() -> String:
	return _found_ip


func found_port() -> int:
	return _found_port


func found_name() -> String:
	return _found_name


func _poll_prober() -> void:
	while _prober.get_available_packet_count() > 0:
		var txt: String = _prober.get_packet().get_string_from_utf8()
		var parts: PackedStringArray = txt.split("|")
		if parts.size() < 2 or parts[0] != RES_PREFIX:
			continue
		var ip: String = _prober.get_packet_ip()
		if ip.is_empty():
			continue
		_found_ip = ip
		_found_port = int(parts[1])
		_found_name = parts[2] if parts.size() > 2 else ""
		_probe_left = 0.0
		return


func _stop_prober() -> void:
	if _prober != null:
		_prober.close()
	_prober = null
	_probe_left = 0.0


## 一次探测覆盖这些地址：同机回环 + 受限广播 + 各网段 /24 广播 + 本机 IP 单播
func _targets() -> Array[String]:
	var out: Array[String] = ["127.0.0.1", "255.255.255.255"]
	for a in IP.get_local_addresses():
		if a.count(".") != 3:
			continue                       # 跳过 IPv6
		if a.begins_with("127.") or a.begins_with("169.254."):
			continue                       # 跳过回环与自动私有地址
		var seg: PackedStringArray = a.split(".")
		var bcast := "%s.%s.%s.255" % [seg[0], seg[1], seg[2]]
		if not out.has(bcast):
			out.append(bcast)
		if not out.has(a):
			out.append(a)
	return out
