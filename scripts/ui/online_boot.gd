extends Node
## 在线入口 —— 打开游戏直接进校园，没有菜单、没有大厅、不用点开始。
##
## 启动顺序（全自动，失败自动降级）：
##   1. 上次连成功过的地址 → 直接连（换了 WiFi 也能命中自己宿舍那台）
##   2. 局域网 UDP 探测 → 同 WiFi 下谁先开游戏谁就是主机，后来者自动加入
##   3. 都没有 → 自己开房当主机，并把应答器打开让别人能发现我
##
## 进世界后：GameState 常驻 IN_RUN（不倒计时），任何人进来立刻出现在地图上，
## 头顶带昵称。按 Tab 打开设置（昵称 / 外观 / 手动地址）。

const PROFILE_PATH := "user://xgd_profile.cfg"
const GAME_PORT: int = 7654
## 默认联机服务器地址：仓库里不带地址，由配置提供（见 default_server()）。
const SERVER_CFG := "res://assets/server.json"
const SERVER_CFG_LOCAL := "res://assets/server.local.json"
const MinimapScript := preload("res://scripts/ui/minimap.gd")
const WorldMapScript := preload("res://scripts/ui/world_map.gd")
const ChatScript := preload("res://scripts/ui/chat.gd")
const TouchPadScript := preload("res://scripts/ui/touch_pad.gd")
const ConsentScript := preload("res://scripts/ui/consent.gd")

## 小地图尺寸（保持 424:800 的校园比例）。200 宽在 1080p 下足够看清街区。
const MINI_W: float = 200.0
const MINI_H: float = 377.0
const MINI_PAD: float = 10.0
const MINI_HEAD: float = 26.0
## 右上角在线名单最多列几行（人多时其余收成「另 N 人」，避免压到小地图）
const ROSTER_MAX_LINES: int = 5

var _nick: String = ""
var _hero: String = "adam"
var _last_addr: String = ""

var _booting: bool = true
var _online: bool = false
var _dbg_t: float = 0.0

var _font: SystemFont
var _ui_layer: CanvasLayer
var _card: Control
var _card_title: Label
var _card_sub: Label
var _hud: Control
var _roster: Label
var _settings: Control
var _nick_edit: LineEdit
var _addr_edit: LineEdit
var _net_info: Label
var _hero_btns: Array[Button] = []
var _mini: Control
## 当前世界（Arena），进/出房间时要把小地图切成房间的
var _arena: Node
var _mini_title: Label
var _mini_panel: Control
var _touch_pad: Control
## 小地图实际尺寸（手机上会缩小，见 _ready）
var _mini_w: float = MINI_W
var _mini_h: float = MINI_H
## 校园模式下的面板宽度：横屏 200，竖屏 132。从房间回来时按它复位。
var _base_mini_w: float = MINI_W
var _map: Control
var _chat: Node
var _clock: Label
## 首次启动的说明页（免责声明 / 隐私 / 聊天规则），点过之后就没了
var _consent: Node


## 触屏设备（Android/iOS 包，或 XGD_TOUCH=1 在桌面模拟）
func is_touch_ui() -> bool:
	return OS.has_feature("mobile") or OS.has_environment("XGD_TOUCH")


## 竖屏模式：手机包，或桌面用 XGD_PORTRAIT=1 预览
func is_portrait_ui() -> bool:
	return OS.has_feature("mobile") or OS.has_environment("XGD_PORTRAIT")


