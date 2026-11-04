extends Node2D
## 校园 NPC：沿可走区域随机漫步，自动绕开建筑/水/桥（用 Godot 内置 AStarGrid2D 寻路）。
## 纯本地模拟、不走网络 —— NPC 不交互、不能聊天，各客户端看到的位置略有差异
## 也无人察觉，但省掉了每帧同步几个实体的开销。
##
## 名字用淡黄色（玩家是白色），一眼能分清谁是真人。

const HeroDB := preload("res://scripts/sandbox/hero_db.gd")
## 只为拿 ACTOR_SCALE，保证 NPC 和玩家同高（改一处两边一起变）
const PlayerScript := preload("res://net/scripts/player/PlayerAvatar.gd")

@export var display_name: String = "路人"
@export var hero_id: String = "adam"
## 不再用半径游走，改由 NavGrid 控制移动范围
@export var radius: float = 30.0
## 相位种子：让每个 NPC 的路线错开，不然一排人同步摇摆
@export var phase_seed: float = 0.0
## 速度倍率（NPC_SPAWNS 的 speed 字段）
@export var move_scale: float = 1.0

# 导航网格（由 Arena 注入）；为空时回退到旧的正弦游走
var nav = null

const WALK_SPEED := 20.0         # 局部像素/秒（campus scale=2 后翻倍显示）

var _origin := Vector2.ZERO
var _last := Vector2.ZERO
var _face: Vector2 = Vector2.DOWN
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()

var _path: Array = []            # 像素路点序列
var _path_idx: int = 0
var _wait: float = 0.0

var _label: Label
var _sprite: AnimatedSprite2D


func _ready() -> void:
	_label = get_node_or_null("Visual/Name")
	_sprite = get_node_or_null("Visual/Sprite")
	var sc: float = PlayerScript.ACTOR_SCALE
	if OS.has_environment("XGD_ACTOR_SCALE"):
		sc = clampf(OS.get_environment("XGD_ACTOR_SCALE").to_float(), 0.08, 1.0)
	var vis := get_node_or_null("Visual") as Node2D
	if vis != null:
		vis.scale = Vector2(sc, sc)
	if _label != null:
		_label.text = display_name
		_label.add_theme_font_size_override("font_size", int(round(11.0 * 0.375 / sc)))
	_apply_hero()
	_origin = position
	_last = position
	_rng.seed = int(phase_seed * 1000.0) + 7
	_t = phase_seed
	_wait = _rng.randf_range(0.0, 3.0)


func _apply_hero() -> void:
	if _sprite == null:
		return
	var h = HeroDB.by_id(hero_id)
	if h.is_empty():
		return
	_sprite.sprite_frames = load(str(h["frames"]))


func _process(delta: float) -> void:
	if nav == null:
		_walk_legacy(delta)
		return
	_t += delta
	if _wait > 0.0:
		_wait -= delta
		_update_anim(false)
		return
	if _path.is_empty() or _path_idx >= _path.size():
		_pick_new_target()
		if _path.is_empty():
			return
	# 去掉与当前位置几乎重合的起点
	if _path_idx == 0 and position.distance_to(_path[0]) < 4.0:
		_path_idx = 1
	if _path_idx >= _path.size():
		_wait = _rng.randf_range(2.0, 5.0)
		return
	var tgt: Vector2 = _path[_path_idx]
	var to: Vector2 = tgt - position
	if to.length() < 3.0:
		_path_idx += 1
		if _path_idx >= _path.size():
			_wait = _rng.randf_range(2.0, 6.0)
			_update_anim(false)
			return
		tgt = _path[_path_idx]
		to = tgt - position
	var step := to.normalized() * WALK_SPEED * move_scale * delta
	position += step
	if step.length() > 0.01:
		_face = step.normalized()
	_update_anim(true)


## 选一个新可走目标并算出 A* 路径
func _pick_new_target() -> void:
	var target_px: Vector2 = nav.random_walkable_near(position, 55)
	_path = nav.find_path(position, target_px)
	_path_idx = 0
	if _path.size() < 2:
		_path = []
		_wait = _rng.randf_range(1.0, 3.0)


## 没有导航网格时的回退：原地正弦小回路（保持旧行为，避免极端情况 NPC 全不动）
func _walk_legacy(delta: float) -> void:
	_t += delta * move_scale
	position = _origin + _offset_at(_t)
	var d: Vector2 = position - _last
	_last = position
	var moving := d.length() > 0.04
	if moving:
		_face = d.normalized()
	_update_anim(moving)


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
