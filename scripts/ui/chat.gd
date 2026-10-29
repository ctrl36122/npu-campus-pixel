extends CanvasLayer
## 群聊：屏幕上的聊天窗口 + 说话时头顶的气泡。
##
## 两种形态，只有两种：
##   收起 —— 小窗贴着屏幕一角，只显示最近的几条消息，点标题栏展开
##   展开 —— 占满屏幕，底部是输入行，右上角 ✕ 收起
##
## 交互只用 GUI 的 Button.pressed（标题栏整条是一个按钮、✕ 是一个按钮），
## 不再用 _input 热区自己判位置 —— 之前那套「触摸 + 合成鼠标 + 热区」三路并存，
## 点一次会被处理两次、互相抵消，才会出现「点了没反应」。
##
## 消息用**一个** RichTextLabel 承载全部历史（而不是每条一个节点塞进 VBox）：
## 后者在固定高度的容器里会被压缩，消息一多就糊成一团。

const MAX_HISTORY := 60         # 最多保留多少条
const IDLE_FADE := 12.0         # 多久没消息开始变淡
const FADE_ALPHA := 0.68

const SMALL_W_RATIO := 0.42     # 收起时的窗口宽度（占视口宽的比例）
const SMALL_H_RATIO := 0.13     # 收起时的窗口高度（占视口高的比例）
const DESK_W := 392.0           # 收起时的窗口尺寸（桌面）
const DESK_H := 212.0
const TOUCH_FS := 20            # 触屏字号：视口逻辑宽恒为 1280，13 落到手机上只有 11px
const TOUCH_FS_BIG := 24

const C_SELF := "#8ec5ff"
const C_OTHER := "#e6eef6"
const C_SYS := "#8a99a6"
const C_TIME := "#5f6f7c"

var _font: Font
var _panel: Panel                    # 用 Panel 而不是 PanelContainer：容器会被内容撑大，
var _rule: ColorRect                 # 消息一多就把输入行顶到屏幕外
var _title_btn: Button
var _close_btn: Button
var _scroll: ScrollContainer
var _log: RichTextLabel
var _composer: HBoxContainer
var _edit: LineEdit
var _send_btn: Button

var _expanded := false
var _active := false
var _hidden := false
var _idle := 0.0
var _history: Array[String] = []      # 每条形如 "[color=#5f7]12:34[/color] [color=..]名字[/color]：正文"
var _known: Dictionary = {}           # peer_id -> 昵称，用来识别「谁进来了 / 谁走了」
var _last_vk := 0                     # 上次读到的软键盘高度，变了就重排


func _ready() -> void:
	layer = 9                          # 低于主 UI(10)：全屏地图打开时会盖住它
	_font = GameTheme.font()
	_build()
	Net.message_received.connect(_on_message)
	Net.history_received.connect(_on_history)
	Net.roster_changed.connect(_on_roster)
	_apply_layout()
	_rebuild_log()
	set_process(true)
	if OS.has_environment("XGD_CHAT_DEMO"):
		_demo.call_deferred()
	if OS.has_environment("XGD_CHAT_EXPAND"):
		var t := get_tree().create_timer(3.0)
		t.timeout.connect(func(): set_expanded(true))


func _demo() -> void:
	await get_tree().create_timer(2.0).timeout
	_on_roster()
	_append_system("早八人 进入了校园")
	_on_message("干饭人", "有人一起去食堂吗")
	_on_message("散步党", "刚从图书馆出来，今天人超多，这条特意写长一点看看会不会正确换行以及会不会把下面的消息挤掉")
	_on_message("夜跑选手", "等会儿操场见")
	_on_message("干饭人", "我在云餐二楼，靠窗那排")
	var me := str(Net.peers.get(Net.my_id(), {}).get("name", "我"))
	_on_message(me, "我这边刚下课，五分钟就到")


# ---------------------------------------------------------------- 对外接口
func is_typing() -> bool:
	return _active


## 触屏「聊」按钮：一步到位换成大窗并进入输入，不用先开小窗再点第二下
func open_typing() -> void:
	set_expanded(true)
	_open_input()


## 打开设置 / 全屏地图时把群聊让开
func set_hidden(v: bool) -> void:
	_hidden = v
	if is_instance_valid(_panel):
		_panel.visible = not v


