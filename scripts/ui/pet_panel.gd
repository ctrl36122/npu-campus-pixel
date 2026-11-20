extends CanvasLayer
## 宠物面板：宿舍里养的猫 —— 名字、花色、亲密度、是不是正牵在手上。
##
## 数据全部来自 Arena.pet_info()（它读存档与当前牵绳状态），面板只负责画；
## 三个写操作也一律回 Arena 做（pet_rename / pet_toggle_leash），面板不自己改存档。
## 打开期间低频轮询一次，摸猫 / 换猫 / 牵绳的状态变化会立刻反映出来。
##
## 「牵出门遛」在手机上没有 F 键可用，所以面板里必须有这颗按钮 —— 两端口径一致。
##
## 快捷键：右下角「宠」按钮（和手机同一套按钮层），Esc 关闭 / 从改名框退回。

signal opened
signal closed

const REFRESH_SEC := 0.4
const NAME_MAX := 12        # 和 Arena.PET_NAME_MAX / Net._sanitize_pets 对齐

var _font: Font
var _mask: ColorRect
var _center: CenterContainer
var _panel: PanelContainer
var _rows: VBoxContainer
var _empty: Label
var _head: Label
var _toast: Label
var _is_open := false
var _arena: Node = null
var _t := 0.0
var _sig := ""

# 改名小窗（盖在主面板上面）
var _dlg_center: CenterContainer
var _dlg: PanelContainer
var _dlg_title: Label
var _dlg_edit: LineEdit
var _dlg_msg: Label
var _dlg_idx := -1


## 花色小色块：左深右浅，1px 描边 —— 不依赖贴图，缺素材也能显示
## 尺寸跟着节点 size 走（手机 UI 放大时不会还是一个 20×22 的小方块）
class ColorChip:
	extends Control
	var dark := Color("3d3445")
	var light := Color("f2eee7")

	func _draw() -> void:
		var half := size.x * 0.5
		draw_rect(Rect2(0, 0, half, size.y), dark)
		draw_rect(Rect2(half, 0, size.x - half, size.y), light)
		draw_rect(Rect2(0, 0, size.x, size.y), Color(0.02, 0.03, 0.04, 0.85), false, 1.0)


func _ready() -> void:
	layer = 12                          # 和好友面板同级，压在 HUD 之上
	_font = GameTheme.font()
	_build()
	_is_open = false
	_mask.visible = false
	_panel.visible = false
	set_process(false)


func setup(arena: Node) -> void:
	_arena = arena


# ---------------------------------------------------------------- 开关
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_ESCAPE and _is_open:
		# 改名框开着时 Esc 只退回面板，别一下把整个面板也关了
		if _dlg.visible:
			_close_rename()
		else:
			close()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	if _is_open:
		close()
	else:
		open()


func is_open() -> bool:
	return _is_open


func open() -> void:
	if _is_open:
		return
	_is_open = true
	_mask.visible = true
	_panel.visible = true
	_dlg.visible = false
	_dlg_idx = -1
	# 空 Label 也占一行高度，重新打开时要把上一次的反馈连带那一行一起收掉
	_toast.text = ""
	_toast.visible = false
	_t = 0.0
	_sig = ""
	_rebuild()
	set_process(true)
	opened.emit()
	# 调试：XGD_PET_RENAME=1（配合 XGD_PET_PANEL=1）直接弹改名框，截图核对排版用
	if OS.has_environment("XGD_PET_RENAME"):
		var list := _pet_list()
		if not list.is_empty():
			_open_rename(0, str((list[0] as Dictionary).get("name", "猫咪")))


func close() -> void:
	if not _is_open:
		return
	_release_keyboard()
	_is_open = false
	_mask.visible = false
	_panel.visible = false
	_dlg.visible = false
	_dlg_idx = -1
	set_process(false)
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

	_center = CenterContainer.new()
	_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	var vs := get_viewport().get_visible_rect().size
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(minf(vs.x * 0.86, GameTheme.px(460.0)), 0)
	_panel.add_theme_stylebox_override("panel", _box())
	_center.add_child(_panel)

	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		pad.add_theme_constant_override(m, int(GameTheme.px(18.0)))
	for m in ["margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, int(GameTheme.px(14.0)))
	_panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(GameTheme.px(10.0)))
	pad.add_child(col)

	var head := HBoxContainer.new()
	col.add_child(head)
	var title := _label("我的猫咪", 19, "#efe4cf", true)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var x := Button.new()
	x.text = "关闭"
	x.focus_mode = Control.FOCUS_NONE
	_style_btn(x, Color(0.20, 0.24, 0.29, 0.55))
	x.pressed.connect(close)
	head.add_child(x)

	_head = _label("", 12, "#8a99a6")
	col.add_child(_head)

	col.add_child(HSeparator.new())

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", int(GameTheme.px(10.0)))
	col.add_child(_rows)

	_empty = _label("", 13, "#8a99a6")
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# 别写死 360：手机上 px(360)=576 比面板内容区还宽，Label 按 576 算只给一行高，
	# 实际渲染换行成两行时第二行就被面板底边裁掉（说明文字只剩半截）。
	_empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_empty)

	# 改名成功 / 牵上绳这类一次性反馈（原本只在世界里的提示条闪一下，面板里看不见）
	_toast = _label("", 12, "#ffd479")
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toast.visible = false
	col.add_child(_toast)

	col.add_child(HSeparator.new())
	var tip_text := "校园里找到猫按 E 摸三次就能领养 · 宿舍里按 E 摸猫、F 牵着遛"
	if GameTheme.touch_ui():
		tip_text = "在校园里点猫摸三次就能领养 · 进宿舍后点猫可以摸它，再到这里牵出门"
	var tip := _label(tip_text, 12, "#5f6f7c")
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(tip)

	_build_rename()


