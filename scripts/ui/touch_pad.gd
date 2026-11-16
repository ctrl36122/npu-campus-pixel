extends Control
## 操作层：左下虚拟摇杆（仅触屏）+ 右下功能键（触屏与桌面都有）。
##
## 为什么不用 Button 节点：Godot 默认把单指触摸「模拟成鼠标」，只有第一根手指能驱动 GUI。
## 左手摇杆按住时，右手去点按钮就会失效。所以这里全部自己处理 InputEventScreenTouch/Drag，
## 按 finger index 分别跟踪，真正做到多点同时操作。
##
## 桌面端（Windows / macOS）也挂这一层，只是不画摇杆、改用鼠标事件 ——
## 右下角那排圆钮和手机上完全一致，键盘快捷键（M / Tab / P）照旧可用。
##
## 规格参考 tiled 版（sxgd-tiled-vertion/src/engine.js）：
##   摇杆半透明深色圆 + 2px 边 + 硬投影，摇杆头浅色圆，死区 0.18；右下竖排方块按钮。
##   尺寸按 1280×720 的虚拟分辨率等比放大（tiled 版的 128px 是 CSS px，直接搬过来只有屏宽 10%）。

const JOY_R := 88.0            # 摇杆外圈半径（直径 176 ≈ 屏高 24%）
const KNOB_R := 30.0
const DEAD := 0.18             # 死区：小于这个位移算没动
const SPRINT_AT := 0.92        # 推到底自动加速（手机没有 Shift 键）
const JOY_LEFT := 30.0
const JOY_BOTTOM := 34.0
const BTN_TOUCH := 76.0     # 触屏按钮直径（手指得点得准）
const BTN_DESK := 56.0      # 桌面按钮直径（鼠标精确，做小一点不压画面）
const BTN_RIGHT := 26.0
const BTN_BOTTOM := 30.0
const BTN_GAP := 18.0       # 触屏横排间隙
const BTN_LEFT := 14.0      # 桌面竖排：离屏幕左边
const BTN_TOP := 14.0
const BTN_GAP_DESK := 10.0
## 交互键（替代 E）：一块横放的牌子，贴在功能键那一排的正上方。
## 用矩形而不是圆钮有两个原因：一是要写字（写清「这一步是干什么」），
## 二是它就是拇指自然落点上方那一条，方形比圆形更好按、也不容易和圆钮混在一起。
const ACT_W := 158.0
const ACT_H := 68.0
const ACT_GAP := 46.0       # 和下面那排圆钮之间的净空

const C_JOY_BG := Color(0.07, 0.10, 0.15, 0.52)
const C_JOY_RING := Color(0.78, 0.82, 0.86, 0.70)
const C_KNOB := Color(0.49, 0.57, 0.67, 0.92)
const C_KNOB_RING := Color(0.91, 0.94, 0.97, 0.85)
const C_BTN_BG := Color(0.075, 0.105, 0.145, 0.82)
const C_BTN_EDGE := Color(0.74, 0.82, 0.90, 0.80)
const C_BTN_TEXT := Color(0.93, 0.97, 1.0, 1.0)

## 五个按钮，slot 的顺序就是视觉顺序（0 最先）。两个平台摆放不同：
##   触屏：右下角**横排**（右手拇指够得到；竖排到第 3 颗就会压到右上角的小地图）
##   桌面：左上角**竖排**（小一点，鼠标点；不挡下方聊天框，也不挡右上角小地图）
const BUTTONS := [
	{"id": "chat", "slot": 0},
	{"id": "map", "slot": 1},
	{"id": "friend", "slot": 2},
	{"id": "pet", "slot": 3},
	{"id": "set", "slot": 4},
]

