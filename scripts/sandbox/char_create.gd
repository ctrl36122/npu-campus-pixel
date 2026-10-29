extends CanvasLayer
## 角色创建界面（进入游戏前的模态弹窗）
##
## 流程：启动 → 显示本界面（玩家锁住不能动）→ 选外观 + 填昵称 → 点「进入校园」
##       → 界面消失、玩家解锁。游戏中按 C 可以重新打开。
##
## Phase 2 联机时，_confirm() 拿到的 hero_id / display_name 就是加入会话时要上报的字段。

const HeroDB := preload("res://scripts/sandbox/hero_db.gd")

@export var player_path: NodePath = ^"../Player"

var _player: Node2D
var _root: Control
var _preview: AnimatedSprite2D
var _name_edit: LineEdit
var _hint: Label
var _cards: Array[Control] = []
var _cur := "adam"


func _ready() -> void:
	layer = 10
	_player = get_node_or_null(player_path)
	_build()
	open()


# ---------------------------------------------------------------- 开关
func open() -> void:
	_root.visible = true
	if _player != null:
		_player.call("set_locked", true)
	if _name_edit.text.strip_edges() == "":
		_name_edit.grab_focus()


func close() -> void:
	_root.visible = false
	if _player != null:
		_player.call("set_locked", false)


func is_open() -> bool:
	return _root != null and _root.visible


# ---------------------------------------------------------------- 界面
func _build() -> void:
	var f := GameTheme.font()

	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.04, 0.06, 0.09, 0.78)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(700, 424)
	panel.offset_left = -350.0
	panel.offset_right = 350.0
	panel.offset_top = -212.0
	panel.offset_bottom = 212.0
	_root.add_child(panel)

	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		pad.add_theme_constant_override(m, 24)
	pad.add_theme_constant_override("margin_top", 16)
	pad.add_theme_constant_override("margin_bottom", 16)
	panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	pad.add_child(col)

	var title := Label.new()
	title.text = "创建你的角色"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", GameTheme.font_bold())
	title.add_theme_font_size_override("font_size", GameTheme.FS_TITLE + 1)
	col.add_child(title)

	# ---------- 主体：左预览 / 右角色卡 ----------
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 20)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)

	# 左：预览框（固定尺寸，角色站在框底）
	var frame := PanelContainer.new()
	frame.custom_minimum_size = Vector2(150, 214)
	frame.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	body.add_child(frame)
	var stage := Control.new()
	stage.custom_minimum_size = Vector2(150, 214)
	frame.add_child(stage)

	_preview = AnimatedSprite2D.new()
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_preview.scale = Vector2(2, 2)              # 32×48 → 64×96
	_preview.position = Vector2(75, 196)
	stage.add_child(_preview)

	# 右：四张扁平角色卡（图标 + 名字）
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	body.add_child(right)

	var pick_lbl := Label.new()
	pick_lbl.text = "选择外观"
	pick_lbl.add_theme_font_override("font", f)
	pick_lbl.add_theme_font_size_override("font_size", 14)
	pick_lbl.add_theme_color_override("font_color", Color(0.78, 0.82, 0.78))
	right.add_child(pick_lbl)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	right.add_child(bar)

	for i in HeroDB.HEROES.size():
		var hero = HeroDB.HEROES[i]
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 2)
		bar.add_child(card)

		var btn := Button.new()
		btn.flat = true                          # 扁平：只显示角色本身，不要大黑框
		btn.custom_minimum_size = Vector2(72, 108)
		btn.icon = _portrait(str(hero["sheet"]))
		btn.expand_icon = true
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_select.bind(str(hero["id"])))
		card.add_child(btn)

		_cards.append(card)

	# ---------- 昵称 ----------
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	col.add_child(name_row)

	var name_lbl := Label.new()
	name_lbl.text = "昵称"
	name_lbl.add_theme_font_override("font", f)
	name_lbl.add_theme_font_size_override("font_size", 15)
	name_row.add_child(name_lbl)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "输入昵称（最多 12 字）"
	_name_edit.max_length = 12
	_name_edit.custom_minimum_size = Vector2(240, 32)
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.add_theme_font_override("font", f)
	_name_edit.add_theme_font_size_override("font_size", 15)
	_name_edit.text_submitted.connect(func(_t): _confirm())
	name_row.add_child(_name_edit)

	var go := Button.new()
	go.text = "进入校园"
	go.custom_minimum_size = Vector2(140, 38)
	go.add_theme_font_override("font", f)
	go.add_theme_font_size_override("font_size", 16)
	go.pressed.connect(_confirm)
	name_row.add_child(go)

	_hint = Label.new()
	_hint.custom_minimum_size = Vector2(0, 18)
	_hint.add_theme_font_override("font", f)
	_hint.add_theme_font_size_override("font_size", 13)
	_hint.add_theme_color_override("font_color", Color(0.88, 0.38, 0.34))
	col.add_child(_hint)

	_select("adam")


func _portrait(sheet_path: String) -> AtlasTexture:
	var at := AtlasTexture.new()
	at.atlas = load(sheet_path)
	at.region = Rect2(HeroDB.PORTRAIT_FRAME * HeroDB.FRAME_W, 0, HeroDB.FRAME_W, HeroDB.FRAME_H)
	at.filter_clip = true
	return at


# ---------------------------------------------------------------- 交互
func _select(id: String) -> void:
	var hero = HeroDB.by_id(id)
	if hero.is_empty():
		return
	_cur = id
	_preview.sprite_frames = load(str(hero["frames"]))
	_preview.animation = &"down_walk"
	_preview.play()
	for i in _cards.size():
		var on: bool = str(HeroDB.HEROES[i]["id"]) == id
		_cards[i].modulate = Color(1, 1, 1, 1) if on else Color(0.42, 0.46, 0.44, 1)


func _confirm() -> void:
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		_hint.text = "请先填写昵称"
		_name_edit.grab_focus()
		return
	_hint.text = ""
	if _player != null:
		_player.call("set_hero", _cur)
		_player.call("set_display_name", nm)
		print("[角色创建] 外观=", _cur, " 昵称=", nm)
	close()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.keycode == KEY_C and not is_open():
		open()
	elif event.keycode == KEY_ESCAPE and is_open() and _name_edit.text.strip_edges() != "":
		_confirm()