func _ready() -> void:
	add_to_group("boot_ui")
	_load_profile()
	if is_portrait_ui():
		# 校园本身南北长（212×400 格），竖屏反而更合身：同样的 13px 字号在 720 宽的
		# 基准里占比是横屏的 1.8 倍，UI 不用重排（现有尺寸都是按屏宽比例定的）。
		var w := get_window()
		w.content_scale_size = Vector2i(720, 1280)
		w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	if is_touch_ui():
		# 手机屏小：小地图缩到 140 宽（保持 424:800 比例），不然右上角占掉半屏
		_mini_w = 132.0
		_mini_h = 132.0 * MINI_H / MINI_W
		_base_mini_w = 132.0
	# 专用服务器（--server）：没有窗口也没有 UI，直接开房等别人连进来。
	# 世界由 SessionFlow 在 session_ready 里建，所以这里什么都不用画。
	if Net.is_dedicated:
		Net.local_name = _nick if not _nick.is_empty() else "校园服务器"
		Net.local_hero = _hero
		if Net.host_game(GAME_PORT) != OK:
			print("[boot] 服务端启动失败：", Net.last_error)
			get_tree().quit(1)
		return
	_build_ui()
	_build_chat()
	_add_consent()
	# 手机：左下摇杆 + 右下按钮（自己要处理多点触摸，所以是独立 Control）
	if is_touch_ui():
		# 必须放独立 CanvasLayer：直接挂在 online_boot 下会落到 layer 0（世界层），
		# 被 UI 和地图整片压住，而且会跟着相机变换跑掉。
		var tl := CanvasLayer.new()
		tl.name = "TouchLayer"
		tl.layer = 11
		add_child(tl)
		_touch_pad = TouchPadScript.new()
		_touch_pad.set("boot", self)
		tl.add_child(_touch_pad)
	Net.session_ready.connect(_on_session_ready)
	Net.session_closed.connect(_on_session_closed)
	Net.roster_changed.connect(_refresh_roster)
	Net.info_changed.connect(_refresh_net_info)
	call_deferred("_boot")
	# 验证用：设了 XGD_VERIFY 时，进世界约 5s 后把主视口存成 res://shot_verify.png，
	# 即使 AI 插件在 play 启动掉线也能留下画面供人工核对（验证后移除）。
	if OS.has_environment("XGD_VERIFY"):
		var vt := get_tree().create_timer(5.0)
		vt.timeout.connect(_verify_shot)
	# 调试用：XGD_CHAT_TAP=1 自动点一下右下「聊」按钮（核对大聊天窗）
	if OS.has_environment("XGD_CHAT_TAP") and is_instance_valid(_touch_pad):
		var ct := get_tree().create_timer(4.0)
		ct.timeout.connect(func(): _touch_pad.call("_fire", "chat"))
	# 调试用：XGD_MAP_TOGGLE=1 八秒后再点一次「图」按钮（核对能否关闭）
	if OS.has_environment("XGD_MAP_TOGGLE") and is_instance_valid(_touch_pad):
		var mg := get_tree().create_timer(8.0)
		mg.timeout.connect(func():
			print("[map] 点前 visible=", _map != null and _map.visible,
				" hide_buttons=", _touch_pad.get("hide_buttons"))
			_touch_pad.call("_fire", "map")
			print("[map] 点后 visible=", _map != null and _map.visible))
	# 调试用：XGD_MAP=1 自动打开全屏地图（核对触摸缩放/拖动）
	if OS.has_environment("XGD_MAP"):
		var dt := get_tree().create_timer(4.0)
		dt.timeout.connect(func(): _open_map())
	# 调试用：XGD_SEND_MSG=<文本> 时，进世界 6 秒后自动广播一条聊天（验证联机/落盘）
	if OS.has_environment("XGD_SEND_MSG"):
		var mt := get_tree().create_timer(6.0)
		mt.timeout.connect(func(): Net.post_message.rpc(OS.get_environment("XGD_SEND_MSG")))
	# 调试用：XGD_SETTINGS=1 时自动弹出设置面板（核对「联机地址」那栏）
	if OS.has_environment("XGD_SETTINGS"):
		var st := get_tree().create_timer(3.0)
		st.timeout.connect(func(): _toggle_settings(true))


func _verify_shot() -> void:
	var vp := get_viewport()
	var tex := vp.get_texture()
	if tex != null:
		var img := tex.get_image()
		if img != null:
			img.save_png("res://shot_verify.png")
			print("[verify] 已保存 res://shot_verify.png")


## 聊天层自己管输入框和气泡，这里只负责实例化（它自己连 Net.message_received）
func _build_chat() -> void:
	_chat = ChatScript.new()
	_chat.name = "Chat"
	add_child(_chat)


## 首次启动的说明页。先拿一个临时实例问「要不要弹」（它 _ready 里会自己 queue_free），
## 需要弹才真正挂上去 —— 否则每局游戏都会白建一次全屏遮罩。
func _add_consent() -> void:
	var probe: Node = ConsentScript.new()
	var need: bool = bool(probe.call("should_show"))
	probe.free()
	if not need:
		return
	_consent = ConsentScript.new()
	add_child(_consent)
	_set_local_blocked(true)                      # 弹窗期间别让人物跟着 WASD 乱跑
	_consent.connect("accepted", func() -> void: _set_local_blocked(false))


# ---------------------------------------------------------------- 启动流程
## 默认服务器地址。仓库里不带地址，按优先级取：
##   1) res://assets/server.local.json —— 本机私有配置（已 gitignore，构建时会打进包里）
##   2) 环境变量 XGD_SERVER            —— 桌面调试临时指定
##   3) res://assets/server.json       —— 仓库里的空模板
## 三者都没有就返回空串：桌面端走局域网自动发现 / 自己当主机，手机端提示未配置。
func default_server() -> String:
	for path in [SERVER_CFG_LOCAL, SERVER_CFG]:
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var data = JSON.parse_string(f.get_as_text())
		if data is Dictionary and data.has("url"):
			var url := str(data["url"]).strip_edges()
			if not url.is_empty():
				return url
	var env := OS.get_environment("XGD_SERVER").strip_edges()
	return env