var boot: Node                  # online_boot，用来开地图 / 开设置 / 开好友 / 开宠物
## 真正的触屏环境才画摇杆、走 ScreenTouch；桌面只画右下按钮、走鼠标事件
var _touch_mode := false
var _hover_id := ""             # 桌面鼠标悬停的按钮（触屏恒为空）
var _btn_mouse := ""            # 桌面按住中的按钮
var _joy_finger := -1
var _joy_vec := Vector2.ZERO
var _joy_origin := Vector2.ZERO      # 浮动摇杆：手指按下处即圆心
var _joy_active := false
var _touches := {}                   # finger -> 当前位置（判断双指）
var _pinch_prev := 0.0
var _pinch_base_zoom := 1.2
var _pinch_start_dist := 0.0
var _btn_finger := {}           # finger -> button id
var _actions_on := {}           # 当前按下的动作，避免重复 press

var _font: Font
## 大聊天窗展开时把右下三个按钮收起来：它们会和输入框叠在一起，还容易误触
var hide_buttons := false
## 「现在能按 E」——由 Arena 每帧推过来。只有为真时才画交互牌：
## 手机上根本没有 E 键，走到宿舍门口 / 椅子边 / 船边光看提示条点不到。
var interact_on := false
## 牌子上写什么：Arena 按当前提示翻成一个动词（进入 / 坐下 / 躺下 / 离开…）。
## 写字而不是画图标 —— 手机上拇指盖着半个钮，图标那点细节根本看不清。
var interact_label := "交互"
var _hide_reasons := {}          # 谁要求隐藏按钮（地图 / 大聊天窗），避免两处互相覆盖
## 谁在占用触摸（大聊天窗 / 全屏地图）：占用期间整套触摸都不接管，
## 否则点浮层下半部分会落进摇杆判定区，人会一边看面板一边往前走
var _grabbed := {}
var _last_vp := Vector2.ZERO     # 视口尺寸变化时重画（按钮/摇杆都按它算位置）


## 兼容旧调用（大聊天窗）
func set_buttons_hidden(v: bool) -> void:
	set_buttons_hidden_for("chat", v)


## 按「原因」记录：地图和大聊天窗都可能要收起按钮，谁先谁后都不能把对方顶掉
func set_buttons_hidden_for(reason: String, v: bool) -> void:
	if v:
		_hide_reasons[reason] = true
	else:
		_hide_reasons.erase(reason)
	var want := not _hide_reasons.is_empty()
	if want != hide_buttons:
		hide_buttons = want
		queue_redraw()


func is_touch_ui() -> bool:
	return OS.has_feature("mobile") or OS.has_environment("XGD_TOUCH")


## 浮层（大聊天窗 / 全屏地图）打开时交出触摸控制权：期间不接管任何触摸，
## 摇杆与按钮都不响应。按「原因」记账，两个浮层互不影响。
func set_touch_grabbed_for(reason: String, v: bool) -> void:
	if v:
		if _grabbed.has(reason):
			return
		_grabbed[reason] = true
		release_all()
		queue_redraw()
	else:
		_grabbed.erase(reason)
		queue_redraw()


func is_touch_grabbed() -> bool:
	return not _grabbed.is_empty()


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE     # 不吃 GUI 事件，全部走 _input
	add_to_group("touch_pad")
	_font = GameTheme.font()
	_touch_mode = is_touch_ui()
	# 桌面也常驻：右下角那排快捷按钮是两侧通用的，只是没有摇杆
	visible = true
	set_process_input(true)
	set_process(true)
	queue_redraw()
	# 桌面预览触屏（XGD_TOUCH=1）时用鼠标当手指：按住拖就能试摇杆和按钮。
	# 纯桌面模式不开这个 —— 否则聊天输入框的点击会被改成触摸事件。
	if _touch_mode and not OS.has_feature("mobile"):
		Input.set_emulate_touch_from_mouse(true)
	# 调试用：XGD_TOUCH_TEST=1 自动推一次摇杆，验证动作映射与角色移动
	if OS.has_environment("XGD_TOUCH_TEST"):
		_auto_test.call_deferred()


