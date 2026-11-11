class_name GameTheme
## 全局字体与字号：所有 UI 从这里拿，禁止各处自建 SystemFont。
##
## 之前的问题：online_boot / chat / labels / char_create 用的是**不指定字体族**的
## SystemFont（Windows 上回退到宋体），main / launcher / hud 指定了微软雅黑，
## 头顶名牌用 Godot 内置字体——同一个屏幕上同时出现三种字体。
## 现在统一走 apply_root_theme 挂在根窗口上，所有 Control 自动继承。

const FS_TITLE := 20   # 面板大标题（连接卡片、设置面板标题）
const FS_HEAD := 15    # 分区标题 / HUD 主信息
const FS_BODY := 13    # 正文、输入框、按钮、在线名单
const FS_SMALL := 11   # 提示条、次要说明

## 手机 UI 放大倍率。手机竖屏的基准视口是 720×1280（见 online_boot.is_portrait_ui），
## 13px 字号落到 1080 宽的手机屏上只有约 1.2mm 高 —— 按桌面字号做出来的面板
## 在手机上是「框子很大、字很小」。这里统一放大字号与点击区域，桌面端恒为 1.0。
const TOUCH_UI_SCALE := 1.6

static var _ui_scale := 0.0


## 触屏环境（Android/iOS 包，或桌面用 XGD_TOUCH=1 模拟）
static func touch_ui() -> bool:
	return OS.has_feature("mobile") or OS.has_environment("XGD_TOUCH")


## 当前 UI 缩放倍率。XGD_UI_SCALE 可覆盖（调试 / 截图核对用）。
static func ui_scale() -> float:
	if _ui_scale <= 0.0:
		_ui_scale = 1.0
		if OS.has_environment("XGD_UI_SCALE"):
			var raw := OS.get_environment("XGD_UI_SCALE").strip_edges()
			if raw.is_valid_float():
				_ui_scale = clampf(raw.to_float(), 0.5, 3.0)
		elif touch_ui():
			_ui_scale = TOUCH_UI_SCALE
	return _ui_scale


## 字号：所有 add_theme_font_size_override 都过这一层，别再写死数字。
static func fs(base: int) -> int:
	return maxi(1, roundi(float(base) * ui_scale()))


## 尺寸（内边距、行高、图标块）：和字号同一倍率才不会「字大了框没大」。
static func px(v: float) -> float:
	return v * ui_scale()


## 焦点在文本输入里：全局快捷键一律让路。
## Godot 在中文输入法组合期不一定替 LineEdit 吃掉按键，事件会继续穿到各个
## _unhandled_input —— 于是打个「m」就呼出全屏地图、打个「e」就顺手摸猫。
## 这里只看焦点归属，不猜 IME 状态，桌面 / 手机都成立。
static func is_typing(vp: Viewport) -> bool:
	if vp == null:
		return false
	var f := vp.gui_get_focus_owner()
	if not (f is LineEdit or f is TextEdit):
		return false
	# 面板收起后焦点偶尔还挂在隐藏的输入框上（设置 / 领养 / 写公告 / 聊天都可能）。
	# 不能让一个看不见的输入框把整局的 M / Tab / E / F 全锁死。
	return (f as Control).is_visible_in_tree()


## 移动冻结：按「来源」记数，别再让多个面板抢同一个 bool。
## 以前 chat / online_boot 各自直接写 PlayerAvatar.ui_blocked：
##   · 打开全屏地图置 true，聊天收起又被写回 false（或反过来互相清掉）；
##   · 某个置 true 的分支漏了置 false，那个 true 就永远留着 —— 人在校园里
##     忽然一步都动不了，看着像掉进碰撞体，其实和碰撞完全无关。
## 现在每个面板只管自己那一位，is_move_blocked() 汇总；带 node 的来源在面板
## 隐藏 / 节点销毁时自动失效，等于给「关闭事件没来」再加一层兜底。
static var _move_blocks: Dictionary = {}


static func set_move_blocked(source: String, on: bool, node: Node = null) -> void:
	if on:
		_move_blocks[source] = weakref(node) if node != null else null
	else:
		_move_blocks.erase(source)


static func is_move_blocked() -> bool:
	for src in _move_blocks.keys():
		var w: Variant = _move_blocks[src]
		if w == null:
			continue
		var n: Variant = w.get_ref()
		if n == null or not (n is Node) or not (n as Node).is_visible_in_tree():
			_move_blocks.erase(src)
	return not _move_blocks.is_empty()


static func clear_move_blocks() -> void:
	_move_blocks.clear()


## 系统安全区（状态栏 / 刘海 / 底部手势条）换算成视口逻辑像素。
## 桌面恒为 0，所以加了 inset 也不会改变桌面布局；返回 (left, top, right, bottom)。
static func safe_insets(vp_size: Vector2) -> Vector4:
	if not OS.has_feature("mobile"):
		return Vector4.ZERO
	var ws := Vector2(DisplayServer.window_get_size())
	if ws.x <= 0.0 or ws.y <= 0.0 or vp_size.x <= 0.0 or vp_size.y <= 0.0:
		return Vector4.ZERO
	var sa := DisplayServer.get_display_safe_area()
	var kx := vp_size.x / ws.x
	var ky := vp_size.y / ws.y
	return Vector4(
		maxf(0.0, float(sa.position.x) * kx),
		maxf(0.0, float(sa.position.y) * ky),
		maxf(0.0, float(ws.x - (sa.position.x + sa.size.x)) * kx),
		maxf(0.0, float(ws.y - (sa.position.y + sa.size.y)) * ky))


## 手机竖屏顶部时间条 + 间隙占的高度。聊天小窗要整体让到它下面，
## 不然两个半透明黑框会叠成一团（桌面没有这条占位，返回 0）。
static func top_hud_reserve() -> float:
	return px(46.0) if touch_ui() else 0.0

static var _font: SystemFont
static var _font_bold: SystemFont


## 常规字体。字体族按优先级排，跨平台都能落到一个黑体系。
static func font() -> SystemFont:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray([
			"Microsoft YaHei UI", "Microsoft YaHei",
			"PingFang SC", "Noto Sans CJK SC", "Source Han Sans SC", "SimHei"])
		_font.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		_font.hinting = TextServer.HINTING_NORMAL
		# 像素风游戏：禁用亚像素定位，字落在整像素上，小字号不发虚
		_font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	return _font


## 标题用粗体（SystemFont 的 font_weight 生效于支持可变字重的系统字体）。
static func font_bold() -> SystemFont:
	if _font_bold == null:
		_font_bold = font().duplicate()
		_font_bold.font_weight = 700
	return _font_bold


## 挂到根窗口：之后所有 Label / Button / LineEdit 不写 override 也用这套字体。
static func apply_root_theme(root: Window) -> void:
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = fs(FS_BODY)
	root.theme = t