## 改名小窗：只放一个输入框和两个按钮，改完直接回面板。
## 单独一屏而不是行内展开 —— 行内输入框会把整行撑高、按钮挤出去，手机上更难看。
func _build_rename() -> void:
	_dlg_center = CenterContainer.new()
	_dlg_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dlg_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_dlg_center)

	var vs := get_viewport().get_visible_rect().size
	_dlg = PanelContainer.new()
	_dlg.custom_minimum_size = Vector2(minf(vs.x * 0.8, GameTheme.px(420.0)), 0)
	_dlg.add_theme_stylebox_override("panel", _box())
	_dlg_center.add_child(_dlg)

	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		pad.add_theme_constant_override(m, int(GameTheme.px(18.0)))
	for m in ["margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, int(GameTheme.px(14.0)))
	_dlg.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", int(GameTheme.px(10.0)))
	pad.add_child(col)

	_dlg_title = _label("", 16, "#efe4cf", true)
	_dlg_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_dlg_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_dlg_title)

	_dlg_edit = LineEdit.new()
	_dlg_edit.placeholder_text = "最多 %d 个字" % NAME_MAX
	_dlg_edit.max_length = NAME_MAX
	_dlg_edit.custom_minimum_size = Vector2(0, GameTheme.px(38.0))
	_dlg_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dlg_edit.text_submitted.connect(func(_t: String) -> void: _commit_rename())
	col.add_child(_dlg_edit)

	_dlg_msg = _label("", 12, "#e8927c")
	_dlg_msg.visible = false
	col.add_child(_dlg_msg)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", int(GameTheme.px(10.0)))
	col.add_child(hb)
	var save := Button.new()
	save.text = "就这么叫"
	save.focus_mode = Control.FOCUS_NONE
	save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_btn(save, Color(0.22, 0.34, 0.26, 0.75))
	save.pressed.connect(_commit_rename)
	hb.add_child(save)
	var cancel := Button.new()
	cancel.text = "再想想"
	cancel.focus_mode = Control.FOCUS_NONE
	cancel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_btn(cancel, Color(0.20, 0.24, 0.29, 0.55))
	cancel.pressed.connect(_close_rename)
	hb.add_child(cancel)

	_dlg.visible = false


# ---------------------------------------------------------------- 数据
func _pet_list() -> Array:
	if _arena == null or not is_instance_valid(_arena):
		return []
	if not _arena.has_method("pet_info"):
		return []
	return _arena.call("pet_info")


func _rebuild() -> void:
	if _rows == null:
		return
	for c in _rows.get_children():
		c.queue_free()
	var cats := _pet_list()
	_sig = str(cats)          # 刚建完就把签名对齐，别让 _process 再白重建一次
	var maxn := 2
	if _arena != null and is_instance_valid(_arena) and _arena.has_method("pet_capacity"):
		maxn = int(_arena.call("pet_capacity"))
	_head.text = "养了 %d / %d 只" % [cats.size(), maxn]
	_empty.visible = cats.is_empty()
	if cats.is_empty():
		if GameTheme.touch_ui():
			_empty.text = "宿舍里还没有猫。\n在校园里点猫摸三次，就能给它起名字带回家。"
		else:
			_empty.text = "宿舍里还没有猫。\n在校园里走到猫旁边按 E 摸三次，就能给它起名字带回家。"
		return
	for i in cats.size():
		_rows.add_child(_pet_row(cats[i], i))