func _auto_test() -> void:
	await get_tree().create_timer(3.5).timeout
	var av := _local_avatar()
	var before: Vector2 = av.global_position if av != null else Vector2.ZERO
	_joy_finger = 0
	_joy_origin = _joy_radius_center()
	_joy_active = true
	_update_joy(_joy_origin + Vector2(-JOY_R, -JOY_R))
	print("[touch] 摇杆推左上 → move_left=%s move_up=%s" % [
		Input.is_action_pressed("move_left"), Input.is_action_pressed("move_up")])
	await get_tree().create_timer(1.5).timeout
	var after: Vector2 = av.global_position if av != null and is_instance_valid(av) else Vector2.ZERO
	print("[touch] 1.5 秒位移 = %s（应明显朝左上）" % str(after - before))
	_cancel_joy()
	await get_tree().create_timer(0.3).timeout
	print("[touch] 松开后 move_left=%s（应为 false）" % Input.is_action_pressed("move_left"))
	# 双指捏合
	if av != null and is_instance_valid(av):
		var z0 := float(av.get("_cam_zoom_target"))
		_touches = {5: Vector2(120, 400), 6: Vector2(320, 400)}
		_pinch_start_dist = 200.0
		_pinch_base_zoom = z0
		_touches[5] = Vector2(20, 400)
		_touches[6] = Vector2(620, 400)
		_pinch_update()
		print("[touch] 双指张开 200→600，视距 %s → %s（应变小=看得更远）" % [
			z0, av.get("_cam_zoom_target")])
		_touches.clear()


func _local_avatar() -> Node2D:
	for pl in get_tree().get_nodes_in_group("players"):
		if pl.get("is_local_player") == true:
			return pl
	return null


func _viewport_size() -> Vector2:
	return get_viewport_rect().size


func _joy_radius_center() -> Vector2:
	var s := _viewport_size()
	# 让开刘海与底部手势条：桌面 inset 全 0，位置不变
	var safe := GameTheme.safe_insets(s)
	return Vector2(JOY_LEFT + JOY_R + safe.x, s.y - JOY_BOTTOM - JOY_R - safe.w)


## 当前平台的按钮直径
func _btn_size() -> float:
	return BTN_TOUCH if _touch_mode else BTN_DESK


## Arena 推过来的「现在有可交互对象」+ 这一步到底要做什么（文字）。
## 只在触屏上画 —— 桌面上 E 键就在手边，多一块牌子只会挡画面。
func set_interact_available(v: bool, label := "交互") -> void:
	if not _touch_mode:
		v = false
	label = label.strip_edges()
	if label == "":
		label = "交互"
	var label_changed := label != interact_label
	interact_label = label
	if interact_on == v and not label_changed:
		return
	interact_on = v
	# 藏起来的那一帧如果还有手指压在它上面，把手势一起收掉，免得松手时误触发
	if not v:
		for f in _btn_finger.keys():
			if String(_btn_finger[f]) == "interact":
				_btn_finger.erase(f)
	queue_redraw()


## 交互牌：右下那排圆钮的**正上方、宽向居中**。
## 不贴屏幕角：贴着角时右缘就压在屏幕边上，拇指得往外抠；居中到那排按钮的
## 中线上，正好落在「拇指自然停住」的位置，也不会偏心压住某一颗圆钮。
func _interact_rect() -> Rect2:
	var s := _viewport_size()
	var safe := GameTheme.safe_insets(s)
	var row_top := s.y - BTN_BOTTOM - safe.w - BTN_TOUCH
	var cx := s.x * 0.5
	if _touch_mode and not BUTTONS.is_empty():
		# 用最左/最右两颗圆钮的中心算横排中线（按钮增减都不用改这里）
		cx = (_btn_center(str(BUTTONS[BUTTONS.size() - 1]["id"])).x +
			_btn_center(str(BUTTONS[0]["id"])).x) * 0.5
	return Rect2(cx - ACT_W * 0.5, row_top - ACT_GAP - ACT_H, ACT_W, ACT_H)


func _interact_visible() -> bool:
	return interact_on and not hide_buttons and not is_touch_grabbed()


