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
const RUN_SPEED := 32.0     # 自己溜达时的小跑
const HOME_RADIUS := 90.0
## 牵着走的时候是另一回事：玩家走路就是 110（冲刺 170），猫还用 32 跑就永远追不上。
## 而且**不能贴着人跑**：追到脚下就停、下一帧又被落下，每帧都在「站/跑」之间切换，
## 姿态和位置一起抖，看着就是抽搐。
##
## 以前的写法是「站在人身后 26px 的那个点」—— 一旦猫离人比 26px 更近（玩家一转身
## 走过来就会这样），那个目标点就翻到**猫的身后**去了，猫于是朝**远离人**的方向走，
## 玩家走进 56px/s、猫退开 52px/s，两个速度互相抵消，距离锁死在 16px 反复抖，
## 而猫还在原地「倒着跑」—— 这就是玩家说的抽搐。
## 现在只用一个标量：离人多远。近了就停，远了按比例追，**永远不后退**。
const FOLLOW_NEAR := 20.0   # 缩到这个距离就彻底站住
## 超过这个距离才重新起步。回差要**比跟随稳态的间距更宽**，否则人一走猫就
## 「追到 20px → 站住 → 被落下 → 再追」，走两步停一下，看着一顿一顿的。
## 稳态间距 = FOLLOW_NEAR + 人走路速度/GAIN（56px/s → 28px、110px/s → 36px），
## 都在这个值以内，所以正常走路时它一直匀速跟着，不会走走停停。
const FOLLOW_FAR := 32.0
const FOLLOW_GAIN := 7.0    # 速度 = (离人多远 − FOLLOW_NEAR) × 这个系数
const FOLLOW_MIN := 16.0    # 追起来至少这么快，再慢就不像在跟了
const FOLLOW_MAX := 210.0   # 上限：玩家冲刺 170，留点余量才追得回来
## 跑/走的分界（带 12px/s 回差）：人正常走路约 56px/s，猫跟着的时候应该还是走
const RUN_ANIM := 100.0
const RUN_ANIM_BACK := 86.0
## 直线被楼/水挡住时不能只做「擦墙滑动」：两个切向轮流试，会在墙角原地左右抖，
## 看着就是疯狂抽搐。绕路交给局部 A*（见 _build_local_path）。
const PATH_EVERY := 0.35    # 绕路时多久重算一次路径（每帧算太浪费）
const PATH_RETRY := 1.2     # 算不出路时的退避（别每 0.35 秒重试一次白烧 CPU）
const PATH_SLACK := 24.0    # 目标点挪了这么远就立刻重算
const PATH_REACH := 5.0     # 离路点这么近就算走到了，换下一个
## 只搜猫周围这么多格。整张校园是 424×800 格，用 AStarGrid2D 全图搜一次要 77ms
## （不可达时更惨），每 0.35 秒来一下就是明显卡顿；而猫只需要绕开身边十几格内的楼。
const PATH_CELLS := 26      # 局部搜索半径上限（格）；实际半径按「离目标多远」收窄
## 最多展开这么多格。A* 是朝目标铺的，绕一堵墙通常几十个节点就够；
## 这条只是「到不了」时的止损 —— 真到不了就让上层瞬移，别把整圈搜完（GDScript 很慢）。
const PATH_NODES := 320
const DIRS8: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)]
const STUCK_LIMIT := 1.2    # 一步都挪不动这么久 → 直接落到脚边（不脱离人）
const STUCK_R := 56.0       # 但只有落后超过这么远才值得瞬移（约 7 格），贴着人就别闪
const LOSE_R := 260.0       # 拉这么远又没有可走的路（玩家上船/被关起来）就瞬移
const WARP_GAPS: Array[float] = [20.0, 34.0, 48.0]   # 落地兜底时由近到远找站位

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
var _anim_rate := 1.0        # 行走/跑步的帧率倍率：跟得越快腿要动得越快，不然像滑冰
## 绕路状态：A* 给出的路点队列 + 上次算路的时刻/目标
var _path: Array[Vector2] = []
var _path_goal := Vector2.INF
var _path_t := 0.0
var _path_ok := false        # 上次算路成功了没有：成功后走完要立刻重算，失败就退避
var _chasing := true         # 在追人吗（20↔32 的回差，别站在阈值上每帧来回切）
var _stuck_t := 0.0          # 连续一步没挪的时长
var _block_t := 0.0          # 连续被挡的时长（小于 0.08 秒不换姿势，免得闪）
var _was_pos := Vector2.INF
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