func _boot() -> void:
	_card_title.text = "正在进入校园…"
	_card_sub.text = ""
	_card.visible = true

	# 网页版：浏览器连不了 UDP，只能连 WebSocket 服务器。
	# 默认连「和网页同一个域名」的 /ws（服务端和网页都放同一台机器、同一个域名下），
	# 也可以用 ?server=wss://xxx/ws 指定别的服务器。连不上就退回单机，别让人卡在启动页。
	if OS.has_feature("web"):
		var url := _web_server_url()
		if not url.is_empty():
			_card_sub.text = "正在连接 %s" % url
			print("[boot] 网页版：尝试连接 ", url)
			if await _try_join(url, 3.0):
				return
		print("[boot] 网页版：服务器没响应，退回单机模式")
		_become_host()
		return

	# 手机：只当客户端。连不上就重试 + 说清原因，绝不自己开房
	# （Android 上 ENet 服务端容易起不来，报了「无法开启校园 UDP」更让人困惑）
	if OS.has_feature("mobile"):
		var srv := default_server()
		if srv.is_empty():
			_booting = false
			_card_title.text = "还没有配置服务器"
			_card_sub.text = "这个安装包里没有内置联机地址。\n可以在「设」里手动填 ws:// 或 wss:// 地址后重连。"
			print("[boot] 手机端：未配置默认服务器")
			return
		for attempt in 3:
			_card_title.text = "正在连接服务器…"
			_card_sub.text = "第 %d 次尝试 %s" % [attempt + 1, srv]
			if await _try_join(srv, 4.0):
				return
		_booting = false
		_card_title.text = "连不上服务器"
		_card_sub.text = "请检查手机是否能上网；校园网可能限制了外网访问。\n可在「设」里手动改服务器地址后重试。"
		print("[boot] 手机端三次都没连上服务器")
		return

	# 桌面上的单机预览（XGD_OFFLINE=1，用来预演网页行为）
	if Net.is_offline():
		print("[boot] 网页/单机模式：跳过联机，直接进入校园")
		_become_host()
		return

	# 1) 上次连过的地址；没有就用内置的官方服务器（这样谁都不用填 IP）
	var first := _last_addr
	if first.is_empty():
		first = default_server()
	_card_sub.text = "正在连接 %s" % first
	if await _try_join(first, 3.0):
		return
	if _last_addr.is_empty():
		print("[boot] 官方服务器没连上，继续找局域网")

	# 2) 局域网搜索（同 WiFi 下同学的房间）
	_card_title.text = "正在搜索附近的校园…"
	_card_sub.text = "同一网络下有人开游戏就能自动加入"
	LanFind.probe(1.6)
	await get_tree().create_timer(1.7).timeout
	if LanFind.has_result():
		print("[boot] 局域网发现主机 %s（%s）" % [LanFind.found_name(), LanFind.found_ip()])
		_card_sub.text = "发现 %s，正在加入…" % LanFind.found_name()
		if await _try_join(LanFind.found_ip(), 2.5):
			return

	# 3) 自己当主机
	_card_title.text = "正在开启校园…"
	if not _last_addr.is_empty():
		_card_sub.text = "连不上 %s（对方没开端口映射 / 不在同一网络），已在本机开房" % _last_addr
	else:
		_card_sub.text = ""
	_become_host()


## 网页版要连的服务器：?server=wss://xxx/ws 优先，否则用当前页面的域名（同域部署）。
## https 页面只允许 wss（混合内容拦截），本地 http 预览时才用 ws。
func _web_server_url() -> String:
	if not OS.has_feature("web"):
		return ""
	var q := str(JavaScriptBridge.eval(
		"(function(){try{var s=new URLSearchParams(location.search).get('server');return s?s:''}catch(e){return ''}})()"))
	if q.begins_with("ws://") or q.begins_with("wss://"):
		return q
	var host := str(JavaScriptBridge.eval("location.host"))
	if host.is_empty():
		return ""
	var is_https := str(JavaScriptBridge.eval("location.protocol")).begins_with("https")
	return "%s://%s/ws" % ["wss" if is_https else "ws", host]


## 解析「主机[:端口]」。支持：
##   1.2.3.4           → 默认端口
##   1.2.3.4:7654      → 指定端口
##   game.example.com  → 域名（frp / 隧道场景）
##   [::1]:7654        → 带方括号的 IPv6
##   ws://… / wss://…  → 整串交给 WebSocket
func _split_addr(addr: String) -> Dictionary:
	var a := addr.strip_edges()
	if a.begins_with("ws://") or a.begins_with("wss://"):
		return {"host": a, "port": GAME_PORT}
	if a.begins_with("["):
		var end := a.find("]")
		if end > 0:
			var port := GAME_PORT
			if a.length() > end + 1 and a[end + 1] == ":":
				port = int(a.substr(end + 2))
			return {"host": a.substr(1, end - 1), "port": port}
	# 裸 IPv6（冒号很多）不切；IPv4/域名只有一个冒号时才当「主机:端口」
	if a.count(":") == 1:
		return {"host": a.get_slice(":", 0), "port": int(a.get_slice(":", 1))}
	return {"host": a, "port": GAME_PORT}


## 尝试连接，成功返回 true。超时或断开返回 false（内部已清理连接）。
func _try_join(addr: String, timeout: float) -> bool:
	Net.local_name = _nick
	Net.local_hero = _hero
	var target := _split_addr(addr)
	if Net.join_game(str(target["host"]), int(target["port"])) != OK:
		return false
	var waited: float = 0.0
	while waited < timeout:
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
		if Net.has_session() and Net.peers.has(Net.my_id()):
			_save_profile(addr)
			print("[boot] 已加入 %s，我是 %d" % [addr, Net.my_id()])
			return true
		if not Net.has_session() and not Net.is_connecting():
			break                                # 被拒 / 立刻断开，别空等
	Net.leave_game("")
	return false


