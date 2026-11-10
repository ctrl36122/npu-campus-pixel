extends CanvasLayer
## 好友私信窗口：一次一个人，从好友面板点「私信」进来。
##
## 消息走 Net.send_dm() / Net.dm_received（前缀编码 + 客户端过滤），
## **不会进公屏**：Net 在把消息分发到 message_received 之前就把私信串截走，
## 只有收件人那一端会看到 dm_received。所以聊天框、头顶气泡、历史记录里都不会出现。
##
## 历史只活在本局内存（_history，按对方 uid 分），退出游戏就没了 ——
## 刻意不落盘：私信落盘意味着要处理加密/清理，这个校园小游戏不值得。
##
## Esc 或点遮罩关闭；桌面回车发送，手机用键盘上的发送键。

signal opened
signal closed

const MAX_ROWS := 300          # 单个会话最多留多少条，防止开久了吃内存

var _font: Font
var _mask: ColorRect
var _panel: PanelContainer
var _title: Label
var _sub: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _edit: LineEdit
var _send: Button
var _empty: Label
var _is_open := false
var _uid := ""
var _name := ""
## uid -> [{"mine": bool, "text": String}]
var _history: Dictionary = {}
## uid -> 未读数（面板关着时攒着，下次打开清掉）
var _unread: Dictionary = {}


func _ready() -> void:
	layer = 13                      # 比好友面板（12）高一层：从好友列表点进来时要盖住它
	_font = GameTheme.font()
	_build()
	_mask.visible = false
	_panel.visible = false
	Net.dm_received.connect(_on_dm)


# ---------------------------------------------------------------- 开关
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_ESCAPE and _is_open:
		close()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _is_open


func current_uid() -> String:
	return _uid


## 打开（或在同一个窗口里切到另一个好友）
func open_dm(uid: String, nm: String) -> void:
	if uid.is_empty():
		return
	_uid = uid
	_name = nm
	_unread.erase(uid)
	_title.text = "与 %s 私信" % nm
	_sub.text = "只有 %s 能看到 · 不进公屏" % nm
	_rebuild()
	_mask.visible = true
	_panel.visible = true
	if not _is_open:
		_is_open = true
		opened.emit()
	_edit.text = ""
	_scroll_bottom.call_deferred()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_show("")


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	_mask.visible = false
	_panel.visible = false
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_hide()
	closed.emit()


# ---------------------------------------------------------------- 搭界面
func _build() -> void:
	_mask = ColorRect.new()
	_mask.color = Color(0.02, 0.03, 0.04, 0.66)
	_mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mask.mouse_filter = Control.MOUSE_FILTER_STOP
	_mask.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			close())
	add_child(_mask)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var vs := get_viewport().get_visible_rect().size
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(minf(vs.x * 0.88, GameTheme.px(460.0)), 0)
	_panel.add_theme_stylebox_override("panel", _box())
	center.add_child(_panel)

	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		pad.add_theme_constant_override(m, int(GameTheme.px(16.0)))
	for m in ["margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, int(GameTheme.px(12.0)))
	_panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(GameTheme.px(8.0)))
	pad.add_child(col)

	# 标题行
	var head := HBoxContainer.new()
	col.add_child(head)
	_title = _label("私信", 18, "#e8eef2", true)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	var x := Button.new()
	x.text = "关闭"
	x.focus_mode = Control.FOCUS_NONE
	_style_btn(x, Color(0.20, 0.24, 0.29, 0.55))
	x.pressed.connect(close)
	head.add_child(x)

	_sub = _label("", 12, "#7f8f9c")
	_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_sub)

	col.add_child(HSeparator.new())

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.custom_minimum_size = Vector2(0,
		clampf(vs.y * 0.28, GameTheme.px(150.0), GameTheme.px(250.0)))
	col.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", int(GameTheme.px(6.0)))
	_scroll.add_child(_list)

	_empty = _label("还没聊过。打个招呼吧。", 13, "#6f7f8c")
	col.add_child(_empty)

	# 输入行
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(GameTheme.px(8.0)))
	col.add_child(row)

	_edit = LineEdit.new()
	_edit.max_length = Net.DM_MAX
	_edit.placeholder_text = "私信内容…（回车发送）"
	if GameTheme.touch_ui():
		_edit.placeholder_text = "私信内容…（点「发送」发出）"
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit.custom_minimum_size = Vector2(0, GameTheme.px(34.0))
	_edit.add_theme_font_override("font", _font)
	_edit.add_theme_font_size_override("font_size", GameTheme.fs(GameTheme.FS_BODY))
	_edit.add_theme_color_override("font_color", Color("#e6eef6"))
	_edit.add_theme_color_override("font_placeholder_color", Color("#6d7d8b"))
	_edit.text_submitted.connect(func(_t: String) -> void: _send_now())
	row.add_child(_edit)

	_send = Button.new()
	_send.text = "发送"
	_send.focus_mode = Control.FOCUS_NONE
	_send.custom_minimum_size = Vector2(GameTheme.px(72.0), GameTheme.px(34.0))
	_style_btn(_send, Color(0.20, 0.42, 0.34, 0.65))
	_send.pressed.connect(_send_now)
	row.add_child(_send)