## 展开 / 收起。所有入口（标题栏、✕、Esc、触屏按钮）最后都走这里
func set_expanded(v: bool) -> void:
	if _expanded == v:
		return
	_expanded = v
	if not v and _active:
		_close_input(false)
	_apply_layout()
	_scroll_to_bottom(true)
	_set_local_blocked(v)
	var boot := get_tree().get_first_node_in_group("boot_ui")
	if boot != null and boot.has_method("set_overlay"):
		boot.call("set_overlay", v)
	# 大窗盖住半个屏幕：右下按钮收起来，摇杆也停掉。
	# 不接管触摸的话，点大窗下半部分会落到摇杆判定区，人会一边看聊天一边往前走。
	var tp := get_tree().get_first_node_in_group("touch_pad")
	if tp != null:
		if tp.has_method("set_buttons_hidden_for"):
			tp.call("set_buttons_hidden_for", "chat", v)
		if tp.has_method("set_touch_grabbed_for"):
			tp.call("set_touch_grabbed_for", "chat", v)
	if v:
		_open_input()


func _toggle() -> void:
	set_expanded(not _expanded)


# ---------------------------------------------------------------- 布局
func _apply_layout() -> void:
	if _panel == null:
		return
	var touch := _is_touch()
	var vs := get_viewport().get_visible_rect().size
	var vk := _vk_inset()

	# 一律按左上角定位 + 绝对尺寸：锚点组合太多容易互相打架，只有 4 个数反而不出错
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	if _expanded:
		# 展开不等于铺满：手机上占半屏就够，露出下面还能看见自己在哪
		var avail := vs.y - vk
		var w: float
		var h: float
		if touch:
			w = vs.x * 0.94
			h = minf(vs.y * 0.54, avail - 24.0)
		else:
			w = vs.x * 0.62
			h = minf(vs.y * 0.80, avail - 40.0)
		_panel.size = Vector2(w, maxf(h, 200.0))
		_panel.position = Vector2(
			(vs.x - w) * 0.5,
			clampf((avail - _panel.size.y) * 0.5, 8.0, maxf(8.0, avail - _panel.size.y - 8.0)))
	else:
		if touch:
			# 按视口比例算：逻辑宽恒为 1280，写死 304 落到手机上只有屏宽的两成
			var w := clampf(vs.x * SMALL_W_RATIO, 360.0, 660.0)
			var h := clampf(vs.y * SMALL_H_RATIO, 150.0, 280.0)
			_panel.position = Vector2(12.0, 14.0)
			_panel.size = Vector2(w, h)
		else:
			_panel.position = Vector2(12.0, vs.y - DESK_H - 46.0)
			_panel.size = Vector2(DESK_W, DESK_H)

	# 大窗盖住整屏，稍微实一点，文字才不被底下的地图干扰；小窗保持薄透
	_panel.add_theme_stylebox_override("panel", _panel_box(0.90 if _expanded else 0.82))

	_composer.visible = _expanded
	_close_btn.visible = _expanded
	_refresh_head()
	_apply_font()
	_layout_children()


## 子控件全部手动摆位。用 Panel（不是容器）+ 绝对 rect，是为了让消息区高度只由
## 面板高度决定，不会被聊天内容撑开把输入行顶出屏幕。
func _layout_children() -> void:
	var w := _panel.size.x
	var h := _panel.size.y
	var pad := 10.0
	var head_h := 46.0 if _is_touch() else 28.0
	var comp_h := 50.0 if _is_touch() else 30.0
	var close_w := 44.0

	var top := 4.0 + head_h + 8.0
	_title_btn.position = Vector2(pad, 4.0)
	_title_btn.size = Vector2(w - pad * 2.0 - (close_w if _expanded else 0.0), head_h)
	_close_btn.position = Vector2(w - pad - close_w, 4.0)
	_close_btn.size = Vector2(close_w, head_h)
	_rule.position = Vector2(pad, 4.0 + head_h + 2.0)
	_rule.size = Vector2(maxf(0.0, w - pad * 2.0), 1.0)

	var bottom := pad
	if _expanded:
		bottom += comp_h + 8.0
		_composer.position = Vector2(pad, h - pad - comp_h)
		_composer.size = Vector2(w - pad * 2.0, comp_h)
	_scroll.position = Vector2(pad, top)
	_scroll.size = Vector2(maxf(0.0, w - pad * 2.0), maxf(0.0, h - top - bottom))


## 软键盘挡住的高度（逻辑像素）。键盘没弹出来就是 0。
## 只有移动端有软键盘，桌面调这个 API 会刷警告，先挡掉。
func _vk_inset() -> float:
	if not OS.has_feature("mobile"):
		return 0.0
	var h := DisplayServer.virtual_keyboard_get_height()
	if h <= 0:
		return 0.0
	var win_y := float(DisplayServer.window_get_size().y)
	if win_y <= 0.0:
		return 0.0
	return h * (get_viewport().get_visible_rect().size.y / win_y)