func _become_host() -> void:
	Net.local_name = _nick
	Net.local_hero = _hero
	var err: int = Net.host_game(GAME_PORT, Net.MAX_PLAYERS, true)
	if err != OK:
		_booting = false
		_card_title.text = "无法开启校园"
		_card_sub.text = Net.last_error
		return
	# 让别人能在局域网里发现我（网页版没有 UDP，跳过）
	if not Net.is_offline():
		LanFind.start_responder(GAME_PORT, _nick)
	_save_profile("")
	print("[boot] 我是主机（%s），等同学加入" % _nick)


# ---------------------------------------------------------------- 会话事件
func _on_session_ready() -> void:
	_booting = false
	_online = true
	_card.visible = false
	_hud.visible = true
	_refresh_roster()
	_wait_world()
	# 玩家节点是进世界之后才生成的，_add_consent 那次 block 时它还不存在 ——
	# 说明页没关就再挡一次，否则弹窗期间人物会跟着键盘跑。
	if _consent != null and is_instance_valid(_consent) and bool(_consent.call("should_show")):
		_set_local_blocked(true)


## 世界（Arena）是 SessionFlow 在同一个信号里创建的，谁先谁后不确定，
## 所以这里轮询等它就绪，再挂小地图/全屏地图。
func _wait_world() -> void:
	for _i in 160:
		await get_tree().create_timer(0.05).timeout
		if not _online:
			return
		var w = SessionFlow.world
		if w != null and is_instance_valid(w) and w.get("minimap_tex") != null:
			_build_map_ui(w)
			return


func _on_session_closed(reason: String) -> void:
	if _booting:
		return                                   # 启动阶段的失败由 _boot 自己重试
	_online = false
	LanFind.stop_responder()
	_hud.visible = false
	_free_map_ui()
	_card.visible = true
	_card_title.text = "已断开连接"
	_card_sub.text = reason if not reason.is_empty() else "主机可能退出了游戏"
	_settings.visible = false
	_set_local_blocked(false)
	await get_tree().create_timer(1.2).timeout
	if _online:
		return
	_boot()                                      # 自动重新找房间


## 排错用：设了环境变量 XGD_DEBUG=1 时定期打印在线状态（正常玩不会有输出）
func _process(delta: float) -> void:
	if _clock != null and is_instance_valid(_clock):
		# DayNight 是 autoload，直接按名字访问（get_singleton 查不到 autoload）
		if true:  # DayNight 是 autoload，直接按名字访问
			_clock.text = "%s  %s" % [DayNight.time_string(), DayNight.phase_name()]
	if not OS.has_environment("XGD_DEBUG"):
		return
	_dbg_t += delta
	if _dbg_t < 2.0:
		return
	_dbg_t = 0.0
	var names: PackedStringArray = []
	var avatars: int = 0
	for p in get_tree().get_nodes_in_group("players"):
		avatars += 1
		names.append("%s@%d,%d%s" % [p.name, int(p.position.x), int(p.position.y),
			"*" if p.is_local_player else ""])
	print("[dbg] online=%s id=%d peers=%d avatars=%d phase=%d %s" % [
		str(_online), Net.my_id(), Net.peer_count(), avatars, GameState.phase, " ".join(names)])


# ---------------------------------------------------------------- 界面
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	_ui_layer = layer
	# 全局字体：挂在根窗口上，名牌 / NPC 名 / 所有面板统一继承
	_font = GameTheme.font()
	GameTheme.apply_root_theme(get_tree().root)

	# ---- 启动 / 断线提示卡（居中）----
	var card_wrap := CenterContainer.new()
	card_wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	card_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(card_wrap)

	_card = PanelContainer.new()
	_card.add_theme_stylebox_override("panel", _box("#0f141a", "#25313d", 10))
	_card.custom_minimum_size = Vector2(430, 0)
	_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_wrap.add_child(_card)

	var pad := MarginContainer.new()
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 22)
	_card.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(col)

	_card_title = _label("正在进入校园…", GameTheme.FS_TITLE, "#e8eef2", true)
	_card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_card_title)

	_card_sub = _label("", 13, "#7f8f9c")
	_card_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_sub.custom_minimum_size = Vector2(380, 0)
	col.add_child(_card_sub)

	# ---- 右上角：在线名单 ----
	_hud = PanelContainer.new()
	_hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_hud.offset_left = -196.0
	_hud.offset_top = 12.0
	_hud.offset_right = -12.0
	_hud.offset_bottom = 12.0
	_hud.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_hud.add_theme_stylebox_override("panel", _box("#0d1218b8", "#2a3845", 6))
	# 纯展示面板，鼠标事件全部穿透，否则鼠标停在名单上滚轮就缩不了镜头
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.visible = false
	layer.add_child(_hud)

	var hud_pad := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		hud_pad.add_theme_constant_override(m, 10)
	for m in ["margin_top", "margin_bottom"]:
		hud_pad.add_theme_constant_override(m, 7)
	_hud.add_child(hud_pad)

	_roster = _label("", 12, "#cfd9e2")
	_roster.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_roster.custom_minimum_size = Vector2(160, 0)
	hud_pad.add_child(_roster)

	# ---- 左下角：操作提示（带半透明底，压在楼上也看得清）----
	var hint_wrap := PanelContainer.new()
	hint_wrap.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	hint_wrap.offset_left = 12.0
	hint_wrap.offset_top = -38.0
	hint_wrap.offset_right = 412.0
	hint_wrap.offset_bottom = -10.0
	hint_wrap.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hint_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_wrap.add_theme_stylebox_override("panel", _box("#0d1218a8", "#26313c", 5))
	layer.add_child(hint_wrap)

	var hint_text := "WASD 移动 · Shift 加速 · 回车聊天 · 滚轮缩放 · M 地图 · Tab 设置"
	if is_touch_ui():
		hint_text = "左摇杆走路（推到底＝跑）· 右下：聊 / 图 / 设"
	var hint := _label(hint_text, 11, "#9fb0bd")
	if is_touch_ui():
		hint_wrap.visible = false        # 手机上底部让给摇杆，提示没地方放也没必要
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint_wrap.add_child(hint)

	# ---- 顶部中央：时钟 + 昼夜阶段（昼夜系统 DayNight 每帧填）----
	var clock_panel := PanelContainer.new()
	clock_panel.name = "ClockPanel"
	clock_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	clock_panel.custom_minimum_size = Vector2(156, 30)
	clock_panel.add_theme_stylebox_override("panel", _box("#0d1418b8", "#2a3845", 6))
	clock_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(clock_panel)

	_clock = _label("06:00  清晨", 13, "#e8eef2", true)
	_clock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clock_panel.add_child(_clock)

	_build_settings(layer)