func _btn_center(id: String) -> Vector2:
	var s := _viewport_size()
	var safe := GameTheme.safe_insets(s)
	var r := _btn_size() * 0.5
	for b in BUTTONS:
		if b["id"] != id:
			continue
		var slot := int(b.get("slot", 0))
		if _touch_mode:
			# 右下横排：最右那颗贴边，往左每颗退一个「直径 + 间隙」
			return Vector2(s.x - BTN_RIGHT - r - safe.z - slot * (_btn_size() + BTN_GAP),
				s.y - BTN_BOTTOM - r - safe.w)
		# 桌面：左上竖排
		return Vector2(BTN_LEFT + r + safe.x, BTN_TOP + r + safe.y + slot * (_btn_size() + BTN_GAP_DESK))
	return Vector2.ZERO


## 命中用半径放大 6px：手指点不准太正常了
func _btn_hit(pos: Vector2) -> String:
	if hide_buttons:
		return ""
	# 交互牌先判：它在圆钮上方、命中框还向外放宽 8px，重叠时该它赢
	if _interact_visible() and _interact_rect().grow(8.0).has_point(pos):
		return "interact"
	var r := _btn_size() * 0.5 + 6.0
	for b in BUTTONS:
		if pos.distance_to(_btn_center(str(b["id"]))) <= r:
			return str(b["id"])
	return ""


# ---------------------------------------------------------------- 输入
func _input(event: InputEvent) -> void:
	if not visible or is_touch_grabbed():
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			# 第二根手指落下 = 想缩放了：撤销摇杆，进入捏合
			if _touches.size() == 2:
				# 例外：第二根手指落在按钮上 —— 那是「左手推着摇杆、右手去按交互」，
				# 手机端最常见的操作。当成捏合的话摇杆会被撤掉、按钮也按不动，
				# 于是走到宿舍门口按交互永远没反应。按钮优先，捏合只留给两指都在空白处。
				var hit2 := _btn_hit(event.position)
				if hit2 != "":
					_btn_finger[event.index] = hit2
					_fire(hit2)
					queue_redraw()
					return
				_cancel_joy()
				_pinch_start_dist = _two_dist()
				_pinch_prev = _pinch_start_dist
				var av := _local_avatar()
				if av != null and av.get("_cam_zoom_target") != null:
					_pinch_base_zoom = float(av.get("_cam_zoom_target"))
				queue_redraw()
			elif _touches.size() == 1:
				_on_touch_down(event.index, event.position)
		else:
			_touches.erase(event.index)
			if _touches.size() < 2:
				_pinch_prev = 0.0
				_pinch_start_dist = 0.0
			_on_touch_up(event.index)
	elif event is InputEventScreenDrag:
		_touches[event.index] = event.position
		if _touches.size() >= 2:
			_pinch_update()
		elif event.index == _joy_finger:
			_update_joy(event.position)
	elif not _touch_mode:
		_mouse_input(event)


func _on_touch_down(finger: int, pos: Vector2) -> void:
	# 按钮优先（它们在摇杆区域之外，顺序无关，但先在按钮上判定更直观）
	var hit := _btn_hit(pos)
	if hit != "":
		_btn_finger[finger] = hit
		_fire(hit)
		queue_redraw()
		return
	# 浮动摇杆：左下这块区域随便按，按下处就是圆心（不用去对准那个圈子）
	if _in_joy_zone(pos):
		_joy_finger = finger
		_joy_origin = pos
		_joy_active = true
		_joy_vec = Vector2.ZERO
		queue_redraw()


func _on_touch_up(finger: int) -> void:
	if finger == _joy_finger:
		_cancel_joy()
		return
	if _btn_finger.has(finger):
		_btn_finger.erase(finger)
		queue_redraw()


## 桌面：左键点击圆钮 = 按下并立刻触发（和触屏一致）；移动只更新 hover 高亮。
## 只处理命中按钮的事件，其余原样放过 —— 否则会吃掉聊天框、设置面板的点击。
func _mouse_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			var hit := _btn_hit(mb.position)
			if hit.is_empty():
				return
			_btn_mouse = hit
			_fire(hit)
			queue_redraw()
			get_viewport().set_input_as_handled()
		elif not _btn_mouse.is_empty():
			_btn_mouse = ""
			queue_redraw()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var id := _btn_hit((event as InputEventMouseMotion).position)
		if id != _hover_id:
			_hover_id = id
			queue_redraw()


