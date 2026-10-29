extends Node
## 联机大厅（最小版）：昵称 + 外观 + 开房/加入 + 准备/开始
##
## 命令行参数（方便双开与自动化测试）：
##   --host            自动开房
##   --join=127.0.0.1  自动加入
##   --name=某某       昵称
##   --hero=lucy       外观
##   --auto            自动准备 / 主机自动开始回合
##   --quiet           不打印心跳（默认每 2 秒打印一行 [NET]）

const HeroDB := preload("res://scripts/sandbox/hero_db.gd")

var _name_edit: LineEdit
var _ip_edit: LineEdit
var _status: Label
var _ready_btn: Button
var _start_btn: Button
var _local_ready: bool = false
var _hero: String = "adam"
var _auto: bool = false
var _quiet: bool = false
var _walk: bool = false
var _walk_t: float = 0.0
var _beat: float = 0.0
var _tries: float = 0.0
var _cards: Array[Control] = []


func _ready() -> void:
	_build_ui()
	Net.session_ready.connect(_on_session_ready)
	Net.session_closed.connect(_on_closed)
	Net.roster_changed.connect(_refresh)
	_parse_args()
	_refresh()


# ---------------------------------------------------------------- 命令行
func _parse_args() -> void:
	# 先收集全部参数再动作：否则 --host 出现在 --name 之前会用到默认昵称
	var want_host := false
	var join_addr := ""
	for a in OS.get_cmdline_user_args():
		if a == "--host":
			want_host = true
		elif a.begins_with("--join="):
			join_addr = a.substr(7)
		elif a.begins_with("--name="):
			var nm := a.substr(7)
			_name_edit.text = nm
			Net.local_name = nm
		elif a.begins_with("--hero="):
			_set_hero(a.substr(7))
		elif a == "--auto":
			_auto = true
		elif a == "--quiet":
			_quiet = true
		elif a == "--walk":
			_walk = true
	if want_host:
		_do_host()
	elif join_addr != "":
		if Net.local_name == "" or Net.local_name == "Player":
			Net.local_name = "Guest"
			_name_edit.text = "Guest"
		var err: int = Net.join_game(join_addr)
		_set_status("正在连接 %s …（%d）" % [join_addr, err])


# ---------------------------------------------------------------- 界面
func _build_ui() -> void:
	var f := GameTheme.font()

	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	panel.offset_left = 16.0
	panel.offset_top = 16.0
	panel.custom_minimum_size = Vector2(330, 0)
	layer.add_child(panel)

	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		pad.add_theme_constant_override(m, 14)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	pad.add_child(col)

	var title := Label.new()
	title.text = "像素工大 · 联机"
	title.add_theme_font_override("font", f)
	title.add_theme_font_size_override("font_size", 17)
	col.add_child(title)

	# 昵称
	var r1 := HBoxContainer.new()
	col.add_child(r1)
	_name_edit = LineEdit.new()
	_name_edit.text = "玩家"
	_name_edit.max_length = 12
	_name_edit.custom_minimum_size = Vector2(180, 30)
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.add_theme_font_override("font", f)
	r1.add_child(_name_edit)

	# 外观
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 6)
	col.add_child(r2)
	for i in HeroDB.HEROES.size():
		var hero = HeroDB.HEROES[i]
		var b := Button.new()
		b.flat = true
		b.custom_minimum_size = Vector2(48, 64)
		b.icon = _portrait(str(hero["sheet"]))
		b.expand_icon = true
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_set_hero.bind(str(hero["id"])))
		r2.add_child(b)
		_cards.append(b)

	# 开房 / 加入
	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 6)
	col.add_child(r3)
	var host_btn := Button.new()
	host_btn.text = "开房间"
	host_btn.custom_minimum_size = Vector2(90, 30)
	host_btn.add_theme_font_override("font", f)
	host_btn.pressed.connect(_do_host)
	r3.add_child(host_btn)

	_ip_edit = LineEdit.new()
	_ip_edit.text = "127.0.0.1"
	_ip_edit.custom_minimum_size = Vector2(110, 30)
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r3.add_child(_ip_edit)

	var join_btn := Button.new()
	join_btn.text = "加入"
	join_btn.custom_minimum_size = Vector2(64, 30)
	join_btn.add_theme_font_override("font", f)
	join_btn.pressed.connect(_do_join)
	r3.add_child(join_btn)

	# 准备 / 开始
	var r4 := HBoxContainer.new()
	r4.add_theme_constant_override("separation", 6)
	col.add_child(r4)
	_ready_btn = Button.new()
	_ready_btn.text = "准备"
	_ready_btn.custom_minimum_size = Vector2(90, 30)
	_ready_btn.add_theme_font_override("font", f)
	_ready_btn.pressed.connect(_toggle_ready)
	r4.add_child(_ready_btn)

	_start_btn = Button.new()
	_start_btn.text = "开始游戏"
	_start_btn.custom_minimum_size = Vector2(100, 30)
	_start_btn.add_theme_font_override("font", f)
	_start_btn.pressed.connect(_start)
	r4.add_child(_start_btn)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(300, 0)
	_status.add_theme_font_override("font", f)
	_status.add_theme_font_size_override("font_size", 13)
	col.add_child(_status)

	_set_hero("adam")