func _build_settings(layer: CanvasLayer) -> void:
	var wrap := CenterContainer.new()
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 这个全屏容器只是用来把设置面板居中的，必须 IGNORE。
	# 默认是 STOP，会在聊天框（layer 9）上面铺一层看不见的墙，把所有 GUI 点击吃掉 ——
	# 表现就是「聊天框怎么点都没反应」，而自绘的触屏按钮（走 _input，绕开 GUI）却是好的。
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(wrap)

	_settings = PanelContainer.new()
	_settings.add_theme_stylebox_override("panel", _box("#0f141a", "#31414f", 10))
	_settings.custom_minimum_size = Vector2(400, 0)
	_settings.visible = false
	wrap.add_child(_settings)

	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 18)
	_settings.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	pad.add_child(col)

	col.add_child(_label("设置", GameTheme.FS_TITLE, "#e8eef2", true))

	# 昵称
	col.add_child(_label("昵称", 12, "#8a99a6"))
	var nr := HBoxContainer.new()
	nr.add_theme_constant_override("separation", 8)
	col.add_child(nr)

	_nick_edit = LineEdit.new()
	_nick_edit.max_length = 12
	_nick_edit.custom_minimum_size = Vector2(0, 30)
	_nick_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nick_edit.add_theme_font_override("font", _font)
	_nick_edit.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	nr.add_child(_nick_edit)

	var save_btn := _button("保存", 70)
	save_btn.pressed.connect(_apply_nick)
	nr.add_child(save_btn)

	# 外观
	col.add_child(_label("外观", 12, "#8a99a6"))
	var hr := HBoxContainer.new()
	hr.add_theme_constant_override("separation", 6)
	col.add_child(hr)
	var HeroDB := preload("res://scripts/sandbox/hero_db.gd")
	for i in HeroDB.HEROES.size():
		var hero: Dictionary = HeroDB.HEROES[i]
		var b := Button.new()
		b.flat = true
		b.custom_minimum_size = Vector2(52, 70)
		b.icon = _portrait(str(hero["sheet"]))
		b.expand_icon = true
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(_apply_hero.bind(str(hero["id"])))
		hr.add_child(b)
		_hero_btns.append(b)

	# 联机信息：当主机时，这里显示「同一 WiFi 填什么 / 异地填什么」，点复制直接发给同学
	col.add_child(_label("联机地址", 12, "#8a99a6"))
	var ir := HBoxContainer.new()
	ir.add_theme_constant_override("separation", 8)
	col.add_child(ir)
	_net_info = _label("", GameTheme.FS_SMALL, "#9fb0bd")
	_net_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_net_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ir.add_child(_net_info)
	var cp_btn := _button("复制", 60)
	cp_btn.pressed.connect(_copy_net_info)
	ir.add_child(cp_btn)

	# 玩家 ID：本地固定，不会被别人占用，方便报给别人 / 以后做存档用
	col.add_child(_label("我的 ID：%s" % Net.local_uid, GameTheme.FS_SMALL, "#6f8494"))

	# 手动地址
	col.add_child(_label("服务器地址（留空则自动搜索）", 12, "#8a99a6"))
	var ar := HBoxContainer.new()
	ar.add_theme_constant_override("separation", 8)
	col.add_child(ar)

	_addr_edit = LineEdit.new()
	_addr_edit.placeholder_text = "例如 192.168.1.20"
	_addr_edit.custom_minimum_size = Vector2(0, 30)
	_addr_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_addr_edit.add_theme_font_override("font", _font)
	_addr_edit.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	ar.add_child(_addr_edit)

	var re_btn := _button("重连", 70)
	re_btn.pressed.connect(_reconnect)
	ar.add_child(re_btn)

	var close_btn := _button("返回游戏", 0)
	close_btn.pressed.connect(func(): _toggle_settings(false))
	col.add_child(close_btn)

	col.add_child(_label("Tab 或 Esc 关闭", GameTheme.FS_SMALL, "#5f6f7c"))


