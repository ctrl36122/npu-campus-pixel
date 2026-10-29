extends Node
## 启动菜单 —— 工程的入口场景（F5 直接到这里）
##
## 三个入口共用同一套 autoload（Net / GameState / SessionFlow）。
## 从联机大厅返回主菜单时会先断开连接，避免下次开房时残留上一局的 peer 列表。

const NET_BOOT := "res://net/scenes/NetBoot.tscn"        # 联机大厅（开房 / 加入）
const CAMPUS := "res://scenes/main.tscn"                 # 单机校园大地图（可走动）
const SANDBOX := "res://scenes/sandbox/phase1.tscn"       # 手感沙盒（16px 小地图）

var _hint: Label


func _ready() -> void:
	_build_ui()


# ---------------------------------------------------------------- 界面
func _build_ui() -> void:
	var font := GameTheme.font()

	# 背景
	var bg := ColorRect.new()
	bg.color = Color("#12161c")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	center.add_child(col)

	# 标题
	var title := Label.new()
	title.text = "像素工大"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", font)
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color("#e8eef2"))
	col.add_child(title)

	var sub := Label.new()
	sub.text = "西北工业大学 · 长安校区"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_override("font", font)
	sub.add_theme_font_size_override("font_size", 15)
	sub.add_theme_color_override("font_color", Color("#7f8f9c"))
	col.add_child(sub)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 26)
	col.add_child(gap)

	# 三个入口
	_add_button(col, font, "联机大厅", "开房间或输入 IP 加入（最多 4 人）", _enter.bind(NET_BOOT))
	_add_button(col, font, "单机校园", "整张校园地图，自由行走", _enter.bind(CAMPUS))
	_add_button(col, font, "手感沙盒", "小块测试场地，调动作与比例用", _enter.bind(SANDBOX))

	_hint = Label.new()
	_hint.text = ""
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_override("font", font)
	_hint.add_theme_font_size_override("font_size", 12)
	_hint.add_theme_color_override("font_color", Color("#5f6f7c"))
	col.add_child(_hint)

	# 已连接时给个提示
	if Net.has_session():
		_hint.text = "检测到未断开的联机会话，进入任何场景前会自动断开"


func _add_button(parent: Node, font: Font, text: String, desc: String, cb: Callable) -> void:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(340, 48)
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_override("font", font)
	btn.add_theme_font_size_override("font_size", GameTheme.FS_HEAD + 2)
	# 默认主题在纯深色背景上按钮字偏暗，显式给三态配色才看得清
	btn.add_theme_color_override("font_color", Color("#dce6ee"))
	btn.add_theme_color_override("font_hover_color", Color("#ffffff"))
	btn.add_theme_color_override("font_pressed_color", Color("#a8ccec"))
	btn.add_theme_stylebox_override("normal", _box("#1b2330", "#2f3d4d"))
	btn.add_theme_stylebox_override("hover", _box("#25313f", "#4a86c8"))
	btn.add_theme_stylebox_override("pressed", _box("#16202b", "#3d6d9e"))
	btn.add_theme_stylebox_override("focus", _box("#25313f", "#4a86c8"))
	btn.pressed.connect(cb)
	parent.add_child(btn)

	var d := Label.new()
	d.text = desc
	d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	d.add_theme_font_override("font", font)
	d.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	d.add_theme_color_override("font_color", Color("#66757f"))
	parent.add_child(d)

	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, 8)
	parent.add_child(sp)


## 生成一个扁平圆角方块样式（深色 UI 的按钮底板）
func _box(bg: String, border: String) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(bg)
	sb.border_color = Color(border)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


# ---------------------------------------------------------------- 跳转
func _enter(path: String) -> void:
	# 离开前先清掉残留会话：否则换场景后 Net 里还挂着上一局的 peers
	if Net.has_session() or Net.is_connecting():
		Net.leave_game("返回主菜单")
	var err: int = get_tree().change_scene_to_file(path)
	if err != OK:
		_hint.text = "无法加载场景：%s（错误 %d）" % [path, err]