func _in_joy_zone(pos: Vector2) -> bool:
	var s := _viewport_size()
	return pos.x < s.x * 0.55 and pos.y > s.y * 0.38


func _cancel_joy() -> void:
	_joy_finger = -1
	_joy_active = false
	_set_joy(Vector2.ZERO)
	queue_redraw()


## 双指捏合：按两指间距的变化直接改相机视距
func _two_dist() -> float:
	var ps: Array = _touches.values()
	if ps.size() < 2:
		return 0.0
	return (ps[0] as Vector2).distance_to(ps[1] as Vector2)


func _pinch_update() -> void:
	var d := _two_dist()
	if _pinch_start_dist < 8.0 or d < 8.0:
		return
	var av := _local_avatar()
	if av == null:
		return
	var target: float = _pinch_base_zoom * (d / _pinch_start_dist)
	target = clampf(target, 0.55, 3.0)
	if absf(target - float(av.get("_cam_zoom_target"))) > 0.005:
		av.set("_cam_zoom_target", snappedf(target, 0.01))
	_pinch_prev = d


func _update_joy(pos: Vector2) -> void:
	var d := pos - _joy_origin
	if d.length() > JOY_R:
		d = d.normalized() * JOY_R
	var v := d / JOY_R
	if v.length() < DEAD:
		v = Vector2.ZERO
	_set_joy(v)
	queue_redraw()


func _set_joy(v: Vector2) -> void:
	_joy_vec = v
	_apply_action("move_left", v.x < -0.28)
	_apply_action("move_right", v.x > 0.28)
	_apply_action("move_up", v.y < -0.28)
	_apply_action("move_down", v.y > 0.28)
	_apply_action("sprint", v.length() >= SPRINT_AT)


func _apply_action(action: String, on: bool) -> void:
	if bool(_actions_on.get(action, false)) == on:
		return
	_actions_on[action] = on
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)


## 摇杆归零 + 松开所有动作（切场景、打开聊天时别让角色一直跑）
func release_all() -> void:
	_joy_finger = -1
	_btn_finger.clear()
	_btn_mouse = ""
	_hover_id = ""
	_set_joy(Vector2.ZERO)
	for a in ["move_left", "move_right", "move_up", "move_down", "sprint"]:
		_apply_action(a, false)


func _fire(id: String) -> void:
	if boot == null or not is_instance_valid(boot):
		return
	match id:
		"interact":
			# 和大聊天窗一样走 boot 转发，最终落到 Arena._try_interact()，
			# 与 E 键、与头顶提示条点按是同一条链路（优先级、节流都在那一处）
			boot.call("touch_interact")
		"chat":
			boot.call("touch_open_chat")
		"map":
			boot.call("touch_toggle_map")
		"friend":
			boot.call("touch_toggle_friends")
		"pet":
			boot.call("touch_toggle_pets")
		"set":
			boot.call("touch_open_settings")


