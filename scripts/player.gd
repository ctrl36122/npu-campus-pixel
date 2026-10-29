extends CharacterBody2D
## 玩家：WASD / 方向键移动，Shift 加速。
## 贴图由网页版 drawPerson 烘焙而来，脚底锚点在 (32, 52)。

const SPEED := 118.0
const RUN_SPEED := 205.0
const ANCHOR := Vector2(32, 52)

@onready var sprite: Sprite2D = $Sprite


func _ready() -> void:
	var tex = load("res://assets/player.png")
	if tex != null:
		sprite.texture = tex
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.offset = -ANCHOR           # 让脚底落在节点原点上（Y 排序用这个点）


func _physics_process(_delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		dir = dir.normalized()

	var spd := RUN_SPEED if Input.is_key_pressed(KEY_SHIFT) else SPEED
	velocity = dir * spd
	move_and_slide()
