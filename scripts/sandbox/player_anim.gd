extends CharacterBody2D
## Phase 1 · 单机原型玩家
##
## 职责：读本地输入 → 四方向移动 → 切两帧步态动画。
## Phase 2 会把这个类拆成「本地输入 / 远端状态」两条路径，但
## 移动结算这段（_apply_movement）会保留，供服务端模拟与客户端预测共用。

## 每秒移动像素（8px 一格 → 72 约等于 9 格/秒）
@export var move_speed: float = 72.0
## 按住 Shift 的加速倍率
@export var run_multiplier: float = 1.7
## 当前使用的角色 id（见 scripts/sandbox/hero_db.gd）
@export var hero_id: String = "adam"
## 相机可移动的关卡范围（世界像素）。关卡换地图时改这个值即可。
@export var level_bounds: Rect2 = Rect2(0, 0, 768, 512)

const HeroDB := preload("res://scripts/sandbox/hero_db.gd")

@onready var anim: AnimatedSprite2D = $AnimatedSprite2D
@onready var cam: Camera2D = $Camera2D

## 当前朝向：down / up / left / right（决定播哪组动画）
var facing: StringName = &"down"
## 昵称（Phase 3 会同步到其他玩家；Phase 1 仅本地保存）
var display_name: String = ""
## 锁定时不接受移动输入（角色创建弹窗打开时用）
var locked: bool = false   # down/up/left/right


func _ready() -> void:
	# 相机限制在关卡内，避免露出地图外的空白
	if level_bounds.size != Vector2.ZERO:
		cam.limit_left = int(level_bounds.position.x)
		cam.limit_top = int(level_bounds.position.y)
		cam.limit_right = int(level_bounds.position.x + level_bounds.size.x)
		cam.limit_bottom = int(level_bounds.position.y + level_bounds.size.y)
		cam.limit_smoothed = false
	set_hero(hero_id)


## 切换角色外观：换成对应的 SpriteFrames 资源
func set_hero(id: String) -> void:
	var h = HeroDB.by_id(id)
	if h.is_empty():
		push_warning("未知角色 id: " + id)
		return
	var path := str(h["frames"])
	if not ResourceLoader.exists(path):
		push_warning("缺少角色帧资源: " + path)
		return
	hero_id = id
	anim.sprite_frames = load(path)
	anim.animation = StringName(String(facing) + "_idle")
	anim.play()


func _physics_process(_delta: float) -> void:
	if locked:
		velocity = Vector2.ZERO
		_play_idle()
		return
	_apply_movement(_read_input())


## 锁定 / 解锁移动（模态界面打开时锁定）
func set_locked(v: bool) -> void:
	locked = v
	if v:
		velocity = Vector2.ZERO
		_play_idle()


## 记录昵称
func set_display_name(nm: String) -> void:
	display_name = nm


## 只读键盘，不写任何位置。Phase 2 里这里会被换成「生成输入指令并上报」。
func _read_input() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		v.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		v.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		v.y += 1.0
	return v


## 唯一的移动结算入口：给定方向 → 设速度 → move_and_slide → 更新动画
## Phase 2 的服务端模拟 / 客户端预测 / 校正重放都必须调用这一个函数
func _apply_movement(dir: Vector2) -> void:
	if dir == Vector2.ZERO:
		velocity = Vector2.ZERO
		_play_idle()
	else:
		dir = dir.normalized()
		facing = _dir_to_facing(dir)
		var spd := move_speed * (run_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		velocity = dir * spd
		_play_walk()

	move_and_slide()


## 八方向输入 → 四方向朝向（取分量更大的那根轴）
func _dir_to_facing(dir: Vector2) -> StringName:
	if absf(dir.x) >= absf(dir.y):
		return &"right" if dir.x > 0.0 else &"left"
	return &"down" if dir.y > 0.0 else &"up"


## 动画命名：<方向>_walk（6 帧循环）/ <方向>_idle（6 帧呼吸循环）
func _play_walk() -> void:
	var nm := StringName(String(facing) + "_walk")
	if anim.animation != nm:
		anim.animation = nm
	anim.play()


func _play_idle() -> void:
	var nm := StringName(String(facing) + "_idle")
	if anim.animation != nm:
		anim.animation = nm
	anim.play()