func _apply_font() -> void:
	var touch := _is_touch()
	var fs := TOUCH_FS if touch else GameTheme.FS_BODY
	if _expanded:
		fs = TOUCH_FS_BIG if touch else 18
	if is_instance_valid(_log):
		_log.add_theme_font_size_override("normal_font_size", fs)
		_log.add_theme_font_size_override("bold_font_size", fs)
	if is_instance_valid(_edit):
		_edit.add_theme_font_size_override("font_size", fs)
	if is_instance_valid(_title_btn):
		_title_btn.add_theme_font_size_override("font_size", (15 if touch else GameTheme.FS_SMALL) + (1 if _expanded else 0))


func _refresh_head() -> void:
	if _title_btn == null:
		return
	var n := Net.peer_count()
	_title_btn.text = "校园群聊 · %d 人" % n
	if _close_btn != null:
		_close_btn.visible = _expanded


# ---------------------------------------------------------------- 界面
func _build() -> void:
	_panel = Panel.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP      # 接住点击，别穿到下面的世界里
	_panel.add_theme_stylebox_override("panel", _panel_box(0.82))
	_panel.gui_input.connect(_on_panel_gui_input)
	add_child(_panel)

	# ── 标题栏：整条是一个 Button（手指好点），右边是 ✕ ──
	_title_btn = Button.new()
	_title_btn.flat = true
	_title_btn.focus_mode = Control.FOCUS_NONE
	_title_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title_btn.add_theme_font_override("font", _font)
	_title_btn.add_theme_font_size_override("font_size", GameTheme.FS_SMALL)
	_title_btn.add_theme_color_override("font_color", Color("#93a3b0"))
	_title_btn.add_theme_color_override("font_hover_color", Color("#cfdae4"))
	_title_btn.add_theme_color_override("font_pressed_color", Color("#ffffff"))
	_title_btn.pressed.connect(_toggle)
	_panel.add_child(_title_btn)

	_close_btn = Button.new()
	_close_btn.text = "✕"
	_close_btn.flat = true
	_close_btn.focus_mode = Control.FOCUS_NONE
	_close_btn.add_theme_font_override("font", _font)
	_close_btn.add_theme_font_size_override("font_size", 22)
	_close_btn.add_theme_color_override("font_color", Color("#9fb0bf"))
	_close_btn.add_theme_color_override("font_hover_color", Color("#ffffff"))
	_close_btn.add_theme_color_override("font_pressed_color", Color("#ffffff"))
	_close_btn.visible = false
	_close_btn.pressed.connect(func(): set_expanded(false))
	_panel.add_child(_close_btn)

	_rule = ColorRect.new()
	_rule.color = Color(0.20, 0.27, 0.35, 0.9)
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_rule)

	# ── 消息区：ScrollContainer 里只放一个 RichTextLabel ──
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.mouse_filter = Control.MOUSE_FILTER_STOP      # 手指能在上面拖着翻历史
	_scroll.resized.connect(_on_scroll_resized)
	_panel.add_child(_scroll)
	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.fit_content = true                              # 高度由内容决定，不会被容器压扁
	_log.scroll_active = false                           # 滚动交给外面的 ScrollContainer
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_log.add_theme_font_override("normal_font", _font)
	_log.add_theme_font_override("bold_font", _font)
	_log.add_theme_font_size_override("normal_font_size", GameTheme.FS_BODY)
	_log.add_theme_color_override("default_color", Color(C_OTHER))
	_log.add_theme_constant_override("line_separation", 8 if _is_touch() else 3)
	_scroll.add_child(_log)

	# ── 输入行：只在大窗里出现，贴在面板底部（键盘弹出时面板跟着变矮） ──
	_composer = HBoxContainer.new()
	_composer.add_theme_constant_override("separation", 6)
	_composer.visible = false
	_panel.add_child(_composer)

	_edit = LineEdit.new()
	_edit.placeholder_text = "说点什么…（键盘上的发送键＝发出）" if _is_touch() else "对所有人说…（回车发送，Esc 取消）"
	_edit.max_length = 160
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit.custom_minimum_size = Vector2(0, 50 if _is_touch() else 30)
	_edit.add_theme_font_override("font", _font)
	_edit.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	_edit.add_theme_color_override("font_color", Color("#e6eef6"))
	_edit.add_theme_color_override("font_placeholder_color", Color("#6d7d8b"))
	_edit.text_submitted.connect(_on_submitted)
	_composer.add_child(_edit)

	_send_btn = Button.new()
	_send_btn.text = "发送"
	_send_btn.focus_mode = Control.FOCUS_NONE
	_send_btn.custom_minimum_size = Vector2(72, 50)
	_send_btn.add_theme_font_override("font", _font)
	_send_btn.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	_send_btn.add_theme_color_override("font_color", Color("#8ec5ff"))
	_send_btn.add_theme_stylebox_override("normal", _send_box(Color(0.24, 0.44, 0.62, 0.30)))
	_send_btn.add_theme_stylebox_override("hover", _send_box(Color(0.24, 0.44, 0.62, 0.55)))
	_send_btn.add_theme_stylebox_override("pressed", _send_box(Color(0.24, 0.44, 0.62, 0.75)))
	_send_btn.pressed.connect(func(): _on_submitted(_edit.text))
	_composer.add_child(_send_btn)


