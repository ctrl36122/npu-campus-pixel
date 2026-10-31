extends CanvasLayer
## 首次启动的使用说明：免责声明 + 隐私说明 + 聊天规则。
##
## 只在第一次进游戏（或说明升版）时弹一次，点「我已知晓」后写进 user://consent.cfg。
## 放 layer 12：压在主 UI(10) 和触屏按钮层(11) 之上，弹窗期间鼠标点不到世界；
## 键盘移动由 online_boot 那边调 _set_local_blocked 一起挡掉。
##
## 文案口径（不要随便改，是照着实际代码写的）：
##   · 玩家 ID 是 user://xgd_uid.cfg 里本机随机生成的，没有账号体系
##   · 服务端只落盘聊天（user://chat_log.json，500 条），IP 不持久化
##   · 素材全部程序绘制，不含校徽

signal accepted

const CONSENT_PATH := "user://consent.cfg"
## 说明有实质改动时 +1，老玩家会重新看到一次
const CONSENT_VERSION := 1

var _font: Font


func _ready() -> void:
	layer = 12
	_font = GameTheme.font()
	if not should_show():
		queue_free()
		return
	_build()


## 该不该弹：没有记录、或记录的版本低于当前版本
func should_show() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CONSENT_PATH) != OK:
		return true
	return int(cfg.get_value("meta", "version", 0)) < CONSENT_VERSION


func _build() -> void:
	var mask := ColorRect.new()
	mask.color = Color(0.02, 0.03, 0.04, 0.88)
	mask.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mask.mouse_filter = Control.MOUSE_FILTER_STOP        # 吃掉所有点击，别穿到世界里
	add_child(mask)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var vs := get_viewport().get_visible_rect().size
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(minf(vs.x * 0.92, 620.0), 0)
	panel.add_theme_stylebox_override("panel", _box())
	center.add_child(panel)

	var pad := MarginContainer.new()
	for m in ["margin_left", "margin_right"]:
		pad.add_theme_constant_override(m, 20)
	for m in ["margin_top", "margin_bottom"]:
		pad.add_theme_constant_override(m, 16)
	panel.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	pad.add_child(col)

	col.add_child(_label("开始之前", 20, "#e8eef2", true))

	# 正文放进滚动区：手机上屏幕矮，内容一屏放不下也不能把按钮顶出去
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, clampf(vs.y * 0.62, 220.0, 575.0))
	col.add_child(scroll)

	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false                  # 滚动交给外面的 ScrollContainer
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_font_override("normal_font", _font)
	body.add_theme_font_override("bold_font", GameTheme.font_bold())
	body.add_theme_font_size_override("normal_font_size", GameTheme.FS_BODY)
	body.add_theme_font_size_override("bold_font_size", GameTheme.FS_BODY)
	body.add_theme_color_override("default_color", Color("#cfd9e2"))
	body.add_theme_constant_override("line_separation", 6)
	body.text = _body_text()
	scroll.add_child(body)

	var ok := Button.new()
	ok.text = "我已阅读并知晓"
	ok.focus_mode = Control.FOCUS_NONE
	ok.custom_minimum_size = Vector2(0, 40)
	ok.add_theme_font_override("font", _font)
	ok.add_theme_font_size_override("font_size", GameTheme.FS_BODY)
	ok.add_theme_color_override("font_color", Color("#8ec5ff"))
	ok.add_theme_stylebox_override("normal", _btn_box(Color(0.24, 0.44, 0.62, 0.30)))
	ok.add_theme_stylebox_override("hover", _btn_box(Color(0.24, 0.44, 0.62, 0.55)))
	ok.add_theme_stylebox_override("pressed", _btn_box(Color(0.24, 0.44, 0.62, 0.75)))
	ok.pressed.connect(_accept)
	col.add_child(ok)


static func _body_text() -> String:
	return "\n".join([
		"[color=#e2b45c]「像素工大」是学生个人制作的校园像素地图，非官方作品。[/color]",
		"",
		"· 与西北工业大学及校内任何机构无关，未获授权，也不代表校方立场。",
		"· 完全免费：没有收费、内购和广告。",
		"· 地图依据 OpenStreetMap 公开数据绘制，建筑位置与细节仅供参考，请以实际校园为准。",
		"· 角色、建筑与场景全部由程序绘制，不含任何校徽或官方标识。",
		"",
		"[color=#8ec5ff]关于你的数据[/color]",
		"",
		"· 不需要账号，不收集手机号、邮箱或实名信息。",
		"· 玩家 ID 由本机随机生成，只用来区分联机中的不同玩家。",
		"· 联机时服务器会保存你自填的昵称和聊天内容（最近 500 条，用于新玩家进入时显示近期对话），不会持久化保存 IP 地址。",
		"· 想删除自己的聊天记录，跟管理员说一声即可。",
		"",
		"[color=#8ec5ff]聊天规则[/color]",
		"",
		"请文明发言。管理员有权删除聊天内容、禁止违规玩家发言。",
	])


func _accept() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("meta", "version", CONSENT_VERSION)
	cfg.save(CONSENT_PATH)
	accepted.emit()
	queue_free()


func _label(text: String, size: int, color: String, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", GameTheme.font_bold() if bold else _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(color))
	return l


## 2px 实线 + 深色底，跟着设置面板那套走
func _box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#0f141a")
	sb.border_color = Color("#31414f")
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
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
	return sb