# ---------------------------------------------------------------- 绘制
func _draw() -> void:
	if not visible:
		return
	# 摇杆只在触屏上出现；桌面用 WASD，右下角只留按钮
	if _touch_mode:
		# 摇杆：未按下时只在默认位置留一个淡淡的提示圈（告诉新手「这块能按」）
		if _joy_active:
			var c := _joy_origin
			draw_circle(c, JOY_R, C_JOY_BG)
			draw_arc(c, JOY_R, 0.0, TAU, 48, C_JOY_RING, 2.0, true)
			var knob := c + _joy_vec * JOY_R
			draw_circle(knob, KNOB_R, C_KNOB)
			draw_arc(knob, KNOB_R, 0.0, TAU, 32, C_KNOB_RING, 2.0, true)
		else:
			var hint := _joy_radius_center()
			draw_circle(hint, JOY_R * 0.86, Color(0.07, 0.10, 0.15, 0.20))
			draw_arc(hint, JOY_R * 0.86, 0.0, TAU, 40, Color(0.80, 0.84, 0.88, 0.22), 2.0, true)

	# 按钮：圆形 + 程序绘制的图标（和左侧摇杆同一套语言，不用素材）
	for b in BUTTONS:
		if hide_buttons:
			break
		var id := str(b["id"])
		var c := _btn_center(id)
		var down: bool = _btn_finger.values().has(id) or _btn_mouse == id
		var hot := _hover_id == id
		var rad := _btn_size() * 0.5
		# 硬投影（项目里所有面板都是硬边、无模糊）
		draw_circle(c + Vector2(0, 3), rad, Color(0, 0, 0, 0.38))
		var bg := C_BTN_BG
		var edge := C_BTN_EDGE
		var ink := C_BTN_TEXT
		if down:
			bg = Color(0.20, 0.38, 0.58, 0.90)
			edge = Color(0.72, 0.86, 1.0, 0.85)
			ink = Color(1, 1, 1, 1)
		elif hot:
			bg = Color(0.12, 0.18, 0.25, 0.92)
			edge = Color(0.86, 0.92, 0.98, 0.95)
			ink = Color(1, 1, 1, 1)
		draw_circle(c, rad, bg)
		draw_arc(c, rad - 1.4, 0.0, TAU, 48, edge, 2.6, true)
		# 内侧一圈暗环 + 顶部高光：让图标和圆边之间有个"凹槽"，不会糊成一块
		draw_arc(c, rad - 5.0, 0.0, TAU, 40, Color(0, 0, 0, 0.22), 1.4, true)
		if not down:
			draw_arc(c, rad - 5.0, PI * 1.12, PI * 1.88, 18, Color(1, 1, 1, 0.13), 1.6, true)
		# 图标是按 76px 的圆画的，桌面 56px 时整体缩放，免得贴着边
		var sc := _btn_size() / BTN_TOUCH
		if is_equal_approx(sc, 1.0):
			_draw_btn_icon(id, c, ink)
		else:
			draw_set_transform(c, 0.0, Vector2(sc, sc))
			_draw_btn_icon(id, Vector2.ZERO, ink)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	# 交互牌最后画（盖在圆钮之上）：暖橙色，和深蓝的功能键区分开，
	# 让它在「能按」的那几秒里一眼就能找到。
	if _interact_visible():
		_draw_interact_plate()


