extends Node
## Loads the shared world and runs rounds.
##
## The world stays loaded for the whole connection. Rounds change GameState's
## phase and clear the world's objects instead of swapping scenes, so the
## MultiplayerSpawner and synchronizer paths every client relies on never move.
##
## The join handshake avoids the classic race where the server spawns a player
## before the client has loaded the scene to put it in: every replicated node is
## invisible to a peer until that peer says "my world is ready".
var world: Node2D
var world_ready: Dictionary = {}
var _opening: bool = false

func _ready() -> void:
	Net.session_ready.connect(_open_world)
	Net.session_closed.connect(_close_world)
	Net.peer_leaving.connect(_peer_leaving)
	GameState.phase_changed.connect(_phase_changed)

func _open_world() -> void:
	if _opening or is_instance_valid(world):
		return
	_opening = true
	world = preload("res://net/scenes/Arena.tscn").instantiate()
	world.name = "World"
	add_child(world)
	await get_tree().process_frame
	_opening = false
	if not Net.has_session() or not is_instance_valid(world):
		return
	if Net.is_server():
		_accept_world_ready(1)
	else:
		_ready_for_world.rpc_id(1, Net.session_id)

@rpc("any_peer", "call_remote", "reliable", 0)
## Sent by a client once its world scene exists. Only then does the server make
## replicated nodes visible to it.
func _ready_for_world(session: String) -> void:
	if Net.is_server() and session == Net.session_id:
		_accept_world_ready(multiplayer.get_remote_sender_id())

func _accept_world_ready(id: int) -> void:
	if id != 1 and not Net.peers.has(id):
		return
	if not is_instance_valid(world):
		return
	world_ready[id] = true
	world.allow_peer(id)
	# 常驻在线：第一个人的世界就绪后立刻把世界切到「游戏中」。
	# 之后每个人接入都直接掉进世界里，不再需要准备 / 开始按钮。
	if Net.is_server() and GameState.phase != GameState.Phase.IN_RUN:
		if not GameState.begin_run():
			GameState.phase = GameState.Phase.IN_RUN
	if GameState.phase == GameState.Phase.IN_RUN and Net.peers.has(id):
		# 延后到空闲帧再生成：spawn_avatar 里要做物理点查询挑空地，
		# 直接在 RPC 回调里查会撞上物理刷写（和传送是同一类问题）。
		world.call_deferred("spawn_avatar", id)

## Called by every spawned node with a synchronizer: show it to every peer whose
## world is ready. public_visibility is false in every spawned scene.
func configure_sync(sync: MultiplayerSynchronizer) -> void:
	if Net.is_server():
		for id in world_ready:
			if id == 1 or multiplayer.get_peers().has(id):
				sync.set_visibility_for(id, true)

func _peer_leaving(id: int) -> void:
	world_ready.erase(id)
	if is_instance_valid(world):
		world.remove_player(id)

func _close_world(_reason: String) -> void:
	world_ready.clear()
	_opening = false
	if is_instance_valid(world):
		remove_child(world)
		world.queue_free()
	world = null
	GameState.reset_session()

## Server only: start a round once every player is ready.
func start_run() -> void:
	if not Net.can_start() or not is_instance_valid(world):
		return
	world.clear_run()
	GameState.begin_run()
	for id in Net.peers:
		world.call_deferred("spawn_avatar", id)
	Net.reset_readiness()

func _phase_changed(phase: int) -> void:
	if phase != GameState.Phase.ENDED or not Net.is_server():
		return
	var session: String = Net.session_id
	await get_tree().create_timer(3.0).timeout
	if not Net.is_server() or Net.session_id != session:
		return
	world.clear_run()
	GameState.return_to_lobby()
	Net.reset_readiness()