## 只在某个矩形里活动（宿舍单间用）。size 为 0 表示不限制。
## 房间里的猫没有 NavGrid（房间是另一套几何），用这个挡住它们穿墙/出门。
var roam_rect := Rect2()
## 房间里的主人：闲着的时候偶尔走过去蹭一下腿。
var companion: Node2D = null
## 牵着走（带出门遛）：一直跟着，不按时间掉。
var follow_forever := false
var _rub_cd := 6.0           # 下一次「去蹭主人」的冷却

## 头顶名牌（只有被领养的猫才有名字；校园里那 100 只野猫不挂）。
## 标签是 Cat 的子节点，所以猫走、猫转身它都跟着，不用 Arena 每帧去摆。
const TAG_FONT := 11
const TAG_SCALE := 0.42      # 名牌在**父空间**里的缩放：字约 4.6px，猫约 20px 高
const TAG_Y := -34.0         # 标签原点在猫局部坐标的 y（猫头顶约 -27，帧顶还留了几像素空白）
var _tag: Label = null
var _tag_face := 1.0


## 素材可能没随仓库分发（见 assets/cats/ 的授权说明），缺了就别生成猫，别让游戏崩。
static func available() -> bool:
	return ResourceLoader.exists(SHEET_PATH)


## 猫不像玩家有碰撞体，漫游前自己查一下可走网格，别走进楼里或踩到水面。
## 没传网格（比如别的场景单独摆一只）就退回原来的自由走。
func _can_walk(p: Vector2) -> bool:
	if roam_rect.size.x > 0.0 and roam_rect.size.y > 0.0 and not roam_rect.has_point(p):
		return false
	if _nav == null:
		return true
	return _nav.is_walkable(Vector2i(int(floor(p.x / TS)), int(floor(p.y / TS))))


## 牵着走：一直跟在这个节点脚边（带猫出门遛）
func start_follow(n: Node2D) -> void:
	_follow_node = n
	follow_forever = true
	_follow_t = 0.0
	moving = false
	_chasing = true
	_was_pos = Vector2.INF
	_stuck_t = 0.0
	_block_t = 0.0


## 收回牵绳：自己该干嘛干嘛（回窝附近溜达）
func stop_follow() -> void:
	follow_forever = false
	_follow_t = 0.0
	wait = 0.4


func is_following() -> bool:
	return follow_forever


func cat_name() -> String:
	return _skin_name


## 挂一个跟头顶走的名牌（传空串 = 摘掉）。必须在 setup() 之后调：
## 补偿缩放要用 _size_k，花色大小不同，字不能跟着一起变大变小。
func set_display_name(t: String) -> void:
	var txt := t.strip_edges()
	if txt.is_empty():
		if _tag != null and is_instance_valid(_tag):
			_tag.queue_free()
		_tag = null
		return
	if _tag == null or not is_instance_valid(_tag):
		_tag = Label.new()
		_tag.name = "NameTag"
		_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 名字不能挡住点猫
		_tag.add_theme_font_size_override("font_size", GameTheme.fs_fixed(TAG_FONT))
		_tag.add_theme_color_override("font_color", Color("f1e6d2cc"))
		_tag.add_theme_color_override("font_outline_color", Color("1a1410ff"))
		_tag.add_theme_constant_override("outline_size", GameTheme.outline(3))
		add_child(_tag)
	_tag.text = txt
	_sync_tag()
	# 刚建的标签首帧字体度量可能还没算完，等布局定下来再对一次中
	_sync_tag.call_deferred()


## 名字的位置 / 镜像补偿。
## 猫节点自身的 scale.x 带 face 的正负号（朝左时整只翻过来），标签直接挂上去会跟着
## 左右镜像。做法是给标签一个逆缩放：父缩放 s·f × 标签缩放 k/(s·f) = k，
## 名字永远正着写、也永远和猫一样大。朝左时 position.x 也得跟着反号才是居中。
func _sync_tag() -> void:
	if _tag == null or not is_instance_valid(_tag):
		return
	var s := maxf(0.01, BASE_SCALE * _size_k)
	var f := 1.0 if face >= 0.0 else -1.0
	_tag_face = f
	_tag.scale = Vector2(TAG_SCALE / (s * f), TAG_SCALE / s)
	var w: float = _tag.get_minimum_size().x
	_tag.position = Vector2(-w * TAG_SCALE * 0.5 * f / s, TAG_Y)


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
	if _follow_t > 0.0 and not follow_forever:
		_follow_t = maxf(0.0, _follow_t - delta)
	_rub_cd = maxf(0.0, _rub_cd - delta)

	var following := follow_forever or _follow_t > 0.0
	if following and _pet_t <= 0.0 and _follow_node != null and is_instance_valid(_follow_node):
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
		# 房间里的猫：闲着每隔十几秒走过去蹭主人一下，别一直趴着不动
		if (companion != null and _rub_cd <= 0.0 and is_instance_valid(companion)
				and pos.distance_to((companion as Node2D).position) < 150.0):
			_rub_cd = _rng.randf_range(9.0, 18.0)
			_follow_node = companion
			_follow_t = _rng.randf_range(1.6, 3.2)
		else:
			wait -= delta
			if wait <= 0.0:
				_leave_rest()
	# 兜底：万一还是被挤到障碍格边缘，就近找一格站住。
	# **别直接扔回 home** —— 那是一次很显眼的瞬移，卡在墙角时会变成一帧一跳。
	if _nav != null and not _can_walk(pos):
		var fix := _walkable_near(pos)
		pos = fix if fix != Vector2.INF else home
		_clear_path()
	position = pos
	# 原图猫朝右；朝左时整个节点（连同 sprite）镜像
	scale = Vector2(BASE_SCALE * _size_k * face, BASE_SCALE * _size_k)
	# 转身了就把名牌的镜像补偿和居中偏移一起重算（平时只有挂着名牌的猫走这条路）
	if _tag != null and is_instance_valid(_tag) and face != _tag_face:
		_sync_tag()
	if _bubble_t > 0.0:
		queue_redraw()   # 影子是静态的，只有爱心动画需要逐帧重绘


## 好感够了 / 牵出去遛：跟着玩家走，但**不紧贴**（离人近了就站着）。
##
## 只用一个标量「离人有多远」驱动，**永远不后退**：
##   近了（< FOLLOW_NEAR）→ 停；远了 → 按比例追，越远越快。
## 早先是「站在人身后 26px 的那个点」，猫一旦离人比 26px 还近（玩家转身走过来
## 就会这样），目标点就翻到猫背后，猫朝远离人的方向走 —— 玩家 56px/s 逼近、
## 猫 52px/s 退开，距离锁死在 16px 来回抖，猫还一直在原地倒着跑。
##
## 三条路，按顺序挑：
##   1. 到玩家的直线整条能走 → 直接走（最平滑）
##   2. 被楼/水挡住 → 在猫周围跑一次局部 A* 绕过去
##      （**不要**原地左右擦墙，那看着就是疯狂抽搐）
##   3. 连路都没有（玩家上船、被关在围栏里）→ 离得远就直接落到脚边，离得近就站着等
## 另外还有卡住兜底：连着 1.2 秒一步没挪、又落后 56px 以上，直接跟到脚边。
func _follow_player(delta: float) -> void:
	var pn := _follow_node as Node2D
	if pn == null:
		return
	# 掉帧（切场景/加载）时 delta 可能到 1 秒：按它算步长会一步迈 200px（等于瞬移），
	# 按它记「卡住多久」又会立刻触发兜底。统一压到 0.1 秒以内。
	var dt := minf(delta, 0.1)
	var to := pn.position - pos
	var dist := to.length()
	moving = false

	# 拉得实在太远（玩家传送/上船/过河）：直接落到脚边，别让它从 260px 外跑过来。
	# 落不下来（玩家在水面上）就继续按下面的逻辑等着。
	if dist > LOSE_R and _warp_behind(pn.position):
		return

	# 起步/停步留回差：不然猫会站在阈值上每帧在「走 / 站」之间来回切，
	# 那一秒能切十几次，看着就是「闪」。
	if dist > FOLLOW_FAR:
		_chasing = true
	elif dist < FOLLOW_NEAR:
		_chasing = false
	if not _chasing:
		_clear_path()
		_stand()
		return

	# 挑这一步往哪走：
	#   · 到玩家的直线整条都能走 → 直接走（最平滑）
	#   · 中途有楼/水 → 走局部 A* 给的绕路点；有路就一直沿着走，不要一步一改主意
	#   · 算不出路（被围死/玩家在船上）→ 远就落到脚边，近就站着（绝不原地空跑）
	var aim := pn.position
	var blocked := not _line_clear(pos, pn.position)
	if blocked:
		var way := _path_step(pn.position, dt)
		if way == Vector2.INF:
			_clear_path()
			if dist > STUCK_R and _warp_behind(pn.position):
				return
			_stand()
			return
		aim = way
	elif not _path.is_empty():
		# 直线又通了：立刻丢路点回直线。以前这里写成「blocked 或 路点非空」就跑
		# A*，结果算过一次路就再也退不出来 —— 猫一直沿着 8px 网格中心走，
		# 一帧 0.5px、一帧 0.7px，看着就是在原地小碎步抖。
		_clear_path()

	# 速度只看「离人多远」：纯比例控制，没有惯性就不会过冲；
	# 不掺玩家的速度估测 —— 估慢了掉队、估快了冲到人身上，两头都抖。
	var spd := clampf((dist - FOLLOW_NEAR) * FOLLOW_GAIN, FOLLOW_MIN, FOLLOW_MAX)
	var mv := aim - pos
	if mv.length() < 0.5:
		mv = to
	var step := mv.normalized() * spd * dt
	var before := pos
	if _can_walk(pos + step):
		pos += step
		_face_step(step)
	else:
		# 斜着迈会切到墙角（A* 的斜向允许「只有一边能走」，连续移动却会拒绝）。
		# 拆成只走 x / 只走 y 各试一次：贴着墙滑过去，而不是原地干站。
		var sx := Vector2(step.x, 0.0)
		var sy := Vector2(0.0, step.y)
		if absf(step.x) > 0.01 and _can_walk(pos + sx):
			pos += sx
			_face_step(sx)
		elif absf(step.y) > 0.01 and _can_walk(pos + sy):
			pos += sy
			_face_step(step)
	# 只挪了想走的一小半 = 等于没动。贴墙时「只走 x」那条分支会以 0.05px/帧 的速度
	# 慢慢蹭，这一步看着就是原地小碎步，必须按「被挡」处理，别当成在走。
	# 用「相对想走的距离」而不是绝对像素，换个帧率也成立。
	if pos.distance_to(before) < maxf(0.02, step.length() * 0.25):
		# 先按原姿势撑 0.08 秒（几十毫秒内解开就别换姿势），还挪不动就站着 ——
		# 空跑腿比闪一下更难看；卡久了就直接落到脚边，宁可闪一下也不能把人跟丢。
		_block_t += dt
		if _block_t > 0.08:
			_stand()
		if _block_t > STUCK_LIMIT and dist > STUCK_R and _warp_behind(pn.position):
			return
		return
	_block_t = 0.0

	# 卡住兜底：连着 STUCK_LIMIT 秒一步没挪，就落到脚边（宁可闪一下也不能脱离人）
	if _was_pos != Vector2.INF and pos.distance_to(_was_pos) < 0.05:
		_stuck_t += dt
	else:
		_stuck_t = 0.0
	_was_pos = pos
	if _stuck_t > STUCK_LIMIT and dist > STUCK_R and _warp_behind(pn.position):
		return

	# 动作：走 ↔ 跑留一点回差，卡在阈值上时不要每帧来回换
	var run_now := spd > (RUN_ANIM_BACK if anim == "run" else RUN_ANIM)
	var want_anim := "run" if run_now else "walk"
	if anim != want_anim:
		_play(want_anim, true)
	# 腿按实际速度摆，但别加太多：run 那行只有 4 帧 / 12fps，
	# 乘 2 就是 24fps 翻 12px 高的四条腿，看着就是抖。
	_anim_rate = clampf(spd / (RUN_SPEED if want_anim == "run" else WALK_SPEED), 1.0, 1.25)
	wait = 0.5


## 直线 a→b 整条是不是都能走（每 5px 采一个点）。只看一步的探针太短，
## 会让猫在「能走/不能走」之间反复改主意，绕着楼打转。
func _line_clear(a: Vector2, b: Vector2) -> bool:
	var d := b - a
	var n := int(d.length() / 5.0) + 1
	for i in range(1, n + 1):
		if not _can_walk(a + d * (float(i) / float(n))):
			return false
	return true


## 站着待机（不重复播放，免得每帧把 anim_t 归零）
func _stand() -> void:
	if anim != "stand":
		_play("stand", true)
	wait = 0.5


## 转身：竖直方向跟随的时候 step.x 只有极小的正负噪声，按它翻转会让猫左右抖，
## 所以横向分量明显大于纵向噪声时才真的改朝向。
func _face_step(step: Vector2) -> void:
	if absf(step.x) < 0.05:
		return
	if absf(step.x) < absf(step.y) * 0.35:
		return
	face = 1.0 if step.x > 0.0 else -1.0


## 绕路：返回「下一步该朝哪个路点走」，没有路可走返回 Vector2.INF。
## 只在猫周围 PATH_CELLS 格里做 A*（够绕开身边的楼/水），路径每 PATH_EVERY 秒
## 或目标点挪了 PATH_SLACK 才重算一次。
func _path_step(goal: Vector2, delta: float) -> Vector2:
	if _nav == null:
		return Vector2.INF
	_path_t -= delta
	var stale := _path_t <= 0.0 or _path_goal == Vector2.INF \
			or _path_goal.distance_to(goal) > PATH_SLACK \
			or (_path_ok and _path.is_empty())      # 算出来的路走完了：立刻接着算下一段
	if stale:
		_path_goal = goal
		_path = _build_local_path(goal)
		_path_ok = not _path.is_empty()
		_path_t = PATH_EVERY if _path_ok else PATH_RETRY
	# 已经走到的路点丢掉
	while not _path.is_empty() and pos.distance_to(_path[0]) < PATH_REACH:
		_path.pop_front()
	if _path.is_empty():
		return Vector2.INF
	return _path[0]


## 在猫周围 PATH_CELLS 格里跑一次 A*（8 向、不许切墙角），
## 返回一串格心像素路点（不含脚下那一格）。到不了就返回空数组。
## 用 A* 而不是 BFS：BFS 按圈铺开，绕一堵墙还没摸到目标就把节点额度烧光了。
func _build_local_path(goal: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if _nav == null:
		return out
	var start_c := Vector2i(int(floor(pos.x / TS)), int(floor(pos.y / TS)))
	var dst := Vector2i(int(floor(goal.x / TS)), int(floor(goal.y / TS)))
	# 目标格本身踩不住（猫窝在墙里/玩家站在障碍上）→ 就近挪到能站的格
	if not _nav.is_walkable_xy(dst.x, dst.y):
		var alt := Vector2i(-1, -1)
		for ring in range(1, 4):
			for dx in range(-ring, ring + 1):
				for dy in range(-ring, ring + 1):
					if _nav.is_walkable_xy(dst.x + dx, dst.y + dy):
						alt = dst + Vector2i(dx, dy)
						break
				if alt.x >= 0:
					break
			if alt.x >= 0:
				break
		if alt.x < 0:
			return out
		dst = alt
	if start_c == dst:
		return out

	# 半径按「离目标几格」收：目标就在隔壁就别开 26 格的大窗口
	var cells_to_goal := maxi(absi(dst.x - start_c.x), absi(dst.y - start_c.y))
	var rad := clampi(cells_to_goal + 6, 10, PATH_CELLS)
	var lo := Vector2i(start_c.x - rad, start_c.y - rad)
	var hi := Vector2i(start_c.x + rad, start_c.y + rad)
	var span := hi - lo + Vector2i.ONE
	var total := span.x * span.y
	var g := PackedFloat32Array()
	g.resize(total)
	g.fill(INF)
	var f := PackedFloat32Array()
	f.resize(total)
	f.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(total)
	prev.fill(-1)
	var state := PackedByteArray()      # 0 没见过 / 1 在堆里 / 2 已出堆
	state.resize(total)

	var start_i := (start_c.y - lo.y) * span.x + (start_c.x - lo.x)
	var goal_i := (dst.y - lo.y) * span.x + (dst.x - lo.x)
	g[start_i] = 0.0
	f[start_i] = _octile(start_c, dst)
	var heap: Array[int] = [start_i]
	state[start_i] = 1
	var expanded := 0
	var found := false
	while not heap.is_empty():
		if expanded >= PATH_NODES:
			break                      # 到不了就别硬搜：交给上层「远就落到脚边」
		expanded += 1
		var cur := _heap_pop(heap, f)
		if state[cur] == 2:
			continue                  # 堆里的旧副本（同一个格被改小过）
		state[cur] = 2
		if cur == goal_i:
			found = true
			break
		var cx := cur % span.x + lo.x
		var cy := cur / span.x + lo.y
		for dv in DIRS8:
			var nx := cx + dv.x
			var ny := cy + dv.y
			if nx < lo.x or ny < lo.y or nx > hi.x or ny > hi.y:
				continue
			var n_i := (ny - lo.y) * span.x + (nx - lo.x)
			if state[n_i] == 2:
				continue
			if not _nav.is_walkable_xy(nx, ny):
				continue
			# 斜着不许切墙角（否则会一头顶进楼角，看着就是在墙边来回蹭）
			if dv.x != 0 and dv.y != 0:
				if not _nav.is_walkable_xy(cx + dv.x, cy) \
						or not _nav.is_walkable_xy(cx, cy + dv.y):
					continue
			var step_cost := 1.41421356 if (dv.x != 0 and dv.y != 0) else 1.0
			var ng := g[cur] + step_cost
			if ng < g[n_i]:
				g[n_i] = ng
				prev[n_i] = cur
				f[n_i] = ng + _octile(Vector2i(nx, ny), dst) * 1.05   # 微加权，快一点
				_heap_push(heap, f, n_i)      # 懒删除：同一格可能进堆多次，出堆时跳过旧的
				state[n_i] = 1
	if not found:
		return out
	# 回溯成路点，反过来
	var cells: Array[int] = []
	var c_i := goal_i
	while c_i != start_i:
		cells.append(c_i)
		c_i = prev[c_i]
		if c_i < 0:
			return out
	cells.reverse()
	for ci in cells:
		out.append(Vector2(ci % span.x + lo.x + 0.5, ci / span.x + lo.y + 0.5) * TS)
	return out


## 八方向网格上的启发式距离（格数）
func _octile(a: Vector2i, b: Vector2i) -> float:
	var dx := absi(a.x - b.x)
	var dy := absi(a.y - b.y)
	return float(maxi(dx, dy)) + 0.41421356 * float(mini(dx, dy))


# ---------------------------------------------------------------- 二叉堆（键在外部数组里）
func _heap_push(heap: Array[int], keys: PackedFloat32Array, v: int) -> void:
	heap.append(v)
	var i := heap.size() - 1
	while i > 0:
		var p := (i - 1) >> 1
		if keys[heap[p]] <= keys[heap[i]]:
			break
		var t := heap[p]
		heap[p] = heap[i]
		heap[i] = t
		i = p


func _heap_pop(heap: Array[int], keys: PackedFloat32Array) -> int:
	var top: int = heap[0]
	var last: int = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		var n := heap.size()
		while true:
			var l := i * 2 + 1
			var r := l + 1
			var m := i
			if l < n and keys[heap[l]] < keys[heap[m]]:
				m = l
			if r < n and keys[heap[r]] < keys[heap[m]]:
				m = r
			if m == i:
				break
			var t := heap[m]
			heap[m] = heap[i]
			heap[i] = t
			i = m
	return top


func _clear_path() -> void:
	_path.clear()
	_path_ok = false
	_path_goal = Vector2.INF
	_path_t = 0.0


## 直接落到玩家身后能站的地方（绕不过去 / 被落太远时的兜底）。成功返回 true。
## 落点优先取「玩家背后约一格半」，别直接落在人身上 —— 那样看着是两个精灵叠一起。
func _warp_behind(at: Vector2) -> bool:
	var away := pos - at
	var dirv := away.normalized() if away.length() > 0.5 else Vector2(0.0, 1.0)
	# 从「人背后」开始绕着找一圈：优先落到人身后，实在没地方才退而求其次。
	# 别直接用 _walkable_near(at) —— 人是站在可走格上的，那个函数会原样返回，
	# 猫就正好落在人身上，两个精灵叠在一起。
	var spot := Vector2.INF
	var a0 := dirv.angle()
	for k in 8:
		var a := a0 + TAU * float(k) / 8.0
		var cand := at + Vector2(cos(a), sin(a)) * FOLLOW_FAR
		if _can_walk(cand):
			spot = cand
			break
	if spot == Vector2.INF:
		spot = _walkable_near(at + dirv * FOLLOW_FAR)
	if spot == Vector2.INF:
		return false      # 脚边一圈全是水（玩家在船上）：留在原地等
	pos = spot
	position = pos
	_clear_path()
	_stuck_t = 0.0
	_was_pos = pos
	_block_t = 0.0
	# 刚落地就别急着自己走开：不然「啪」一下闪到人身后，紧接着又跑起来
	_chasing = false
	_play("stand", true)
	wait = 0.3
	return true


## 目标点踩不住（楼 / 水）时，一圈一圈往外找最近的落脚点；都不行返回 Vector2.INF
func _walkable_near(at: Vector2) -> Vector2:
	if _can_walk(at):
		return at
	for gap in WARP_GAPS:
		for i in 12:
			var a := TAU * float(i) / 12.0
			var cand := at + Vector2(cos(a), sin(a)) * gap
			if _can_walk(cand):
				return cand
	return Vector2.INF


## 一次性动画（起身/趴下/跳/连击）播完自动接循环动画
func _play(a: String, lp: bool, q: String = "") -> void:
	anim = a
	anim_t = 0.0
	_anim_rate = 1.0
	loop_anim = lp
	queued = q
	frame = 0
	_set_frame(0)


func _tick_anim(delta: float) -> void:
	anim_t += delta
	var d: Dictionary = ANIMS[anim]
	var n := int(d["n"])
	var f := int(anim_t * float(d["fps"]) * _anim_rate)
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