## 交互牌：一块暖橙色实心矩形 + 正中两个字（进入 / 坐下 / 离开…）。
## 硬边 + 2.5px 描边 + 3px 投影，跟画面里其它像素 UI 一套规矩，不做圆角。
## 文字而不是图标：手机上拇指盖住半个钮，图标那点细节等于没有；
## 而「这一步要干什么」直接写出来，比一个抽象图标省一次猜测。
func _draw_interact_plate() -> void:
	var r := _interact_rect()
	var down: bool = _btn_finger.values().has("interact") or _btn_mouse == "interact"
	var bg := Color(0.15, 0.10, 0.04, 0.92)
	var edge := Color(1.0, 0.76, 0.40, 0.94)
	var ink := Color(1.0, 0.89, 0.66, 1.0)
	if down:
		bg = Color(1.0, 0.71, 0.31, 0.96)
		edge = Color(1.0, 0.94, 0.82, 1.0)
		ink = Color(0.12, 0.07, 0.02, 1.0)
	draw_rect(Rect2(r.position + Vector2(0, 3), r.size), Color(0, 0, 0, 0.40))
	draw_rect(r, bg)
	draw_rect(r, edge, false, 2.5)
	if not down:
		# 上沿一道更亮的线：不按时也有一点「牌子」的体积
		draw_rect(Rect2(r.position + Vector2(2.5, 2.5), Vector2(r.size.x - 5.0, 1.5)),
			Color(1, 1, 1, 0.12))
	# 文字：竖直方向用「字身高度的一半」对齐光学中心，不用 size.y*0.5（中文字面偏下）
	var fs := GameTheme.fs(27)
	var tw := _font.get_string_size(interact_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(_font,
		Vector2(r.position.x + (r.size.x - tw) * 0.5,
			r.position.y + r.size.y * 0.5 + float(fs) * 0.36),
		interact_label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)


## 五个图标全部现画：空心气泡 / 折页地图 / 双人 / 猫头 / 设置滑杆
func _draw_btn_icon(id: String, c: Vector2, col: Color) -> void:
	var hole := Color(0.045, 0.065, 0.095, 0.95)
	match id:
		"chat":
			# 空心气泡 + 小尾巴 + 三个点
			var w := 31.0
			var h := 21.0
			var tl := c + Vector2(-w * 0.5, -h * 0.82)
			draw_rect(Rect2(tl, Vector2(w, h)), col, false, 2.4)
			var tail := PackedVector2Array([
				tl + Vector2(7.0, h),
				tl + Vector2(15.0, h),
				tl + Vector2(7.0, h + 8.0),
			])
			draw_polyline(PackedVector2Array([tail[0], tail[1], tail[2], tail[0]]), col, 2.2, true)
			for i in 3:
				draw_circle(tl + Vector2(w * 0.30 + i * w * 0.20, h * 0.5), 2.3, col)
		"map":
			# 折页地图：三条竖带，中间那条压暗当折痕，再点一个定位点
			for i in 3:
				var bx := c.x - 16.0 + i * 11.0
				var bias := -2.5 if i == 1 else 2.0
				var col_i := col
				if i == 1:
					col_i = Color(col.r, col.g, col.b, 0.62)
				draw_rect(Rect2(Vector2(bx, c.y - 11.0 + bias), Vector2(8.0, 21.0)), col_i, true)
			# 定位针
			draw_circle(c + Vector2(0, 0), 4.4, hole)
			draw_circle(c + Vector2(0, 0), 2.6, col)
		"friend":
			# 两个人：后面那个半透明、小一点、靠左上；前面实心压在上面
			var back := Color(col.r, col.g, col.b, 0.42)
			draw_circle(c + Vector2(-5.6, -8.0), 4.0, back)
			draw_arc(c + Vector2(-5.6, 11.6), 7.0, PI, TAU, 18, back, 2.2, true)
			draw_circle(c + Vector2(4.6, -5.4), 4.6, col)
			draw_arc(c + Vector2(4.6, 14.0), 7.8, PI, TAU, 20, col, 2.4, true)
		"pet":
			# 猫头剪影：圆脸 + 两只三角耳 + 两只眼睛（用背景色抠出）
			draw_circle(c + Vector2(0.0, 2.5), 8.6, col)
			draw_colored_polygon(PackedVector2Array([
				c + Vector2(-8.4, -1.5), c + Vector2(-7.6, -11.5), c + Vector2(-1.4, -5.0),
			]), col)
			draw_colored_polygon(PackedVector2Array([
				c + Vector2(8.4, -1.5), c + Vector2(7.6, -11.5), c + Vector2(1.4, -5.0),
			]), col)
			draw_circle(c + Vector2(-3.2, 1.2), 1.5, hole)
			draw_circle(c + Vector2(3.2, 1.2), 1.5, hole)
		"set":
			# 三条滑杆：线更粗、滑块更大、位置错开
			for i in 3:
				var y := c.y - 9.5 + i * 9.5
				draw_line(Vector2(c.x - 15.0, y), Vector2(c.x + 15.0, y), col, 2.8)
				var kx := c.x + (-6.0 if i == 0 else (5.0 if i == 1 else -2.0))
				draw_circle(Vector2(kx, y), 4.4, hole)
				draw_circle(Vector2(kx, y), 3.4, col)


## 视口尺寸变了（横竖屏切换、窗口缩放）要重画：摇杆和按钮的位置都是按视口尺寸算的。
## 平时不逐帧重画，只有输入事件里才 queue_redraw，省一次全屏绘制。
func _process(_delta: float) -> void:
	var vs := _viewport_size()
	if vs != _last_vp:
		_last_vp = vs
		queue_redraw()
