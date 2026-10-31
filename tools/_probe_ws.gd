extends SceneTree
# 联机服务端健康探针：走真实 WebSocket 握手，确认 Caddy 反代 + Godot WS 服务端都通。
# 用法：godot --headless --path . --script res://tools/_probe_ws.gd

func _init() -> void:
	var url := OS.get_environment("XGD_PROBE_URL")
	if url.is_empty():
		url = "ws://<你的服务器IP>/ws"
	print("PROBE URL ", url)
	var ws := WebSocketPeer.new()
	var err := ws.connect_to_url(url)
	if err != OK:
		print("PROBE CONNECT_ERR ", err)
		quit(1)
		return
	var deadline := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		ws.poll()
		var st := ws.get_ready_state()
		if st == WebSocketPeer.STATE_OPEN:
			print("PROBE OPEN ok")
			# 再等一次 poll，看服务端是否主动下发首包（欢迎/快照）
			OS.delay_msec(600)
			ws.poll()
			print("PROBE PKTS ", ws.get_available_packet_count())
			quit(0)
			return
		if st == WebSocketPeer.STATE_CLOSED:
			print("PROBE CLOSED code=", ws.get_close_code(), " reason=", ws.get_close_reason())
			quit(2)
			return
		OS.delay_msec(50)
	print("PROBE TIMEOUT state=", ws.get_ready_state())
	quit(3)
