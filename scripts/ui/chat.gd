extends CanvasLayer
## 聊天：左下角一个「群聊窗口」+ 说话时头顶气泡。
##
## 面板是常驻的（不输入时半透明淡出，但仍在），有标题栏（在线人数）、
## 时间戳、按人名着色的昵称、以及「谁进来了/离开了」的系统提示。
## 滚轮可以在面板上翻历史（鼠标移出面板后滚轮仍归地图缩放用）。
##
## 联机部分复用 Net.post_message / Net.message_received：服务器校验发言者身份、
## 截断到 160 字，客户端伪造不了别人的名字。

const MAX_HISTORY := 60         # 最多保留多少条（滚轮可翻）
const IDLE_FADE := 12.0         # 多久没消息开始变淡
const FADE_ALPHA := 0.68
const PANEL_W := 392.0
const PANEL_H := 212.0

const C_SELF := "#8ec5ff"
const C_OTHER := "#e6eef6"
const C_SYS := "#8a99a6"
const C_TIME := "#5f6f7c"

var _font: SystemFont
var _panel: PanelContainer
var _title: Label
var _scroll: ScrollContainer
var _log: VBoxContainer
var _edit: LineEdit
var _bar: Control
var _lines: Array[RichTextLabel] = []
var _active := false
var _idle := 0.0
var _known: Dictionary = {}      # peer_id -> 昵称，用来识别「谁进来了 / 谁走了」
var _empty_hint: Label
var _expanded := false
var _toggle_btn: Button
var _head: HBoxContainer
var _last_touch_ms := -1000      # 上一次触摸时间，用来压掉「触摸合成的鼠标事件」


func _ready() -> void:
	layer = 9                     # 低于主 UI(10)：全屏地图打开时会盖住它
	_font = GameTheme.font()
	_build()
	_show_empty_hint()
	Net.message_received.connect(_on_message)
	Net.history_received.connect(_on_history)
	Net.roster_changed.connect(_on_roster)
	set_process(true)
	# 调试用：XGD_CHAT_DEMO=1 灌几条假消息，方便核对群聊面板的排版/换行/滚动
	if OS.has_environment("XGD_CHAT_DEMO"):
		_demo.call_deferred()
	# 调试用：XGD_CHAT_TOGGLE=1 六秒后按一下「收起」按钮（核对按钮真的能收）
	if OS.has_environment("XGD_CHAT_TOGGLE"):
		var tt := get_tree().create_timer(6.0)
		tt.timeout.connect(func():
			print("[chat] 收起前 expanded=", _expanded)
			_toggle_expand()
			print("[chat] 收起后 expanded=", _expanded, " 面板高=", _panel.size.y))
	# 调试用：XGD_CHAT_EXPAND=1 自动展开聊天大窗（核对放大排版）
	if OS.has_environment("XGD_CHAT_EXPAND"):
		var et := get_tree().create_timer(3.0)
		et.timeout.connect(func():
			_expanded = true
			_apply_layout())


func _demo() -> void:
	await get_tree().create_timer(2.0).timeout
	_on_roster()
	_append_system("早八人 进入了校园")
	_on_message("干饭人", "有人一起去食堂吗")
	_on_message("散步党", "刚从图书馆出来，今天人超多，这条特意写长一点看看会不会正确换行以及会不会把下面的消息挤掉")
	_on_message("夜跑选手", "等会儿操场见")
	var me := str(Net.peers.get(Net.my_id(), {}).get("name", "我"))
	_on_message(me, "我这边刚下课，五分钟就到")


func is_typing() -> bool:
	return _active


## 点聊天面板 = 放大看消息（手机小屏上尤其需要），再点一下收起
func _on_panel_gui(event: InputEvent) -> void:
	# 触摸设备只认触摸事件、桌面只认鼠标事件（同一次点按会同时产生两种，混着处理会互相抵消）
	var tapped := false
	if event is InputEventMouseButton:
		tapped = (not _touch_device()) and event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventScreenTouch:
		tapped = _touch_device() and event.pressed
	if tapped:
		_toggle_expand()
		_panel.accept_event()