func _label(text: String, size: int, color: String, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	if bold:
		l.add_theme_font_override("font", GameTheme.font_bold())
	else:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(color))
	return l


func _button(text: String, width: int) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	if width > 0:
		b.custom_minimum_size = Vector2(width, 30)
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	b.add_theme_color_override("font_color", Color("#dce6ee"))
	b.add_theme_color_override("font_hover_color", Color("#ffffff"))
	b.add_theme_stylebox_override("normal", _box("#1b2330", "#2f3d4d", 4))
	b.add_theme_stylebox_override("hover", _box("#25313f", "#4a86c8", 4))
	b.add_theme_stylebox_override("pressed", _box("#16202b", "#3d6d9e", 4))
	return b


func _box(bg: String, border: String, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg)
	sb.border_color = Color(border)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 6.0
	sb.content_margin_bottom = 6.0
	return sb


func _portrait(sheet_path: String) -> AtlasTexture:
	var HeroDB := preload("res://scripts/sandbox/hero_db.gd")
	var at := AtlasTexture.new()
	at.atlas = load(sheet_path)
	at.region = Rect2(HeroDB.PORTRAIT_FRAME * HeroDB.FRAME_W, 0, HeroDB.FRAME_W, HeroDB.FRAME_H)
	at.filter_clip = true
	return at


# ---------------------------------------------------------------- 名单
func _refresh_roster() -> void:
	if _roster == null:
		return
	var ids: Array = Net.peers.keys()
	ids.sort()
	var lines: PackedStringArray = []
	for id in ids:
		var entry: Dictionary = Net.peers[id]
		var tag := ""
		if int(id) == 1:
			tag = " ·主机"
		if int(id) == Net.my_id():
			tag += " ·我"
		lines.append("· %s%s" % [str(entry.get("name", "?")), tag])
	if lines.is_empty():
		lines.append("· 连接中…")
	# 人多时名单会顶到小地图上：只列前几个人，其余用「另 N 人」收口。
	if lines.size() > ROSTER_MAX_LINES:
		var extra: int = lines.size() - ROSTER_MAX_LINES
		lines = lines.slice(0, ROSTER_MAX_LINES)
		lines.append("…另 %d 人" % extra)
	_roster.text = "在线 %d/%d\n%s" % [ids.size(), Net.MAX_PLAYERS, "\n".join(lines)]


