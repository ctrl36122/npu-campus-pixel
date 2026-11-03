extends RefCounted
## 角色素材注册表
##
## 素材来源：SkyOffice（client/public/assets/character/*.png，MIT）
## 每个角色都是一张 52 帧、单行排列的 32×48 图集，布局完全一致：
##   idle: right=0  up=6  left=12 down=18   （各 6 帧）
##   run : right=24 up=30 left=36 down=42   （各 6 帧）
##   sit : down=48  left=49 right=50 up=51
##
## 加新角色：把同规格 PNG 放进 assets/sandbox/heroes/，在 HEROES 里加一行即可。

const FRAME_W := 32
const FRAME_H := 48
const FRAMES_PER_ANIM := 6
const DIRS := ["right", "up", "left", "down"]
const IDLE_START := {"right": 0, "up": 6, "left": 12, "down": 18}
const WALK_START := {"right": 24, "up": 30, "left": 36, "down": 42}
const SIT_START := {"right": 50, "up": 51, "left": 49, "down": 48}
const PORTRAIT_FRAME := 18          # down 待机第 0 帧，做头像

const HEROES := [
	{"id": "adam",  "name": "亚当", "sheet": "res://assets/sandbox/heroes/adam.png",
	 "frames": "res://assets/sandbox/frames_adam.tres"},
	{"id": "ash",   "name": "艾什", "sheet": "res://assets/sandbox/heroes/ash.png",
	 "frames": "res://assets/sandbox/frames_ash.tres"},
	{"id": "lucy",  "name": "露西", "sheet": "res://assets/sandbox/heroes/lucy.png",
	 "frames": "res://assets/sandbox/frames_lucy.tres"},
	{"id": "nancy", "name": "南希", "sheet": "res://assets/sandbox/heroes/nancy.png",
	 "frames": "res://assets/sandbox/frames_nancy.tres"},
	# 换装变体（同底图、仅服装色相旋转，见 tools/make_hero_variants.py）
	{"id": "adam_r", "name": "亚当·蓝", "sheet": "res://assets/sandbox/heroes/adam_r.png",
	 "frames": "res://assets/sandbox/frames_adam_r.tres"},
	{"id": "adam_p", "name": "亚当·紫", "sheet": "res://assets/sandbox/heroes/adam_p.png",
	 "frames": "res://assets/sandbox/frames_adam_p.tres"},
	{"id": "ash_g", "name": "艾什·青", "sheet": "res://assets/sandbox/heroes/ash_g.png",
	 "frames": "res://assets/sandbox/frames_ash_g.tres"},
	{"id": "ash_o", "name": "艾什·橙", "sheet": "res://assets/sandbox/heroes/ash_o.png",
	 "frames": "res://assets/sandbox/frames_ash_o.tres"},
	{"id": "lucy_b", "name": "露西·粉", "sheet": "res://assets/sandbox/heroes/lucy_b.png",
	 "frames": "res://assets/sandbox/frames_lucy_b.tres"},
	{"id": "lucy_t", "name": "露西·金", "sheet": "res://assets/sandbox/heroes/lucy_t.png",
	 "frames": "res://assets/sandbox/frames_lucy_t.tres"},
	{"id": "nancy_v", "name": "南希·堇", "sheet": "res://assets/sandbox/heroes/nancy_v.png",
	 "frames": "res://assets/sandbox/frames_nancy_v.tres"},
	{"id": "nancy_c", "name": "南希·红", "sheet": "res://assets/sandbox/heroes/nancy_c.png",
	 "frames": "res://assets/sandbox/frames_nancy_c.tres"},
]


static func by_id(id: String) -> Dictionary:
	for h in HEROES:
		if h["id"] == id:
			return h
	return {}


static func index_of(id: String) -> int:
	for i in HEROES.size():
		if HEROES[i]["id"] == id:
			return i
	return 0