## 真机上 Button 收不到触摸事件（本项目只有自绘的触屏控件能收到），
## 所以标题栏用原始触摸自己判定：点标题栏任意位置都算「展开 / 收起」。
func _input(event: InputEvent) -> void:
	var pressed := false
	var pos := Vector2.ZERO
	if event is InputEventScreenTouch:
		if not _touch_device():
			return
		pressed = event.pressed
		pos = event.position
	elif event is InputEventMouseButton:
		# 触摸设备上同一次点按会再合成一个鼠标事件（且顺序在触摸之前），
		# 两类都处理就会「展开一次、又收起一次」，表现就是点了没反应 —— 只认一类。
		if _touch_device():
			return
		pressed = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
		pos = event.position
	# 大聊天窗展开时，点面板空白处也算收起（消息行已经是 IGNORE，不会吞事件）
	if not pressed or not is_instance_valid(_panel) or not _panel.visible:
		return
	var inside := false
	if is_instance_valid(_head):
		inside = _head.get_global_rect().grow(8.0).has_point(pos)
	# 按钮那块让 Button 自己响应（真机上 GUI 点击是好的），这里排除掉避免翻两次
	if inside and is_instance_valid(_toggle_btn):
		if _toggle_btn.get_global_rect().grow(10.0).has_point(pos):
			inside = false
	if inside:
		_toggle_expand()
		get_viewport().set_input_as_handled()


func _toggle_expand() -> void:
	_expanded = not _expanded
	_apply_layout()
	_scroll_to_bottom()


## 收起：手机在左上（左下让给摇杆）、桌面在左下；展开：占满屏幕中间的大窗
func _apply_layout() -> void:
	if _panel == null:
		return
	var touch := _is_touch()
	var vs := get_viewport().get_visible_rect().size
	if _expanded:
		_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_panel.offset_left = 10.0
		_panel.offset_right = -10.0
		_panel.offset_top = 52.0
		_panel.offset_bottom = -214.0 if touch else -64.0
	elif touch:
		_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		_panel.offset_left = 12.0
		_panel.offset_top = 16.0
		_panel.offset_right = 12.0 + 272.0
		_panel.offset_bottom = 16.0 + 158.0
	else:
		_panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
		_panel.offset_left = 12.0
		_panel.offset_top = -PANEL_H - 46.0
		_panel.offset_right = 12.0 + PANEL_W
		_panel.offset_bottom = -46.0
	if _panel.get_parent() == null:
		add_child(_panel)
	_panel.modulate.a = 1.0
	_idle = 0.0
	# 展开时字号放大，站着看也清楚
	var fs: int = 18 if _expanded else GameTheme.FS_BODY
	for rt in _lines:
		rt.add_theme_font_size_override("normal_font_size", fs)
	if _title != null:
		_title.add_theme_font_size_override("font_size", GameTheme.FS_BODY if _expanded else GameTheme.FS_SMALL)
		_refresh_title()
	_sync_log_height()
	_scroll_to_bottom()
	_reposition_bar()
	var boot := get_tree().get_first_node_in_group("boot_ui")
	if boot != null and boot.has_method("set_overlay"):
		boot.call("set_overlay", _expanded)
	# 大窗占屏时把右下按钮收起来，否则和输入框重叠
	var tp := get_tree().get_first_node_in_group("touch_pad")
	if tp != null and tp.has_method("set_buttons_hidden"):
		tp.call("set_buttons_hidden", _expanded)
		if _expanded and tp.has_method("release_all"):
			tp.call("release_all")


