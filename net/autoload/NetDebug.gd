extends Node
## Testing tools: the F3 network inspector, and the F4 lag dial that delays or
## drops application messages (chat, emotes, input batches). It can also start
## enabled from the command line: --lag=MS --jitter=MS --loss=PERCENT.
## These are application-message estimates, not ENet packets or total bandwidth.
var overlay: CanvasLayer
var sent_messages: int = 0
var received_messages: int = 0
var sent_payload_bytes: int = 0
var received_payload_bytes: int = 0
var payload_bytes_per_second: float = 0.0
var _window: float = 0.0
var _previous_bytes: int = 0
var enabled: bool = false
var latency_ms: float = 0.0
var jitter_ms: float = 0.0
var loss_chance: float = 0.0
var reconciliations: int = 0
var last_correction: float = 0.0

func _ready() -> void:
	overlay = preload("res://net/scenes/DebugOverlay.tscn").instantiate()
	add_child(overlay)
	for arg in OS.get_cmdline_args() + OS.get_cmdline_user_args():
		if arg.begins_with("--lag="):
			latency_ms = clampf(float(arg.substr(6)), 0.0, 1000.0)
			enabled = true
		elif arg.begins_with("--jitter="):
			jitter_ms = clampf(float(arg.substr(9)), 0.0, 400.0)
			enabled = true
		elif arg.begins_with("--loss="):
			loss_chance = clampf(float(arg.substr(7)) / 100.0, 0.0, 1.0)
			enabled = true

func _process(delta: float) -> void:
	_window += delta
	if _window >= 1.0:
		payload_bytes_per_second = float(sent_payload_bytes - _previous_bytes) / _window
		_previous_bytes = sent_payload_bytes
		_window = 0.0

func rtt_ms(id: int) -> int:
	if not Net.has_session() or id == Net.my_id() or not multiplayer.get_peers().has(id):
		return -1
	if not multiplayer.multiplayer_peer is ENetMultiplayerPeer:
		return -1
	if not Net.is_server() and id != 1:
		return -1
	var enet: ENetMultiplayerPeer = multiplayer.multiplayer_peer
	var peer: ENetPacketPeer = enet.get_peer(id)
	return int(peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)) if peer != null else -1

func send(args: Array, handler: Callable) -> void:
	if enabled and randf() < loss_chance:
		return
	sent_messages += 1
	sent_payload_bytes += var_to_bytes(args).size()
	var delay_ms: float = maxf(0.0, latency_ms + randf_range(-jitter_ms, jitter_ms)) if enabled else 0.0
	if delay_ms == 0.0:
		handler.call(args)
	else:
		get_tree().create_timer(delay_ms / 1000.0).timeout.connect(func(): handler.call(args))