# ---------------------------------------------------------------- 消息
func _send_now() -> void:
	if _uid.is_empty():
		return
	var txt := _edit.text
	if txt.strip_edges().is_empty():
		return
	var err := Net.send_dm(_uid, _name, txt)
	if not err.is_empty():
		_sub.text = err
		_sub.add_theme_color_override("font_color", Color("#ff9a8a"))
		return
	_sub.text = "只有 %s 能看到 · 不进公屏" % _name
	_sub.add_theme_color_override("font_color", Color("#7f8f9c"))
	_edit.text = ""
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_show("")


func _on_dm(from_uid: String, from_name: String, to_uid: String, text: String) -> void:
	var peer_uid := from_uid if to_uid == Net.local_uid else to_uid
	var mine := from_uid == Net.local_uid
	var arr: Array = _history.get(peer_uid, [])
	arr.append({"mine": mine, "text": text})
	if arr.size() > MAX_ROWS:
		arr = arr.slice(arr.size() - MAX_ROWS)
	_history[peer_uid] = arr
	if peer_uid != _uid:
		if not mine:
			_unread[peer_uid] = int(_unread.get(peer_uid, 0)) + 1
		return
	if _is_open:
		_append_row(mine, text)
		_empty.visible = false
		_scroll_bottom.call_deferred()
	elif not mine:
		_unread[peer_uid] = int(_unread.get(peer_uid, 0)) + 1


func unread_of(uid: String) -> int:
	return int(_unread.get(uid, 0))


func _rebuild() -> void:
	for c in _list.get_children():
		c.queue_free()
	var arr: Array = _history.get(_uid, [])
	_empty.visible = arr.is_empty()
	for m in arr:
		if m is Dictionary:
			_append_row(bool(m.get("mine", false)), str(m.get("text", "")))


func _append_row(mine: bool, text: String) -> void:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if mine:
		row.alignment = BoxContainer.ALIGNMENT_END
	_list.add_child(row)

	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", _bubble(mine))
	row.add_child(box)

	var lb := Label.new()
	lb.text = text
	lb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 给自动换行一个确定的宽度；跟着 UI 倍率走，手机上气泡才不会挤成一条
	lb.custom_minimum_size = Vector2(GameTheme.px(220.0), 0)
	lb.add_theme_font_override("font", _font)
	lb.add_theme_font_size_override("font_size", GameTheme.fs(GameTheme.FS_BODY))
	lb.add_theme_color_override("font_color", Color("#e6eef6") if mine else Color("#cfe0ee"))
	box.add_child(lb)


func _scroll_bottom() -> void:
	await get_tree().process_frame
	if _scroll == null or not is_instance_valid(_scroll):
		return
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


# ---------------------------------------------------------------- 小工具
func _label(text: String, size: int, color: String, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", GameTheme.font_bold() if bold else _font)
	l.add_theme_font_size_override("font_size", GameTheme.fs(size))
	l.add_theme_color_override("font_color", Color(color))
	return l


func _style_btn(b: Button, c: Color) -> void:
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", GameTheme.fs(13))
	b.add_theme_color_override("font_color", Color("#dbe6ef"))
	b.add_theme_stylebox_override("normal", _btn_box(c))
	b.add_theme_stylebox_override("hover", _btn_box(c.lightened(0.18)))
	b.add_theme_stylebox_override("pressed", _btn_box(c.darkened(0.15)))


func _box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#0f141a")
	sb.border_color = Color("#31414f")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 12
	sb.shadow_offset = Vector2(0, 5)
	return sb


func _bubble(mine: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#1d3247") if mine else Color("#1a2029")
	sb.border_color = Color("#2f4a63") if mine else Color("#2b3642")
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = GameTheme.px(10.0)
	sb.content_margin_right = GameTheme.px(10.0)
	sb.content_margin_top = GameTheme.px(6.0)
	sb.content_margin_bottom = GameTheme.px(6.0)
	return sb


func _btn_box(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.border_color = Color(0.29, 0.53, 0.78, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = GameTheme.px(10.0)
	sb.content_margin_right = GameTheme.px(10.0)
	var vpad := GameTheme.px(9.0 if GameTheme.touch_ui() else 4.0)
	sb.content_margin_top = vpad
	sb.content_margin_bottom = vpad
	return sb