## 输入栏位置：
##  - 小窗（手机左上）：浮在屏幕中部，避开底部软键盘
##  - 大窗：贴在面板底边内侧，像一个正经聊天软件的输入行
##  - 桌面：贴屏幕底边居中
func _reposition_bar() -> void:
	if _bar == null:
		return
	var touch := _is_touch()
	if _expanded:
		var bottom_pad := 214.0 if touch else 64.0
		_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		_bar.offset_left = 24.0
		_bar.offset_right = -24.0
		_bar.offset_top = -(bottom_pad + 52.0)
		_bar.offset_bottom = -(bottom_pad + 10.0)
	elif touch:
		_bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
		_bar.offset_left = -300.0
		_bar.offset_right = 300.0
		_bar.offset_top = -56.0
		_bar.offset_bottom = -16.0
	else:
		_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
		_bar.offset_left = 240.0
		_bar.offset_right = -240.0
		_bar.offset_top = -52.0
		_bar.offset_bottom = -14.0


func _refresh_title() -> void:
	if _title == null:
		return
	_title.text = "校园群聊 · 在线 %d 人" % Net.peer_count()
	if _toggle_btn != null:
		_toggle_btn.text = "收起" if _expanded else "放大"


## 是否运行在触摸设备上（手机包，或桌面用 XGD_TOUCH=1 预览）
func _touch_device() -> bool:
	return DisplayServer.is_touchscreen_available() or OS.has_feature("mobile") \
		or OS.has_environment("XGD_TOUCH")


func _is_touch() -> bool:
	return OS.has_feature("mobile") or OS.has_environment("XGD_TOUCH")


## 触屏「聊」按钮调用：**直接换成大聊天窗**并进入输入。
## 小窗只有 158 高，点「聊」本来就是想看消息 / 要说话，没必要先进小窗再让用户点第二下。
func open_typing() -> void:
	if _is_touch() and not _expanded:
		_expanded = true
		_apply_layout()
	if not _active:
		_open()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_show("")


## 打开设置/全屏地图时把群聊框让开，免得两块 UI 叠在一起
func set_hidden(v: bool) -> void:
	if is_instance_valid(_panel):
		_panel.visible = not v


# ---------------------------------------------------------------- 界面
func _build() -> void:
	# 群聊窗口（左下）
	var touch := _is_touch()
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP      # 要接住点击（点一下放大/收起）
	_panel.mouse_filter = Control.MOUSE_FILTER_PASS       # 让滚轮能落在面板上
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.031, 0.043, 0.058, 0.82)
	box.border_color = Color(0.22, 0.30, 0.39, 1.0)
	box.set_border_width_all(2)                            # 项目约定：2px 实线 + 无圆角
	box.content_margin_left = 9.0
	box.content_margin_right = 9.0
	box.content_margin_top = 6.0
	box.content_margin_bottom = 6.0
	_panel.add_theme_stylebox_override("panel", box)
	add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	# 注意：容器若设成 IGNORE，会把子控件的点击一起吞掉（标题栏按钮就点不动了）
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	_panel.add_child(col)

	# 标题栏
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 6)
	head.mouse_filter = Control.MOUSE_FILTER_PASS
	_head = head
	col.add_child(head)
	var dot := Label.new()
	dot.text = "■"
	dot.add_theme_font_override("font", _font)
	dot.add_theme_font_size_override("font_size", 8)
	dot.add_theme_color_override("font_color", Color("#5f9e6a"))
	head.add_child(dot)
	_title = Label.new()
	_title.text = "校园群聊"
	_title.add_theme_font_override("font", _font)
	_title.add_theme_font_size_override("font_size", GameTheme.FS_SMALL)
	_title.add_theme_color_override("font_color", Color(C_SYS))
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)

	# 明确的「放大 / 收起」按钮：面板上的点击会被消息行吃掉，光靠点空白处不可靠
	_toggle_btn = Button.new()
	_toggle_btn.text = "放大"
	_toggle_btn.flat = true
	_toggle_btn.focus_mode = Control.FOCUS_NONE
	_toggle_btn.add_theme_font_override("font", _font)
	_toggle_btn.add_theme_font_size_override("font_size", GameTheme.FS_SMALL)
	_toggle_btn.add_theme_color_override("font_color", Color("#8ec5ff"))
	_toggle_btn.add_theme_color_override("font_hover_color", Color("#cfe6ff"))
	_toggle_btn.add_theme_color_override("font_pressed_color", Color("#ffffff"))
	_toggle_btn.custom_minimum_size = Vector2(52, 24)
	_toggle_btn.pressed.connect(_toggle_expand)   # 按钮自己处理点击
	head.add_child(_toggle_btn)

	# 分隔线
	var sep := ColorRect.new()
	sep.color = Color(0.20, 0.27, 0.35, 0.9)
	sep.custom_minimum_size = Vector2(0, 1)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(sep)

	# 消息区（滚轮翻历史）
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.resized.connect(_sync_log_height)
	col.add_child(_scroll)

	_log = VBoxContainer.new()
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.alignment = BoxContainer.ALIGNMENT_END
	_log.add_theme_constant_override("separation", 1)
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scroll.add_child(_log)

	# 输入栏（底部居中，激活时才显示）
	_bar = PanelContainer.new()
	_reposition_bar()
	_bar.visible = false
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.11, 0.95)
	sb.border_color = Color(0.29, 0.53, 0.78, 1)
	sb.set_border_width_all(1)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	_bar.add_theme_stylebox_override("panel", sb)
	add_child(_bar)

	_edit = LineEdit.new()
	if _is_touch():
		_edit.placeholder_text = "说点什么…（键盘上的发送键＝发出）"
	else:
		_edit.placeholder_text = "对所有人说…（回车发送，Esc 取消）"
	_edit.max_length = 160
	_edit.add_theme_font_override("font", _font)
	_edit.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	_edit.add_theme_color_override("font_color", Color("#e6eef6"))
	_edit.add_theme_color_override("font_placeholder_color", Color("#6d7d8b"))
	_edit.text_submitted.connect(_on_submitted)
	_bar.add_child(_edit)

	_panel.gui_input.connect(_on_panel_gui)
	_apply_layout()