func _pet_row(info: Variant, i: int) -> Control:
	var d: Dictionary = info if info is Dictionary else {}
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(GameTheme.px(10.0)))

	var chip := ColorChip.new()
	chip.custom_minimum_size = Vector2(GameTheme.px(20.0), GameTheme.px(22.0))
	chip.dark = Color(str(d.get("dark", "3d3445")))
	chip.light = Color(str(d.get("light", "f2eee7")))
	row.add_child(chip)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(GameTheme.px(2.0)))
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(vb)

	var nm := str(d.get("name", "猫咪"))
	var name_l := _label(nm, 15, "#f4ead6", true)
	name_l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	vb.add_child(name_l)

	var pets := int(d.get("pets", 0))
	var skin := str(d.get("skin_name", "猫"))
	vb.add_child(_label("%s · 亲密 %d" % [skin, pets], 12, "#9fb0bd"))

	# 改名：手机/桌面同一颗按钮 —— 名字是「取过就改不动」这件事最容易被吐槽
	var rb := Button.new()
	rb.text = "改名"
	rb.focus_mode = Control.FOCUS_NONE
	rb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_btn(rb, Color(0.20, 0.24, 0.29, 0.55))
	rb.pressed.connect(_open_rename.bind(i, nm))
	row.add_child(rb)

	# 牵着 / 放回：手机上没有 F 键，这是唯一入口，所以必须一直摆在行上
	var leash := bool(d.get("leash", false))
	var lb := Button.new()
	lb.text = "放回" if leash else "牵着"
	lb.focus_mode = Control.FOCUS_NONE
	lb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_style_btn(lb, Color(0.40, 0.31, 0.13, 0.85) if leash else Color(0.18, 0.27, 0.36, 0.70))
	if leash:
		lb.add_theme_color_override("font_color", Color("#ffe0a3"))
	lb.pressed.connect(_toggle_leash.bind(i))
	row.add_child(lb)
	return row


## 打开期间低频比对一次签名：摸猫、换猫、牵/放都会变，变了才重建
func _process(delta: float) -> void:
	if _arena == null or not is_instance_valid(_arena):
		return
	# 改名框跟着软键盘收放（每帧都要看：键盘高度是逐帧长出来的）
	_sync_kb_inset()
	_t += delta
	if _t < REFRESH_SEC:
		return
	_t = 0.0
	var s := str(_pet_list())
	if s == _sig:
		return
	_sig = s
	_rebuild()


## 键盘弹出时把居中容器压到上半屏，输入框才不会被盖住
func _sync_kb_inset() -> void:
	if _dlg_center == null or not is_instance_valid(_dlg_center):
		return
	var want := -_vk_inset() if _dlg.visible else 0.0
	if not is_equal_approx(_dlg_center.offset_bottom, want):
		_dlg_center.offset_bottom = want


# ---------------------------------------------------------------- 改名 / 牵绳
func _open_rename(i: int, cur: String) -> void:
	if _arena == null or not is_instance_valid(_arena):
		return
	_dlg_idx = i
	_dlg_title.text = "给「%s」改个名字" % cur
	_dlg_edit.text = cur
	_dlg_msg.visible = false
	_dlg_msg.text = ""
	_toast.visible = false
	_panel.visible = false
	_dlg.visible = true
	_dlg_edit.grab_focus()
	_dlg_edit.select_all()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_show("")


func _close_rename() -> void:
	_release_keyboard()
	_dlg.visible = false
	_dlg_idx = -1
	if _is_open:
		_panel.visible = true


func _commit_rename() -> void:
	if _arena == null or not is_instance_valid(_arena) or _dlg_idx < 0:
		_close_rename()
		return
	var got := str(_arena.call("pet_rename", _dlg_idx, _dlg_edit.text))
	if got.is_empty():
		# 空名字：原地提示，别把框关了让人重开一次
		_dlg_msg.text = "名字不能是空的"
		_dlg_msg.visible = true
		_dlg_edit.grab_focus()
		return
	_close_rename()
	_rebuild()
	_toast.text = "以后就叫「%s」啦" % got
	_toast.visible = true


func _toggle_leash(i: int) -> void:
	if _arena == null or not is_instance_valid(_arena):
		return
	var msg := str(_arena.call("pet_toggle_leash", i))
	if msg.is_empty():
		return
	_rebuild()
	_toast.text = msg
	_toast.visible = true


func _release_keyboard() -> void:
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_hide()


# ---------------------------------------------------------------- 小工具
## 软键盘挡住的高度（逻辑像素），没弹出来就是 0。只有移动端有软键盘。
## 改名框在屏幕正中，键盘一弹就会压住输入框 —— 把它顶到上半屏去。
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
	sb.border_color = Color("#4a4030")
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
	sb.content_margin_left = GameTheme.px(10.0)
	sb.content_margin_right = GameTheme.px(10.0)
	var vpad := GameTheme.px(9.0 if GameTheme.touch_ui() else 4.0)
	sb.content_margin_top = vpad
	sb.content_margin_bottom = vpad
	return sb