func _panel_box(alpha: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.031, 0.043, 0.058, alpha)     # 半透明（用户明确要求透出底下地图）
	box.border_color = Color(0.22, 0.30, 0.39, 1.0)
	box.set_border_width_all(2)                          # 项目约定：2px 实线 + 无圆角
	return box
	return box


func _send_box(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.border_color = Color(0.29, 0.53, 0.78, 0.9)
	sb.set_border_width_all(1)
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	return sb


# ---------------------------------------------------------------- 输入
func _open_input() -> void:
	_active = true
	_edit.text = ""
	_edit.grab_focus()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_show("")
	_idle = 0.0
	_panel.modulate.a = 1.0
	_scroll_to_bottom(true)


func _close_input(send: bool) -> void:
	var text: String = _edit.text.strip_edges()
	_active = false
	_edit.release_focus()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_hide()
	if send and not text.is_empty():
		Net.post_message.rpc(text)      # call_local：自己也会立刻收到一条
		_idle = 0.0
		_panel.modulate.a = 1.0


func _on_submitted(text: String) -> void:
	_close_input(true)
	if _is_touch():
		set_expanded(false)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = event.keycode
	if key == KEY_ESCAPE:
		if _active:
			_close_input(false)
		elif _expanded:
			set_expanded(false)
		else:
			return
		get_viewport().set_input_as_handled()
		return
	if key == KEY_ENTER or key == KEY_KP_ENTER:
		if not _expanded:
			set_expanded(true)          # 会顺手聚焦输入
			get_viewport().set_input_as_handled()


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
	_refresh_head()


# ---------------------------------------------------------------- 渲染
func _append(speaker: String, text: String, mine: bool, ts: String) -> void:
	var body := "[color=%s]%s[/color]：%s" % [
		C_SELF if mine else _name_color(speaker), _bb(speaker), _bb(text)]
	_push(body, ts)


func _append_system(text: String) -> void:
	_push("[color=%s]· %s[/color]" % [C_SYS, _bb(text)], "")


func _push(bbcode: String, ts: String) -> void:
	var stamp := ts if ts != "" else Time.get_time_string_from_system().left(5)
	_history.append("[color=%s]%s[/color] %s" % [C_TIME, stamp, bbcode])
	while _history.size() > MAX_HISTORY:
		_history.pop_front()
	_rebuild_log()
	_panel.modulate.a = 1.0
	_idle = 0.0


## 整段重排。60 条文本的量，重建比逐条删节点省心（也避免节点高度算错）。
## 关键：重建会重算滚动范围，所以先记下「当前是否贴着底」和「离底多远」，
## 重建后按原样恢复 —— 用户正往上翻历史时，新消息不能把他拽回底部。
func _rebuild_log() -> void:
	if not is_instance_valid(_log) or not is_instance_valid(_scroll):
		return
	var bar := _scroll.get_v_scroll_bar()
	var bottom_before := int(bar.max_value - bar.page)
	var stick := _scroll.scroll_vertical >= bottom_before - 8
	var keep := _scroll.scroll_vertical

	if _history.is_empty():
		_log.text = "[color=%s]还没有人说话%s[/color]" % [
			C_SYS, " · 点右下「聊」发言" if _is_touch() else " · 按回车发言"]
	else:
		_log.text = "\n".join(_history)

	# RichTextLabel 换了文本之后，高度要等它重新排版完才准 —— 一帧不够，两帧才稳
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(_scroll):
		return
	_fit_panel()
	_fit_scroll()
	bar = _scroll.get_v_scroll_bar()
	var bottom := int(bar.max_value - bar.page)
	# 贴底就跟到底；正在翻历史就原地不动（新消息加在下面，视图不该被推走）
	if stick:
		_scroll.scroll_vertical = int(bar.max_value)      # 超出部分由 ScrollContainer 自己 clamp
	else:
		_scroll.scroll_vertical = mini(keep, bottom)


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


## force=true 一定跳到最新；否则只在已经贴着底的时候跟（别打断正在翻历史的人）
func _scroll_to_bottom(force: bool = false) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(_scroll):
		return
	_fit_panel()
	_fit_scroll()
	var bar := _scroll.get_v_scroll_bar()
	var bottom := int(bar.max_value - bar.page)
	if force or _scroll.scroll_vertical >= bottom - 8:
		_scroll.scroll_vertical = int(bar.max_value)


## 消息区尺寸变了（展开 / 收起 / 键盘弹出）之后重新贴底，
## 不然最后一行会被下边缘切掉半截
## 大窗高度跟着消息条数长，最多到半屏 —— 消息少时不会是一整块空面板。
## 跑完如果高度变了会重排子控件，所以调用方要在它之后再做贴底。
func _fit_panel() -> void:
	if not _expanded or not is_instance_valid(_log) or not is_instance_valid(_panel):
		return
	var vs := get_viewport().get_visible_rect().size
	var avail := vs.y - _vk_inset()
	var pad := 10.0
	var head_h := 46.0 if _is_touch() else 28.0
	var comp_h := 50.0 if _is_touch() else 30.0
	var chrome := (4.0 + head_h + 8.0) + (pad + comp_h + 8.0)
	var content := float(_log.get_content_height()) + 6.0
	var cap := avail * (0.54 if _is_touch() else 0.80)
	var want := clampf(content + chrome, 240.0, cap)
	if absf(_panel.size.y - want) > 2.0:
		_panel.size.y = want
		_panel.position.y = clampf((avail - want) * 0.5, 8.0, maxf(8.0, avail - want - 8.0))
		_layout_children()


## 消息没几行时，把消息区缩到内容高度、贴着输入行往上排（聊天软件都是底部对齐）；
## 内容超出一屏就铺满可用高度，交给滚动条
func _fit_scroll() -> void:
	if not is_instance_valid(_scroll) or not is_instance_valid(_log):
		return
	var w := _panel.size.x
	var h := _panel.size.y
	var pad := 10.0
	var head_h := 46.0 if _is_touch() else 28.0
	var comp_h := 50.0 if _is_touch() else 30.0
	var top := 4.0 + head_h + 8.0
	var bottom := pad + (comp_h + 8.0 if _expanded else 0.0)
	var avail := maxf(0.0, h - top - bottom)
	var content := float(_log.get_content_height()) + 6.0
	var use := avail if _expanded else minf(content, avail)
	_scroll.size = Vector2(maxf(0.0, w - pad * 2.0), maxf(0.0, use))
	_scroll.position = Vector2(pad, maxf(top, h - bottom - use))


## 滚轮：不管鼠标落在面板的哪个位置（标题栏、空白、消息上），都算「翻聊天记录」，
## 并且把事件吃掉 —— 否则它会漏到世界层变成镜头缩放：
## 玩家在聊天框上滚，结果地图在动，看着就像「滚不动」。
func _on_panel_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton) or not event.pressed:
		return
	var step := 0
	if event.button_index == MOUSE_BUTTON_WHEEL_UP:
		step = -1
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		step = 1
	if step == 0:
		return
	_scroll.scroll_vertical += step * 60          # 一次约两行
	_panel.accept_event()


func _on_scroll_resized() -> void:
	call_deferred("_stick_bottom_if_needed")


func _stick_bottom_if_needed() -> void:
	if not is_instance_valid(_scroll):
		return
	var bar := _scroll.get_v_scroll_bar()
	var bottom := int(bar.max_value - bar.page)
	if _scroll.scroll_vertical >= bottom - 48:
		_scroll.scroll_vertical = int(bar.max_value)


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	# 软键盘弹出 / 收起时窗口高度会变，面板要跟着让出位置，否则输入行被键盘盖住
	if OS.has_feature("mobile"):
		var vk := DisplayServer.virtual_keyboard_get_height()
		if vk != _last_vk:
			_last_vk = vk
			_apply_layout()
	if _hidden or _active or _expanded:
		return
	_idle += delta
	if _idle > IDLE_FADE and _panel.modulate.a > FADE_ALPHA:
		_panel.modulate.a = maxf(FADE_ALPHA, _panel.modulate.a - delta * 1.2)


## 是否运行在触摸设备上（手机包，或桌面用 XGD_TOUCH=1 预览）
func _is_touch() -> bool:
	return OS.has_feature("mobile") or OS.has_environment("XGD_TOUCH")
