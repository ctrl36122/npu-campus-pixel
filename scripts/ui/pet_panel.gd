extends CanvasLayer
## 宠物面板：看看宿舍里养的猫 —— 名字、花色、亲密度、是不是正牵在手上。
##
## 数据全部来自 Arena.pet_info()（它读 user://adopted_cats.json 与当前牵绳状态），
## 这里只负责画，不做任何裁定。面板打开期间低频轮询一次，摸猫 / 换猫 / 牵绳
## 的状态变化会立刻反映出来，不用手动刷新。
##
## 快捷键：右下角「宠」按钮（和手机同一套按钮层），Esc 关闭。

signal opened
signal closed

const REFRESH_SEC := 0.4

var _font: Font
var _mask: ColorRect
var _panel: PanelContainer
var _rows: VBoxContainer
var _empty: Label
var _head: Label
var _is_open := false
var _arena: Node = null
var _t := 0.0
var _sig := ""


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
	_t = 0.0
	_sig = ""
	_rebuild()
	set_process(true)
	opened.emit()


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	_mask.visible = false
	_panel.visible = false
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

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var vs := get_viewport().get_visible_rect().size
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(minf(vs.x * 0.86, GameTheme.px(440.0)), 0)
	_panel.add_theme_stylebox_override("panel", _box())
	center.add_child(_panel)

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

	col.add_child(HSeparator.new())
	var tip_text := "校园里找到猫按 E 摸三次就能领养 · 宿舍里按 E 摸猫、F 牵着遛"
	if GameTheme.touch_ui():
		tip_text = "在校园里点猫摸三次就能领养 · 进宿舍后点猫可以摸它"
	var tip := _label(tip_text, 12, "#5f6f7c")
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(tip)


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
	vb.add_child(_label("%s" % nm, 15, "#f4ead6", true))

	var pets := int(d.get("pets", 0))
	var skin := str(d.get("skin_name", "猫"))
	vb.add_child(_label("%s · 亲密 %d" % [skin, pets], 12, "#9fb0bd"))

	var leash := bool(d.get("leash", false))
	var st := _label("牵着遛弯" if leash else "在窝里", 12,
		"#ffd479" if leash else "#7f8f9c")
	st.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(st)
	return row


## 打开期间低频比对一次签名：摸猫、换猫、牵/放都会变，变了才重建
func _process(delta: float) -> void:
	if _arena == null or not is_instance_valid(_arena):
		return
	_t += delta
	if _t < REFRESH_SEC:
		return
	_t = 0.0
	var s := str(_pet_list())
	if s == _sig:
		return
	_sig = s
	_rebuild()


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
