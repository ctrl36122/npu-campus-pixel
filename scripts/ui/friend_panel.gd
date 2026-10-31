extends CanvasLayer
## 好友面板：谁加了我、我加了谁、把谁删掉。
##
## 为什么需要一个面板而不是只靠命令：好友请求是**异步**的 —— 对方可能在你离线时
## 发来请求，也可能在楼里另一个楼层发。只靠聊天命令（/accept 昵称）很容易错过，
## 而按 E 接受要求两个人站在一起。所以给一个随时能按 P 打开的面板。
##
## 数据全来自 Net.my_friends（服务端下发的那份切片），这里只负责画和发命令，
## 不做任何本地裁定 —— 加好友、通过、删除都以服务端回包为准。
##
## 快捷键 P（Peers）。聊天输入框有焦点时不响应，避免打字打出个面板来。

signal opened
signal closed

var _font: Font
var _mask: ColorRect
var _panel: PanelContainer
var _req_box: VBoxContainer
var _req_title: Label
var _friend_box: VBoxContainer
var _empty: Label
var _is_open := false


func _ready() -> void:
	layer = 12                          # 压在主 UI 之上，和说明页同级
	_font = GameTheme.font()
	_build()
	_is_open = false
	_mask.visible = false
	_panel.visible = false
	Net.social_changed.connect(_rebuild)
	Net.message_received.connect(_on_message)


# ---------------------------------------------------------------- 开关
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_P:
		if _typing() or Net.is_dedicated:
			return
		toggle()
		get_viewport().set_input_as_handled()
	elif k.keycode == KEY_ESCAPE and _is_open:
		close()
		get_viewport().set_input_as_handled()


## 焦点在文本输入里时不抢按键（否则聊天框里打不出 p）
func _typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit


func toggle() -> void:
	if _is_open:
		close()
	else:
		open()


## online_boot 用它决定要不要挡住人物移动
func is_open() -> bool:
	return _is_open


func open() -> void:
	if _is_open:
		return
	_is_open = true
	_mask.visible = true
	_panel.visible = true
	_rebuild()
	opened.emit()


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	_mask.visible = false
	_panel.visible = false
	closed.emit()


# ---------------------------------------------------------------- 搭界面
func _build() -> void:
	_mask = ColorRect.new()
	_mask.color = Color(0.02, 0.03, 0.04, 0.72)
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
	_panel.custom_minimum_size = Vector2(minf(vs.x * 0.86, 480.0), 0)
	_panel.add_theme_stylebox_override("panel", _box())
	center.add_child(_panel)

	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		pad.add_theme_constant_override(m, 18)
	for m in ["margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 14)
	_panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	pad.add_child(col)

	# 标题行
	var head := HBoxContainer.new()
	col.add_child(head)
	var title := _label("好友", 19, "#e8eef2", true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var x := Button.new()
	x.text = "关闭"
	x.focus_mode = Control.FOCUS_NONE
	_style_btn(x, Color(0.20, 0.24, 0.29, 0.55))
	x.pressed.connect(close)
	head.add_child(x)

	# 待处理请求（没有请求时整块隐藏）
	_req_title = _label("待你接受", 14, "#ffd479", true)
	col.add_child(_req_title)
	_req_box = VBoxContainer.new()
	_req_box.add_theme_constant_override("separation", 6)
	col.add_child(_req_box)

	col.add_child(HSeparator.new())

	col.add_child(_label("我的好友", 14, "#8ec5ff", true))

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, clampf(vs.y * 0.34, 120.0, 260.0))
	col.add_child(scroll)

	_friend_box = VBoxContainer.new()
	_friend_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_friend_box.add_theme_constant_override("separation", 6)
	scroll.add_child(_friend_box)

	_empty = _label("还没有好友。走到同学旁边按 E，或在聊天框输入 /friend 昵称。",
		13, "#8a99a6")
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_empty)

	col.add_child(_label("按 P 开关这个面板", 12, "#5f6f7c"))


## 重建列表。数据只读 Net.my_friends，不缓存 —— 每次变了就整块重画，
## 这点行数（几十个好友）重建的开销可以忽略，比逐行做 diff 稳。
func _rebuild() -> void:
	if _req_box == null:
		return
	for c in _req_box.get_children():
		c.queue_free()
	for c in _friend_box.get_children():
		c.queue_free()

	var reqs := Net.friend_requests()
	_req_title.visible = reqs.size() > 0
	_req_box.visible = reqs.size() > 0
	for r in reqs:
		_req_box.add_child(_request_row(String(r["uid"]), String(r["name"])))

	var friends := Net.friend_list()
	_empty.visible = friends.size() == 0
	for f in friends:
		_friend_box.add_child(_friend_row(String(f["uid"]), String(f["name"])))


func _request_row(uid: String, nm: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lb := _label(nm, 14, "#ffe9a8")
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lb)
	var yes := Button.new()
	yes.text = "接受"
	yes.focus_mode = Control.FOCUS_NONE
	_style_btn(yes, Color(0.20, 0.46, 0.34, 0.55))
	yes.pressed.connect(func() -> void:
		Net.friend_accept(uid)
		_rebuild())
	row.add_child(yes)
	var no := Button.new()
	no.text = "拒绝"
	no.focus_mode = Control.FOCUS_NONE
	_style_btn(no, Color(0.40, 0.24, 0.24, 0.55))
	no.pressed.connect(func() -> void:
		Net.friend_deny(uid)
		_rebuild())
	row.add_child(no)
	return row


func _friend_row(uid: String, nm: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lb := _label(nm, 14, "#dbe6ef")
	lb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lb)
	var st := _label("在线" if _online(uid) else "离线", 12,
		"#9ff0d0" if _online(uid) else "#6f7f8c")
	row.add_child(st)
	var del := Button.new()
	del.text = "删除"
	del.focus_mode = Control.FOCUS_NONE
	_style_btn(del, Color(0.34, 0.22, 0.22, 0.45))
	del.pressed.connect(func() -> void:
		Net.friend_remove(uid)
		_rebuild())
	row.add_child(del)
	return row


func _online(uid: String) -> bool:
	for id in Net.peers:
		if str(Net.peers[id].get("uid", "")) == uid:
			return true
	return false


## 收到好友请求：面板没开就闪一下提示（聊天里也会有一行系统消息）
func _on_message(speaker: String, text: String) -> void:
	if speaker != Net.SYS_SPEAKER or not text.begins_with("@FRIENDREQ|"):
		return
	if _is_open:
		_rebuild()


# ---------------------------------------------------------------- 小工具
func _label(text: String, size: int, color: String, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", GameTheme.font_bold() if bold else _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(color))
	return l


func _style_btn(b: Button, c: Color) -> void:
	b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", 13)
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


func _btn_box(c: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c
	sb.border_color = Color(0.29, 0.53, 0.78, 0.9)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 10.0
	sb.content_margin_right = 10.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb
