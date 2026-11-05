extends Node2D
## 校园小猫 —— 直接播放 Aichan_owo 的 Oreo Cat 原始 sprite sheet，**不再自绘**。
##
## 素材：references/bd01d88b4e94991e/Oreo Cat - Aichan_owo/
##   · Sprite Sheet Cat - Aichan_owo.png  462×766，33×32 一帧，24 行 × 14 列
##   · Cat Animation List.png             24 个动作，编号 1..24 与 sheet 行一一对应
## 工程里 assets/cats/oreo_cat_sheet.png 是原文件逐字节副本，没有裁剪/改色/重绘。
## 花色变体只靠 cat_tint.gdshader 在运行时给同一张图重新着色，不改原文件。
##
## origin = 脚底中点；由 Wildlife（ground 模式）生成，挂进 Objects 参与 y 排序。

const TS := 8.0             # 格→校园局部像素，和可走网格一致
const SHEET_PATH := "res://assets/cats/oreo_cat_sheet.png"
const TINT_SHADER := "res://assets/cats/cat_tint.gdshader"
const FRAME_W := 33.0
const FRAME_H := 32.0
const FOOT_Y := 27.0        # 帧内脚底位置；跳跃/跑步行的脚本来就更靠上，正好当腾空
const BASE_SCALE := 0.62    # sheet 猫约 20px 高 → 12px 校园局部像素，约为人物一半

const WALK_SPEED := 14.0    # 校园局部像素/秒（campus scale=2 后翻倍显示）
const RUN_SPEED := 32.0
const HOME_RADIUS := 90.0

## row = Cat Animation List 的动作编号（1 起），n = 该行实际帧数，fps = 播放速度。
## 1..3 站↔坐、4..6 站↔睡、7 站立待机、8 吃、9 走、10 跑、
## 12 潜行、14 跳、15 连击。17 起都带纸箱，校园溜达不用。
const ANIMS := {
	"sit_down":   {"row": 1,  "n": 4,  "fps": 8.0},
	"sit":        {"row": 2,  "n": 4,  "fps": 4.0},
	"sit_up":     {"row": 3,  "n": 4,  "fps": 8.0},
	"sleep_down": {"row": 4,  "n": 5,  "fps": 8.0},
	"sleep":      {"row": 5,  "n": 5,  "fps": 3.0},
	"sleep_up":   {"row": 6,  "n": 5,  "fps": 8.0},
	"stand":      {"row": 7,  "n": 5,  "fps": 6.0},
	"eat":        {"row": 8,  "n": 4,  "fps": 6.0},
	"walk":       {"row": 9,  "n": 8,  "fps": 10.0},
	"run":        {"row": 10, "n": 4,  "fps": 12.0},
	"stealth":    {"row": 12, "n": 7,  "fps": 9.0},
	"jump":       {"row": 14, "n": 7,  "fps": 11.0},
	"attack":     {"row": 15, "n": 13, "fps": 12.0},
}

## 花色表：同一张真素材的配色变体。tint=0 即原图（奶牛猫）。
## dark / light 是 shader 的两个端点色，size/speed/doze 保留品种性格差异。
const SKINS := [
	{"name": "奶牛猫", "dark": "3d3445", "light": "f2eee7", "tint": 0.0,
		"size": 1.00, "speed": 1.00, "doze": 0.20},
	{"name": "黑猫", "dark": "211f26", "light": "4a4650", "tint": 0.92,
		"size": 1.00, "speed": 1.10, "doze": 0.20},
	{"name": "白猫", "dark": "c9c6c0", "light": "faf7ef", "tint": 0.95,
		"size": 1.00, "speed": 0.90, "doze": 0.50},
	{"name": "橘猫", "dark": "a85417", "light": "f0c078", "tint": 0.90,
		"size": 1.06, "speed": 1.00, "doze": 0.35},
	{"name": "狸花猫", "dark": "57544c", "light": "b3ac97", "tint": 0.88,
		"size": 1.02, "speed": 1.05, "doze": 0.25},
	{"name": "蓝猫", "dark": "5c6675", "light": "b9c1cc", "tint": 0.92,
		"size": 1.22, "speed": 0.78, "doze": 0.55},
	{"name": "银渐层", "dark": "8e949e", "light": "f0f1ee", "tint": 0.90,
		"size": 1.10, "speed": 0.85, "doze": 0.45},
	{"name": "三花猫", "dark": "6a4022", "light": "f6efe1", "tint": 0.86,
		"size": 0.96, "speed": 1.00, "doze": 0.40},
	{"name": "暹罗猫", "dark": "443329", "light": "efe0c4", "tint": 0.90,
		"size": 1.00, "speed": 1.05, "doze": 0.30},
	{"name": "折耳猫", "dark": "8a7660", "light": "e5d8bf", "tint": 0.88,
		"size": 1.02, "speed": 0.85, "doze": 0.50},
	{"name": "玳瑁猫", "dark": "33291f", "light": "a4642e", "tint": 0.90,
		"size": 0.98, "speed": 1.00, "doze": 0.30},
	{"name": "奶猫", "dark": "7b6b58", "light": "f3e6d2", "tint": 0.85,
		"size": 0.72, "speed": 1.30, "doze": 0.15},
	{"name": "布偶猫", "dark": "6b5a4c", "light": "f6efe6", "tint": 0.90,
		"size": 1.16, "speed": 0.80, "doze": 0.55},
	{"name": "金渐层", "dark": "b08a4a", "light": "f2e2bd", "tint": 0.90,
		"size": 1.08, "speed": 0.88, "doze": 0.42},
	{"name": "蓝白猫", "dark": "6b7686", "light": "f2f1ec", "tint": 0.92,
		"size": 1.02, "speed": 1.00, "doze": 0.30},
	{"name": "橘白猫", "dark": "c46a22", "light": "f8eee0", "tint": 0.92,
		"size": 1.04, "speed": 1.05, "doze": 0.35},
	{"name": "狸白猫", "dark": "565449", "light": "f0ece2", "tint": 0.88,
		"size": 1.00, "speed": 1.12, "doze": 0.22},
	{"name": "烟灰猫", "dark": "3f4149", "light": "9aa0a8", "tint": 0.90,
		"size": 1.00, "speed": 0.95, "doze": 0.38},
	{"name": "奶油猫", "dark": "c8a678", "light": "f8ecd8", "tint": 0.88,
		"size": 0.98, "speed": 0.92, "doze": 0.48},
	{"name": "巧克力猫", "dark": "4a342a", "light": "8a6852", "tint": 0.92,
		"size": 1.02, "speed": 1.00, "doze": 0.32},
	{"name": "银虎斑", "dark": "5f6268", "light": "c9cbd0", "tint": 0.90,
		"size": 1.04, "speed": 1.08, "doze": 0.26},
	{"name": "孟买猫", "dark": "17161a", "light": "2a2830", "tint": 0.95,
		"size": 0.98, "speed": 1.15, "doze": 0.18},
	{"name": "阿比西尼亚", "dark": "8a5a2c", "light": "d9a86a", "tint": 0.90,
		"size": 0.96, "speed": 1.25, "doze": 0.20},
	{"name": "挪威森林", "dark": "5c5142", "light": "ddd0b4", "tint": 0.88,
		"size": 1.24, "speed": 0.82, "doze": 0.40},
]

var home := Vector2.ZERO
var pos := Vector2.ZERO
var target := Vector2.ZERO
var wait := 1.0
var face := 1.0
var moving := false

var anim := "stand"
var anim_t := 0.0
var loop_anim := true
var queued := ""      # 一次性动画播完后接的循环动画
var frame := 0

var _sprite: Sprite2D = null
var _size_k := 1.0
var _speed_k := 1.0
var _doze := 0.3
var _rng := RandomNumberGenerator.new()
var _nav: NavGrid = null     # 可走网格（Arena 传入）；漫游时避开楼和水

## 互动状态（Arena 里按 E 摸猫时调 pet()）
var pet_count := 0
var skin_index := 0          # 在 SKINS 里的下标，领养存档用它还原花色
var _skin_name := "猫咪"
var _pet_t := 0.0            # 被摸后保持坐姿
var _bubble_t := 0.0         # 头顶爱心剩余时间
var _bubble_was := false
var _follow_t := 0.0         # 好感够了，跟着玩家走一小段
var _follow_node: Node2D = null


## 素材可能没随仓库分发（见 assets/cats/ 的授权说明），缺了就别生成猫，别让游戏崩。
static func available() -> bool:
	return ResourceLoader.exists(SHEET_PATH)


## 猫不像玩家有碰撞体，漫游前自己查一下可走网格，别走进楼里或踩到水面。
## 没传网格（比如别的场景单独摆一只）就退回原来的自由走。
func _can_walk(p: Vector2) -> bool:
	if _nav == null:
		return true
	return _nav.is_walkable(Vector2i(int(floor(p.x / TS)), int(floor(p.y / TS))))


func cat_name() -> String:
	return _skin_name


## 摸满 3 次就能领养（Arena 的提示条和 E 键共用这个判定）
func can_adopt() -> bool:
	return pet_count >= 3


## 按 E 摸猫：停下漫游 → 转向玩家 → 坐下 → 冒爱心；摸够 3 次会跟一小段。
## 返回一句反馈给屏幕提示条。
func pet(player: Node2D) -> String:
	pet_count += 1
	_pet_t = 2.2
	_bubble_t = 2.0
	_follow_node = player
	moving = false
	wait = 0.9
	if player != null and is_instance_valid(player):
		face = 1.0 if player.position.x >= pos.x else -1.0
	if pet_count >= 3:
		_follow_t = 8.0
	_play("sit_down", false, "sit")
	match pet_count:
		1: return "喵？"
		2: return "喵～"
		3: return "跟着你走啦！"
		_: return "呼噜呼噜～"


func setup(anchor: Vector2, skin_data: Variant, seed_val: int, nav_data: NavGrid = null) -> void:
	_rng.seed = seed_val
	var skin: Dictionary = SKINS[0] if skin_data is Dictionary else SKINS[0]
	if skin_data is Dictionary:
		skin = skin_data
	_size_k = float(skin.get("size", 1.0))
	_speed_k = float(skin.get("speed", 1.0))
	_doze = float(skin.get("doze", 0.3))
	_skin_name = str(skin.get("name", "猫咪"))
	skin_index = maxi(0, SKINS.find(skin))
	_nav = nav_data
	home = anchor
	# 初始落点也要查可走，别一出生就站在楼影里
	pos = anchor
	# 宿舍里的猫没有 nav，直接趴在窝上，别再随机抖到墙外
	if _nav != null:
		for i in 12:
			var cand := anchor + Vector2(_rng.randf_range(-40.0, 40.0), _rng.randf_range(-24.0, 24.0))
			if _can_walk(cand):
				pos = cand
				break
	position = pos
	_build_sprite(skin)
	_play("stand", true)
	wait = _rng.randf_range(0.5, 2.0)
	scale = Vector2(BASE_SCALE * _size_k * face, BASE_SCALE * _size_k)
	queue_redraw()   # 影子只画一次；之后只有冒爱心时才重绘


func _build_sprite(skin: Dictionary) -> void:
	var tex: Texture2D = load(SHEET_PATH)
	if tex == null:
		return
	_sprite = Sprite2D.new()
	_sprite.texture = tex
	_sprite.region_enabled = true
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Sprite2D 以 region 中心为原点：把帧内 FOOT_Y 那一行挪到节点原点
	_sprite.position = Vector2(0.0, FRAME_H * 0.5 - FOOT_Y)
	var sh: Shader = load(TINT_SHADER)
	if sh != null:
		var mat := ShaderMaterial.new()
		mat.shader = sh
		mat.set_shader_parameter("dark_color", Color(skin.get("dark", "3d3445")))
		mat.set_shader_parameter("light_color", Color(skin.get("light", "f2eee7")))
		mat.set_shader_parameter("tint_strength", float(skin.get("tint", 0.0)))
		_sprite.material = mat
	add_child(_sprite)


func _process(delta: float) -> void:
	_tick_anim(delta)
	_pet_t = maxf(0.0, _pet_t - delta)
	if _bubble_t > 0.0:
		_bubble_t = maxf(0.0, _bubble_t - delta)
		_bubble_was = true
	elif _bubble_was:
		queue_redraw()          # 最后刷一次，把爱心擦掉
		_bubble_was = false
	if _follow_t > 0.0:
		_follow_t = maxf(0.0, _follow_t - delta)

	if _follow_t > 0.0 and _pet_t <= 0.0 and _follow_node != null and is_instance_valid(_follow_node):
		_follow_player(delta)
	elif _pet_t > 0.0:
		moving = false
	elif moving:
		var to := target - pos
		if to.length() < 2.0:
			_arrive()
		else:
			var spd := RUN_SPEED if anim == "run" else WALK_SPEED
			var step := to.normalized() * spd * _speed_k * delta
			if _can_walk(pos + step):
				pos += step
				if absf(step.x) > 0.01:
					face = 1.0 if step.x > 0.0 else -1.0
			else:
				_arrive()   # 撞到楼/水就停下，休息完换个方向再走
	else:
		wait -= delta
		if wait <= 0.0:
			_leave_rest()
	# 兜底：万一还是被挤到障碍格边缘，轻轻拉回自己的活动中心
	if _nav != null and not _can_walk(pos):
		pos = home
	position = pos
	# 原图猫朝右；朝左时整个节点（连同 sprite）镜像
	scale = Vector2(BASE_SCALE * _size_k * face, BASE_SCALE * _size_k)
	if _bubble_t > 0.0:
		queue_redraw()   # 影子是静态的，只有爱心动画需要逐帧重绘


