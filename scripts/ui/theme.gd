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