# ---------------------------------------------------------------- 输入
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = event.keycode
	if _active:
		if key == KEY_ESCAPE:
			_close(false)
			get_viewport().set_input_as_handled()
		return
	if key == KEY_ENTER or key == KEY_KP_ENTER:
		_open()
		get_viewport().set_input_as_handled()


func _open() -> void:
	_active = true
	_bar.visible = true
	_edit.text = ""
	_edit.grab_focus()
	_set_local_blocked(true)
	_idle = 0.0
	_panel.modulate.a = 1.0
	_scroll_to_bottom()


func _close(send: bool) -> void:
	var text: String = _edit.text.strip_edges()
	_active = false
	_bar.visible = false
	_edit.release_focus()
	_set_local_blocked(false)
	if send and not text.is_empty():
		Net.post_message.rpc(text)      # call_local：自己也会立刻收到一条
		_idle = 0.0
		_panel.modulate.a = 1.0


func _on_submitted(text: String) -> void:
	_edit.text = text
	_close(true)


## 说话时冻结本地移动（避免打字时人物乱跑）
func _set_local_blocked(v: bool) -> void:
	for p in get_tree().get_nodes_in_group("players"):
		if p.is_local_player:
			p.ui_blocked = v


# ---------------------------------------------------------------- 收消息
func _on_message(speaker: String, text: String) -> void:
	var mine := speaker == str(Net.peers.get(Net.my_id(), {}).get("name", ""))
	_append(speaker, text, mine, "")
	for p in get_tree().get_nodes_in_group("players"):
		var nm := str(Net.peers.get(p.owner_peer_id, {}).get("name", ""))
		if nm == speaker and p.has_method("show_bubble"):
			p.show_bubble(text)
			break


## 服务端补发的历史消息：只进列表，不弹头顶气泡
func _on_history(speaker: String, text: String, unix_time: int) -> void:
	var mine := speaker == str(Net.peers.get(Net.my_id(), {}).get("name", ""))
	_append(speaker, text, mine, _fmt_unix(unix_time))


