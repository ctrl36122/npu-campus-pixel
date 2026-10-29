extends Node2D
## 校园 NPC：在自己出生点附近小范围踱步。
##
## 纯本地模拟、不走网络 —— NPC 不交互、不能聊天，各客户端看到的位置略有差异
## 也无人察觉，但省掉了每帧同步几个实体的开销。
##
## 名字用淡黄色（玩家是白色），一眼能分清谁是真人。

const HeroDB := preload("res://scripts/sandbox/hero_db.gd")

@export var display_name: String = "路人"
@export var hero_id: String = "adam"
## 游走半径（校园局部像素）
@export var radius: float = 30.0
## 相位种子：让每个 NPC 的路线错开，不然一排人同步摇摆
@export var phase_seed: float = 0.0
@export var move_scale: float = 1.0

var _origin := Vector2.ZERO
var _last := Vector2.ZERO
var _face: Vector2 = Vector2.DOWN
var _t: float = 0.0

var _label: Label
var _sprite: AnimatedSprite2D


func _ready() -> void:
	# 精灵和名牌都装在 Visual(scale 0.5) 里：校园整体放大了 2 倍（16px/格），
	# 角色必须保持原尺寸（32×48 ≈ 3 格高）。玩家容器被 reparent 进校园层时
	# Godot 会自动补偿出 scale 0.5，NPC 是直接挂进去的，所以要自己补一个。
	_label = get_node_or_null("Visual/Name")
	_sprite = get_node_or_null("Visual/Sprite")
	if _label != null:
		_label.text = display_name
	_apply_hero()
	_origin = position
	_t = phase_seed
	_last = position


func _apply_hero() -> void:
	if _sprite == null:
		return
	var h = HeroDB.by_id(hero_id)
	if h.is_empty():
		return
	_sprite.sprite_frames = load(str(h["frames"]))


func _process(delta: float) -> void:
	_t += delta * move_scale
	position = _origin + _offset_at(_t)
	var d: Vector2 = position - _last
	_last = position
	var moving := d.length() > 0.04
	if moving:
		_face = d.normalized()
	_update_anim(moving)


## 两个不同周期的正弦叠加：走出不规则小回路，不会像钟摆一样来回
func _offset_at(t: float) -> Vector2:
	var a := t * 0.34
	var x := cos(a) * radius + cos(a * 1.7 + 1.1) * radius * 0.34
	var y := sin(a * 0.81) * radius * 0.75 + sin(a * 1.31) * radius * 0.22
	return Vector2(x, y)


func _update_anim(moving: bool) -> void:
	if _sprite == null:
		return
	var dir := "down"
	if _face != Vector2.ZERO:
		if absf(_face.x) >= absf(_face.y):
			dir = "right" if _face.x > 0.0 else "left"
		else:
			dir = "down" if _face.y > 0.0 else "up"
	var nm := StringName(dir + ("_walk" if moving else "_idle"))
	if _sprite.animation != nm:
		_sprite.animation = nm
	if not _sprite.is_playing():
		_sprite.play()