# ---------------------------------------------------------------- 小地图 / 全屏地图
## 对应网页版的功能：右上角小地图（带视野框和楼名缩略）、点击展开全屏图、
## 在全屏图上点任意位置传送。传送请求交给 Arena，由服务器校验落点后放人。
func _build_map_ui(arena: Node) -> void:
	if _mini != null and is_instance_valid(_mini):
		return
	var tex: Texture2D = arena.minimap_tex
	var camp: Node2D = arena.campus
	if tex == null or camp == null:
		return

	# ---- 小地图面板：圆角 + 外投影 + 标题栏，正式 UI 的观感 ----
	var panel_w: float = _mini_w + MINI_PAD * 2.0
	var panel_h: float = _mini_h + MINI_PAD * 2.0 + MINI_HEAD + 6.0

	_mini_panel = PanelContainer.new()
	_mini_panel.name = "MinimapPanel"
	_mini_panel.anchor_left = 1.0
	_mini_panel.anchor_right = 1.0
	_mini_panel.offset_left = -12.0 - panel_w
	_mini_panel.offset_right = -12.0
	_mini_panel.offset_top = 118.0
	_mini_panel.offset_bottom = 118.0 + panel_h
	_mini_panel.mouse_filter = Control.MOUSE_FILTER_PASS
	_mini_panel.add_theme_stylebox_override("panel", _map_panel_box())
	_ui_layer.add_child(_mini_panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mini_panel.add_child(vb)

	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(head)

	_mini_title = _label("校园地图", 13, "#dbe6f0", true)
	_mini_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mini_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(_mini_title)

	var compass := _label("N", 12, "#e2b45c", true)
	compass.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(compass)

	_mini = Control.new()
	_mini.name = "Minimap"
	_mini.set_script(MinimapScript)
	_mini.custom_minimum_size = Vector2(_mini_w, _mini_h)
	_mini.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mini.mouse_filter = Control.MOUSE_FILTER_PASS
	vb.add_child(_mini)
	_mini.call("setup", tex, camp, _font)
	_mini.connect("pressed_open", _open_map)

	# 进/出建筑内景时把右上角那块换成房间平面图（房间是横的，面板高度要跟着改）
	_arena = arena
	if arena.has_signal("room_changed"):
		arena.room_changed.connect(_on_room_changed)

	_map = Control.new()
	_map.name = "WorldMap"
	_map.set_script(WorldMapScript)
	_map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map.visible = false
	_ui_layer.add_child(_map)
	_map.call("setup", tex, camp, arena, _font)
	_map.connect("closed", _close_map)


## 地图面板的样式：深色圆角底板 + 2px 冷色描边 + 硬投影。
func _map_panel_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#0d141c")
	sb.border_color = Color("#3a4c5e")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = MINI_PAD
	sb.content_margin_right = MINI_PAD
	sb.content_margin_top = MINI_PAD
	sb.content_margin_bottom = MINI_PAD
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 10
	sb.shadow_offset = Vector2(0, 4)
	return sb


## 房间 / 校园 切换小地图。房间比校园小得多，整间一次铺满，
## 另外房间是横的（910×754），面板按它的比例重新定高，不然会被压扁。
func _on_room_changed(inside: bool) -> void:
	if _mini == null or not is_instance_valid(_mini) or _arena == null:
		return
	if inside:
		var rm: Node = _arena.get("room")
		if rm == null or not is_instance_valid(rm):
			return
		var tex: Texture2D = rm.get("minimap_tex")
		var sz: Vector2 = rm.get("size_px")
		if tex == null or sz.y < 1.0:
			return
		_mini.call("set_room", tex, rm.position, sz)
		if _mini_title != null and is_instance_valid(_mini_title):
			_mini_title.text = String(rm.get("data").get("name", "内景"))
		_resize_mini(_mini_w, _mini_w * sz.y / sz.x)
		# 全屏地图同步切到房间视图（点小图/M 展开时就不会再显示校园）
		if _map != null and is_instance_valid(_map) and _map.has_method("set_room"):
			_map.call("set_room", rm)
	else:
		_mini.call("clear_room")
		if _mini_title != null and is_instance_valid(_mini_title):
			_mini_title.text = "校园地图"
		_resize_mini(_base_mini_w, _base_mini_w * MINI_H / MINI_W)
		if _map != null and is_instance_valid(_map) and _map.has_method("clear_room"):
			_map.call("clear_room")


## 现在是否在建筑内景里（右上角小图 / 全屏地图都已切到房间视图）
func _in_room() -> bool:
	return _arena != null and is_instance_valid(_arena) and bool(_arena.get("in_room"))


func _resize_mini(w: float, h: float) -> void:
	if w < 40.0 or h < 40.0:
		return
	_mini_w = w
	_mini_h = h
	if _mini != null and is_instance_valid(_mini):
		_mini.custom_minimum_size = Vector2(w, h)
		_mini.size = Vector2(w, h)
	if _mini_panel != null and is_instance_valid(_mini_panel):
		var panel_w: float = w + MINI_PAD * 2.0
		var panel_h: float = h + MINI_PAD * 2.0 + MINI_HEAD + 6.0
		_mini_panel.offset_left = -12.0 - panel_w
		_mini_panel.offset_right = -12.0
		_mini_panel.offset_bottom = _mini_panel.offset_top + panel_h


func _free_map_ui() -> void:
	if _mini_panel != null and is_instance_valid(_mini_panel):
		_mini_panel.queue_free()
	_mini_panel = null
	_mini = null
	if _map != null and is_instance_valid(_map):
		_map.queue_free()
	_map = null


## ---- 触屏按钮的入口（touch_pad.gd 调用）----
func touch_open_chat() -> void:
	if is_instance_valid(_chat) and _chat.has_method("open_typing"):
		_chat.call("open_typing")


func touch_toggle_map() -> void:
	if _map != null and is_instance_valid(_map) and _map.visible:
		_close_map()
	else:
		_open_map()


func touch_open_settings() -> void:
	_toggle_settings(true)


## 全屏浮层（校园地图 / 大聊天窗）打开时把 HUD 让开：
## 顶部状态条、时钟、小地图都被压在下面，叠着看很乱，先藏起来。
func set_overlay(v: bool) -> void:
	if _hud != null and is_instance_valid(_hud):
		_hud.visible = not v
	if _mini_panel != null and is_instance_valid(_mini_panel):
		_mini_panel.visible = not v
	if _clock != null and is_instance_valid(_clock):
		_clock.visible = not v


func _open_map() -> void:
	if _map == null or not is_instance_valid(_map):
		return
	_map.visible = true
	set_overlay(true)
	# 地图自带「✕ 关闭」，右下三个按钮在图上纯属干扰，先收起来；
	# 触摸也要交出去，否则点地图下半部分会启动摇杆、人在图后面走动
	if is_instance_valid(_touch_pad):
		_touch_pad.call("set_buttons_hidden_for", "map", true)
		if _touch_pad.has_method("set_touch_grabbed_for"):
			_touch_pad.call("set_touch_grabbed_for", "map", true)
	# 打开时按「当前是否在内景」校准全屏地图是房间视图还是校园视图，
	# 不依赖进/出房信号是否及时触发——否则会出现「在房间里点开地图却是校园图、
	# 点一下还把人传到校园、相机卡在房间边界外直接卡死」的情况。
	if _arena != null and is_instance_valid(_arena) and bool(_arena.get("in_room")):
		var rm: Node = _arena.get("room")
		if rm != null and is_instance_valid(rm):
			_map.call("set_room", rm)          # 内部已 reset_view
		else:
			_map.call("reset_view")
	else:
		_map.call("clear_room")                # 内部已 reset_view（仅房间模式时）
		_map.call("reset_view")
	_set_local_blocked(true)


func _close_map() -> void:
	if _map != null and is_instance_valid(_map):
		_map.visible = false
	set_overlay(false)
	if is_instance_valid(_touch_pad):
		_touch_pad.call("set_buttons_hidden_for", "map", false)
		if _touch_pad.has_method("set_touch_grabbed_for"):
			_touch_pad.call("set_touch_grabbed_for", "map", false)
	_set_local_blocked(false)


# ---------------------------------------------------------------- 设置交互
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = event.keycode
	if key == KEY_TAB:
		_toggle_settings(not _settings.visible)
		get_viewport().set_input_as_handled()
	elif key == KEY_M and _online:
		# M 打开全屏地图：在校园里是整张校园；进房间后全屏地图已切到
		# 房间平面图（见 _on_room_changed），所以房间内 M 同样能开、看到的是房间。
		if _map != null and is_instance_valid(_map) and _map.visible:
			_close_map()
		else:
			_open_map()
		get_viewport().set_input_as_handled()
	elif key == KEY_ESCAPE and _map != null and is_instance_valid(_map) and _map.visible:
		_close_map()
		get_viewport().set_input_as_handled()
	elif key == KEY_ESCAPE and _settings.visible:
		_toggle_settings(false)
		get_viewport().set_input_as_handled()


func _toggle_settings(open: bool) -> void:
	if _settings == null:
		return
	_settings.visible = open
	_set_local_blocked(open)
	if is_instance_valid(_chat):
		_chat.call("set_hidden", open)
	if open:
		_nick_edit.text = _nick
		_addr_edit.text = _last_addr
		_refresh_hero_highlights()
		_refresh_net_info()
		# 不自动聚焦输入框：否则 Tab 会被 LineEdit 吃掉，关不掉面板


## 刷新「联机地址」那一栏（打开设置面板时、以及 UPnP 探测出结果后）
func _refresh_net_info() -> void:
	if _net_info != null:
		_net_info.text = Net.net_info_text()


## 把地址复制到剪贴板，方便直接粘给同学
func _copy_net_info() -> void:
	var lan := Net.lan_address()
	var txt := ""
	if Net.public_address != "":
		txt = "%s:%d" % [Net.public_address, GAME_PORT]
	elif lan != "":
		txt = "%s:%d" % [lan, GAME_PORT]
	else:
		txt = "127.0.0.1:%d" % GAME_PORT
	DisplayServer.clipboard_set(txt)
	if _net_info != null:
		_net_info.text = Net.net_info_text() + "\n已复制：" + txt


func _apply_nick() -> void:
	var nm: String = _nick_edit.text.strip_edges()
	if nm.is_empty():
		return
	_nick = nm
	Net.set_my_name(nm)
	_save_profile(_last_addr)


func _apply_hero(id: String) -> void:
	_hero = id
	Net.set_my_hero(id)
	_save_profile(_last_addr)
	_refresh_hero_highlights()


## 只重画外观按钮的高亮，不动输入框（换装时不该把正在输入的昵称清掉）
func _refresh_hero_highlights() -> void:
	var HeroDB := preload("res://scripts/sandbox/hero_db.gd")
	for i in _hero_btns.size():
		var on: bool = str(HeroDB.HEROES[i]["id"]) == _hero
		_hero_btns[i].modulate = Color(1, 1, 1, 1) if on else Color(0.55, 0.6, 0.58, 1)


func _reconnect() -> void:
	_last_addr = _addr_edit.text.strip_edges()
	_save_profile(_last_addr)
	_toggle_settings(false)
	LanFind.stop_responder()                     # 原来当主机的话先把应答器关掉
	_booting = true
	_online = false
	_hud.visible = false
	Net.leave_game("正在切换服务器…")
	_boot()


func _set_local_blocked(v: bool) -> void:
	for p in get_tree().get_nodes_in_group("players"):
		if p.is_local_player:
			p.ui_blocked = v


# ---------------------------------------------------------------- 存档
func _load_profile() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PROFILE_PATH) != OK:
		_nick = _random_nick()
		_hero = "adam"
		_last_addr = ""
		_save_profile("")
		return
	_nick = str(cfg.get_value("me", "nick", _random_nick()))
	_hero = str(cfg.get_value("me", "hero", "adam"))
	_last_addr = str(cfg.get_value("net", "last_addr", ""))


func _save_profile(addr: String) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("me", "nick", _nick)
	cfg.set_value("me", "hero", _hero)
	cfg.set_value("net", "last_addr", addr)
	cfg.save(PROFILE_PATH)


## 第一次打开时给个不重名的默认昵称，玩家想改就按 Tab
func _random_nick() -> String:
	var pool: Array[String] = ["航空", "航天", "航海", "材料", "计算机", "自动化", "微电子", "动力", "机电", "软件"]
	var n: String = pool[randi() % pool.size()]
	return "%s同学%02d" % [n, randi() % 100]