## unix 时间戳 → 本地 HH:MM。服务器跑在 UTC，不能直接用它的时分。
func _fmt_unix(t: int) -> String:
	if t <= 0:
		return ""
	var offset := int(Time.get_unix_time_from_system()) \
		- int(Time.get_unix_time_from_datetime_dict(Time.get_datetime_dict_from_system()))
	var dt := Time.get_datetime_dict_from_unix_time(t + offset)
	return "%02d:%02d" % [int(dt["hour"]), int(dt["minute"])]


## 谁进来了 / 谁走了：对比 roster 变化，本地生成系统提示（不走网络）
func _on_roster() -> void:
	var cur: Dictionary = {}
	for id in Net.peers:
		cur[id] = str(Net.peers[id].get("name", ""))
	if not _known.is_empty():
		for id in cur:
			if not _known.has(id) and int(id) != Net.my_id():
				_append_system("%s 进入了校园" % cur[id])
		for id in _known:
			if not cur.has(id):
				_append_system("%s 离开了" % _known[id])
	_known = cur
	_refresh_title()


# ---------------------------------------------------------------- 渲染一条消息
func _append(speaker: String, text: String, mine: bool, ts: String) -> void:
	var body := "[color=%s]%s[/color]：%s" % [
		C_SELF if mine else _name_color(speaker),
		_bb(speaker), _bb(text)]
	_push(body, ts)


## 一条消息都没有时，面板里给句提示，别是一大块黑
func _show_empty_hint() -> void:
	var l := Label.new()
	l.text = "还没有人说话 · 点右下「聊」发言" if _is_touch() else "还没有人说话 · 按回车发言"
	l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", GameTheme.FS_SMALL)
	l.add_theme_color_override("font_color", Color(C_SYS))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log.add_child(l)
	_empty_hint = l


func _append_system(text: String) -> void:
	_push("[color=%s]· %s[/color]" % [C_SYS, _bb(text)], "")


func _push(bbcode: String, ts: String) -> void:
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rt.custom_minimum_size = Vector2(0, 0)
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rt.add_theme_font_override("normal_font", _font)
	rt.add_theme_font_size_override("normal_font_size", 18 if _expanded else GameTheme.FS_BODY)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rt.add_theme_color_override("default_color", Color(C_OTHER))
	rt.add_theme_constant_override("line_separation", 1)
	rt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var stamp := ts if ts != "" else Time.get_time_string_from_system().left(5)
	rt.text = "[color=%s]%s[/color] %s" % [C_TIME, stamp, bbcode]
	if _empty_hint != null:
		_empty_hint.queue_free()
		_empty_hint = null
	_log.add_child(rt)
	_lines.append(rt)
	while _lines.size() > MAX_HISTORY:
		var old: RichTextLabel = _lines.pop_front()
		old.queue_free()
	_panel.modulate.a = 1.0
	_idle = 0.0
	_sync_log_height()
	_scroll_to_bottom()


## 等人的昵称哈希成固定颜色（同一个人永远同一个色）
func _name_color(name: String) -> String:
	var pal := ["#ffd479", "#9ad3a3", "#f0a3c8", "#a8c4ff", "#ffb38a", "#c5a3ff", "#8fd7d2"]
	var h := 0
	for i in name.length():
		h = (h * 31 + name.unicode_at(i)) % 100000
	return pal[h % pal.size()]


## BBCode 转义：正文里的 [ 会把标签吃掉
func _bb(s: String) -> String:
	return s.replace("[", "[lb]")


## ScrollContainer 只按内容高度排子节点，内容少时 VBox 会贴在顶部、alignment=END 不生效。
## 把 VBox 的最小高度拉到视口高度，消息少时也会贴着底边（像正经聊天窗口）。
func _sync_log_height() -> void:
	if is_instance_valid(_scroll) and is_instance_valid(_log):
		_log.custom_minimum_size.y = _scroll.size.y
		_scroll_to_bottom()


func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _process(delta: float) -> void:
	if _active:
		return
	_idle += delta
	if _idle > IDLE_FADE and _panel.modulate.a > FADE_ALPHA:
		_panel.modulate.a = maxf(FADE_ALPHA, _panel.modulate.a - delta * 1.2)
