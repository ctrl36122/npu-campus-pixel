extends Control
## 手机端操作层：左下虚拟摇杆 + 右下功能键。
##
## 为什么不用 Button 节点：Godot 默认把单指触摸「模拟成鼠标」，只有第一根手指能驱动 GUI。
## 左手摇杆按住时，右手去点按钮就会失效。所以这里全部自己处理 InputEventScreenTouch/Drag，
## 按 finger index 分别跟踪，真正做到多点同时操作。
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
const BTN := 76.0          # 圆形按钮直径
const BTN_RIGHT := 26.0
const BTN_GAP := 18.0

const C_JOY_BG := Color(0.07, 0.10, 0.15, 0.52)
const C_JOY_RING := Color(0.78, 0.82, 0.86, 0.70)
const C_KNOB := Color(0.49, 0.57, 0.67, 0.92)
const C_KNOB_RING := Color(0.91, 0.94, 0.97, 0.85)
const C_BTN_BG := Color(0.075, 0.105, 0.145, 0.82)
const C_BTN_EDGE := Color(0.74, 0.82, 0.90, 0.80)
const C_BTN_TEXT := Color(0.93, 0.97, 1.0, 1.0)

## 右下按钮：从下往上排
const BUTTONS := [
	{"id": "chat", "bottom": 34.0},
	{"id": "map", "bottom": 132.0},
	{"id": "set", "bottom": 230.0},
]

var boot: Node                  # online_boot，用来开地图 / 开设置
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
var _hide_reasons := {}          # 谁要求隐藏按钮（地图 / 大聊天窗），避免两处互相覆盖
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


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE     # 不吃 GUI 事件，全部走 _input
	add_to_group("touch_pad")
	_font = GameTheme.font()
	visible = is_touch_ui()
	set_process_input(visible)
	set_process(visible)
	if visible:
		queue_redraw()
		# 桌面预览（XGD_TOUCH=1）时用鼠标当手指：按住拖就能试摇杆和按钮
		if not OS.has_feature("mobile"):
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
	return Vector2(JOY_LEFT + JOY_R, s.y - JOY_BOTTOM - JOY_R)


func _btn_center(id: String) -> Vector2:
	var s := _viewport_size()
	for b in BUTTONS:
		if b["id"] == id:
			var bottom := float(b["bottom"])
			return Vector2(s.x - BTN_RIGHT - BTN * 0.5, s.y - bottom - BTN * 0.5)
	return Vector2.ZERO


## 命中用半径放大 6px：手指点不准太正常了
func _btn_hit(pos: Vector2) -> String:
	if hide_buttons:
		return ""
	for b in BUTTONS:
		var id := str(b["id"])
		if pos.distance_to(_btn_center(id)) <= BTN * 0.5 + 6.0:
			return id
	return ""


# ---------------------------------------------------------------- 输入
func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			# 第二根手指落下 = 想缩放了：撤销摇杆，进入捏合
			if _touches.size() == 2:
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
	_set_joy(Vector2.ZERO)
	for a in ["move_left", "move_right", "move_up", "move_down", "sprint"]:
		_apply_action(a, false)


func _fire(id: String) -> void:
	if boot == null or not is_instance_valid(boot):
		return
	match id:
		"chat":
			boot.call("touch_open_chat")
		"map":
			boot.call("touch_toggle_map")
		"set":
			boot.call("touch_open_settings")


# ---------------------------------------------------------------- 绘制
func _draw() -> void:
	if not visible:
		return
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
		var down := _btn_finger.values().has(id)
		var rad := BTN * 0.5
		# 硬投影（项目里所有面板都是硬边、无模糊）
		draw_circle(c + Vector2(0, 3), rad, Color(0, 0, 0, 0.38))
		var bg := C_BTN_BG
		var edge := C_BTN_EDGE
		var ink := C_BTN_TEXT
		if down:
			bg = Color(0.20, 0.38, 0.58, 0.90)
			edge = Color(0.72, 0.86, 1.0, 0.85)
			ink = Color(1, 1, 1, 1)
		draw_circle(c, rad, bg)
		draw_arc(c, rad - 1.4, 0.0, TAU, 48, edge, 2.6, true)
		# 内侧一圈暗环 + 顶部高光：让图标和圆边之间有个"凹槽"，不会糊成一块
		draw_arc(c, rad - 5.0, 0.0, TAU, 40, Color(0, 0, 0, 0.22), 1.4, true)
		if not down:
			draw_arc(c, rad - 5.0, PI * 1.12, PI * 1.88, 18, Color(1, 1, 1, 0.13), 1.6, true)
		_draw_btn_icon(id, c, ink)


## 三个图标全部现画：空心气泡 / 折页地图 / 设置滑杆
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
