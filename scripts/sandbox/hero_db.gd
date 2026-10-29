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