## 好感够了：贴着玩家脚边小跑，离远了会加速追；跟到就原地待机
func _follow_player(delta: float) -> void:
	var goal: Vector2 = (_follow_node as Node2D).position + Vector2(-14.0, 10.0)
	var to := goal - pos
	moving = false
	if to.length() > 3.0:
		if anim != "walk" and anim != "run":
			_play("walk", true)
		var spd := RUN_SPEED if to.length() > 40.0 else WALK_SPEED
		var step := to.normalized() * spd * _speed_k * delta
		if _can_walk(pos + step):
			pos += step
			if absf(step.x) > 0.01:
				face = 1.0 if step.x > 0.0 else -1.0
	elif anim != "stand":
		_play("stand", true)
	wait = 0.5   # 跟随结束后稍等一下再恢复自己溜达


## 一次性动画（起身/趴下/跳/连击）播完自动接循环动画
func _play(a: String, lp: bool, q: String = "") -> void:
	anim = a
	anim_t = 0.0
	loop_anim = lp
	queued = q
	frame = 0
	_set_frame(0)


func _tick_anim(delta: float) -> void:
	anim_t += delta
	var d: Dictionary = ANIMS[anim]
	var n := int(d["n"])
	var f := int(anim_t * float(d["fps"]))
	if f >= n:
		if loop_anim:
			f %= n
		else:
			f = n - 1
			if queued != "":
				var nxt := queued
				_play(nxt, true)
				return
	if f != frame:
		frame = f
		_set_frame(f)


func _set_frame(f: int) -> void:
	if _sprite == null:
		return
	var d: Dictionary = ANIMS[anim]
	var row := int(d["row"])
	_sprite.region_rect = Rect2(float(f) * FRAME_W, float(row - 1) * FRAME_H,
		FRAME_W, FRAME_H)


## 走到目的地：按参考动作表挑一个休息动作，起坐/趴下都带过渡帧
func _arrive() -> void:
	moving = false
	var r := _rng.randf()
	if r < 0.10 + _doze * 0.30:
		_play("sleep_down", false, "sleep")
		wait = _rng.randf_range(5.0, 11.0) * (0.6 + _doze)
	elif r < 0.42:
		_play("sit_down", false, "sit")
		wait = _rng.randf_range(2.5, 6.0)
	elif r < 0.58:
		_play("eat", true)
		wait = _rng.randf_range(2.0, 4.0)
	elif r < 0.70:
		_play("stand", true)
		wait = _rng.randf_range(1.2, 3.0)
	elif r < 0.80:
		_play("jump", false, "stand")
		wait = _rng.randf_range(1.0, 2.0)
	elif r < 0.88:
		_play("attack", false, "stand")
		wait = _rng.randf_range(1.0, 2.0)
	else:
		_play("stealth", true)
		wait = _rng.randf_range(2.0, 4.0)


## 休息结束：坐着/睡着要先播起身帧，再走
func _leave_rest() -> void:
	# 挑一个确实站得住的落点（最多试 8 次），否则猫会一头撞进楼里
	var t := pos
	for i in 8:
		var cand := pos + Vector2(_rng.randf_range(-55.0, 55.0), _rng.randf_range(-35.0, 35.0))
		if cand.distance_to(home) > HOME_RADIUS:
			cand = home + (cand - home).limit_length(60.0)
		if _can_walk(cand):
			t = cand
			break
	target = t
	moving = true
	if anim == "sit":
		_play("sit_up", false, "walk")
	elif anim == "sleep":
		_play("sleep_up", false, "walk")
	elif _rng.randf() < 0.22:
		_play("run", true)
	else:
		_play("walk", true)


func _draw() -> void:
	# 脚下一小片影子（sprite sheet 没有影），跟随节点缩放
	draw_rect(Rect2(-8.0, -0.8, 16.0, 1.6), Color(0.0, 0.0, 0.0, 0.10))
	# 被摸时头顶冒 3 颗像素爱心，边飘边淡出
	if _bubble_t > 0.0:
		var ph := 1.0 - _bubble_t / 2.0
		var c := Color(0.93, 0.32, 0.42, 0.92 * (1.0 - ph * 0.7))
		var y0 := -24.0 - ph * 7.0
		for i in 3:
			var x := -5.0 + float(i) * 5.0 + sin(ph * 5.0 + float(i) * 1.7) * 1.5
			var y := y0 - float(i) * 2.0
			draw_rect(Rect2(x, y, 2.0, 2.0), c)
			draw_rect(Rect2(x + 2.6, y, 2.0, 2.0), c)
			draw_rect(Rect2(x + 0.6, y + 1.6, 4.0, 1.6), c)
			draw_rect(Rect2(x + 1.4, y + 3.0, 2.4, 1.0), c)