func _portrait(sheet_path: String) -> AtlasTexture:
	var at := AtlasTexture.new()
	at.atlas = load(sheet_path)
	at.region = Rect2(HeroDB.PORTRAIT_FRAME * HeroDB.FRAME_W, 0, HeroDB.FRAME_W, HeroDB.FRAME_H)
	at.filter_clip = true
	return at


# ---------------------------------------------------------------- 操作
func _do_host() -> void:
	Net.local_name = _name_edit.text.strip_edges() if _name_edit != null else "Host"
	if Net.local_name == "":
		Net.local_name = "Host"
	Net.local_hero = _hero
	var err: int = Net.host_game()
	_set_status("开房结果：%d（端口 %d）" % [err, 7654])


func _do_join() -> void:
	Net.local_name = _name_edit.text.strip_edges()
	if Net.local_name == "":
		Net.local_name = "Guest"
	Net.local_hero = _hero
	var err: int = Net.join_game(_ip_edit.text.strip_edges())
	_set_status("加入结果：%d" % err)


func _set_hero(id: String) -> void:
	_hero = id
	Net.local_hero = id
	for i in _cards.size():
		var on: bool = str(HeroDB.HEROES[i]["id"]) == id
		_cards[i].modulate = Color(1, 1, 1, 1) if on else Color(0.5, 0.55, 0.5, 1)


func _toggle_ready() -> void:
	_local_ready = not _local_ready
	Net.set_ready(_local_ready)
	_ready_btn.text = "取消准备" if _local_ready else "准备"
	_refresh()


func _start() -> void:
	SessionFlow.start_run()


func _set_status(t: String) -> void:
	if _status != null:
		_status.text = t


# ---------------------------------------------------------------- 事件
func _on_session_ready() -> void:
	_set_status("已连接 · 我是 %d" % Net.my_id())
	_refresh()


func _on_closed(reason: String) -> void:
	_set_status("连接已关闭：%s" % reason)


func _refresh() -> void:
	if _status == null:
		return
	var names: Array[String] = []
	for id in Net.peers:
		var e: Dictionary = Net.peers[id]
		names.append("%s%s" % [e.get("name", "?"), "✓" if e.get("ready", false) else ""])
	if Net.has_session():
		_start_btn.visible = Net.is_server()
		var ph := "大厅"
		if GameState.phase == GameState.Phase.IN_RUN:
			ph = "游戏中"
		elif GameState.phase == GameState.Phase.ENDED:
			ph = "本回合结束"
		_set_status("我是 %d · %s · %s\n在线：%s" % [Net.my_id(),
			"主机" if Net.is_server() else "客户端", ph,
			", ".join(names) if names.size() > 0 else "（空）"])
	else:
		_start_btn.visible = false


func _drive_walk(delta: float) -> void:
	if not _walk or GameState.phase != GameState.Phase.IN_RUN:
		return
	_walk_t += delta
	for p in get_tree().get_nodes_in_group("players"):
		if not p.is_local_player:
			continue
		p.input.bot_driven = true
		p.input.bot_move = Vector2.RIGHT if _walk_t < 3.0 else Vector2.ZERO


func _process(delta: float) -> void:
	_drive_walk(delta)
	if _auto and Net.has_session():
		_tries += delta
		if _tries > 0.5:
			_tries = 0.0
			if not _local_ready:
				_toggle_ready()
			if Net.is_server() and Net.can_start() and GameState.phase == GameState.Phase.LOBBY:
				SessionFlow.start_run()
	if _quiet:
		return
	_beat += delta
	if _beat >= 2.0:
		_beat = 0.0
		var avatars: int = get_tree().get_nodes_in_group("players").size()
		var pos := Vector2.ZERO
		var parts: Array[String] = []
		for p in get_tree().get_nodes_in_group("players"):
			if p.is_local_player:
				pos = p.position
			parts.append("%s@%d,%d%s" % [p.name, int(p.position.x), int(p.position.y),
				"*" if p.is_local_player else ""])
		print("[NET] id=%d peers=%d phase=%d avatars=%d self=(%d,%d) av[%s]" % [
			Net.my_id(), Net.peer_count(), GameState.phase, avatars,
			int(pos.x), int(pos.y), " ".join(parts)])
