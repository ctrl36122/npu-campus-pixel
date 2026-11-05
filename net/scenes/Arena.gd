extends Node2D
## 联机共享世界：校园地图 + 玩家。
##
## 校园是 scenes/world.tscn（从网页版烘出来的静态场景：28 块地面、53 栋楼、1531 个装饰、
## 448 个水面碰撞）。它完全静态，所以每个客户端各自实例化一份即可，不需要走网络同步——
## 网络上只传玩家。
##
## 两个坐标系的换算要注意：
##   world.tscn 里的坐标是「8px/格」的原生像素（世界 3392×6400）；
##   玩家角色是 32×48，直接放进去会变成 6 格高的巨人，
##   所以整个校园放大 CAMPUS_SCALE 倍（2×）→ 视觉上等于 16px/格，玩家约 3 格高。

const PLAYER: PackedScene = preload("res://net/scenes/Player.tscn")
const CAMPUS: PackedScene = preload("res://scenes/world.tscn")
const NPC: PackedScene = preload("res://net/scenes/Npc.tscn")
const LabelsScript := preload("res://scripts/labels.gd")
const MapData := preload("res://scripts/ui/map_data.gd")

## 校园里的 NPC。位置取自 world.json 的 npc 出生点，两个压在楼里的已就近挪开
## （用 Python 遍历建筑多边形和水面验证过）。
const NPC_SPAWNS: Array = [
	# hero 用换装变体（见 scripts/sandbox/hero_db.gd），让闲逛 NPC 也展示新可选外观；
	# 四个基础角色（adam/ash/lucy/nancy）仍保留给玩家在选角面板里挑。
	{"name": "早八人", "cell": Vector2(230, 270), "hero": "adam_r", "radius": 26.0, "speed": 1.0},
	{"name": "阅览常客", "cell": Vector2(247, 392), "hero": "lucy_b", "radius": 20.0, "speed": 0.6},
	{"name": "散步党", "cell": Vector2(266, 305), "hero": "ash_g", "radius": 44.0, "speed": 1.15},
	{"name": "干饭人", "cell": Vector2(285, 184), "hero": "nancy_v", "radius": 30.0, "speed": 1.3},
	{"name": "夜跑选手", "cell": Vector2(88, 270), "hero": "ash_o", "radius": 52.0, "speed": 1.6},
	{"name": "考研人", "cell": Vector2(157, 344), "hero": "lucy_t", "radius": 22.0, "speed": 0.75},
]

const CAMPUS_SCALE: float = 2.0
const TS: float = 8.0
## 出生点（格）：教学区之间的开阔路口。
## 这个点是用 Python 遍历 world.json 挑出来的——本点和周围 8 个散开位置
## 都不在任何建筑轮廓或水面里（北门那个点周围有楼，玩家出生就会被楼压住看不见）。
## 出生点（格）。显示调试：XGD_SPAWN="x,y" 可临时改出生点（截图、验景用），正常玩不受影响。
const SPAWN_CELL: Vector2 = Vector2(220, 240)


func _spawn_cell() -> Vector2:
	if OS.has_environment("XGD_SPAWN"):
		var parts := OS.get_environment("XGD_SPAWN").split(",")
		if parts.size() == 2 and parts[0].is_valid_float() and parts[1].is_valid_float():
			return Vector2(float(parts[0]), float(parts[1]))
	return SPAWN_CELL


# ── 水上小船 ────────────────────────────────────────────────────────────────
## 船位（格）：最大的南侧湖 5 艘，其余 5 块独立水域各 2 艘，共 15 艘。
## 每个点都落在水格里，并且紧贴一格可行走岸线（已用 world.json 的水面矩形
## 和楼体轮廓逐个校验过：人在岸上走两步就能看到提示，上船不用下水）。
## 这张表在服务端和每个客户端完全一致，所以船的编号可以直接走 RPC。
const BoatScript := preload("res://net/scenes/Boat.gd")
const BOAT_CELLS: Array = [
	Vector2(241, 259), Vector2(248, 240),      # 出生点西侧湖（近南门）
	Vector2(264, 318), Vector2(281, 324),      # 中央小湖
	Vector2(355, 335), Vector2(365, 355),      # 东侧小水塘
	Vector2(255, 394), Vector2(291, 352),      # 图书馆前湖
	Vector2(283, 458), Vector2(284, 526),      # 长条水道
	Vector2(137, 579), Vector2(207, 582), Vector2(288, 613),
	Vector2(269, 682), Vector2(221, 666),      # 南侧大湖
]
## 船速与走路完全一致（PlayerAvatar.SPEED = 110 局部 px/s），Shift 同样的倍率。
const BOAT_SPEED := 110.0
const BOAT_SPRINT := 1.55
## 站在岸边多近可以按 E 上船（局部像素，约 3.75 格）
const BOAT_NEAR_R := 30.0
## 人物脚底相对船心的偏移：稍微偏南，保证 y 排序时人画在船体上面
const BOAT_RIDER_OFFSET := Vector2(0, 2.0)
## 船位广播频率（30Hz，和移动同步同频）
const BOAT_SEND_HZ := 30.0
## 单个网络包允许的最大船位位移（防瞬移；留出 3 个 tick 的抖动余量）
const BOAT_STEP_MAX := 48.0
## 相邻玩家的散开半径（校园局部像素，未放大）= 10 格。
## 人多时靠这个半径一圈圈往外排，避免几十个人叠成一坨。
const SPREAD: float = 80.0
## 被楼遮住时的透视方式：只在玩家身边挖一个柔和椭圆「透视窗」（楼体其余部分
## 保持实心），而不是整栋楼变半透明 —— 后者夜里会把楼后被路灯照亮的路面整片透出来。
const XRAY_SHADER := preload("res://net/shaders/building_xray.gdshader")
const XRAY_RX: float = 17.0       # 透视窗半宽（贴图局部像素）
const XRAY_RY: float = 24.0       # 透视窗半高
const XRAY_HOLE_ALPHA: float = 0.20

## 小地图：1 像素 = 1 格，整张校园 424×800
const CELLS: Vector2 = Vector2(424, 800)
## 底图分辨率：每格 4 像素（424×800 → 1696×3200）。比原来 1px/格 清晰得多，
## 全屏地图放大到 8× 也不糊。
const MINI_PXP: int = 4
## 校园局部像素尺寸（8px/格）
const LOCAL_PX: Vector2 = Vector2(3392, 6400)
## 小地图缓存（首次启动烘焙，之后直接读；分辨率变了要换文件名）
const MINIMAP_CACHE: String = "user://minimap_cache_v23.png"

@onready var players: Node2D = $Players
@onready var spawner: MultiplayerSpawner = $PlayerSpawner

var campus: Node2D
var labels: CanvasLayer
## 小地图纹理，UI 层（online_boot）读取它来做右上角小地图与全屏地图
var minimap_tex: Texture2D
## 透视墙：每栋楼的 Sprite + 它的脚线 y（局部坐标）
## 玩家走到楼"后面"（被 2.5D 立面盖住）时把这栋楼调成半透明，否则完全看不见自己
var _xray: Array = []

## 夜晚视觉（昼夜系统 DayNight 驱动）：
##  - 夜幕叠加层：独立画布（layer 1），盖在世界之上、UI 之下，把整张校园压暗染色
##  - 夜灯层：独立画布（layer 2），叠加在夜幕之上、用加色混合画建筑窗户暖光，
##    因为是独立画布、不参与夜幕的乘色，所以夜里灯是真亮的
##  - 楼名标注抬到 layer 3，夜里也看得清
var _night_dark: CanvasLayer
var _night_dark_rect: ColorRect   ## 夜幕：全屏矩形 + shader（按光照图决定哪里不压暗）
var _night_warm_rect: ColorRect   ## 路灯光照区的暖色补光（add 混合）
var _dark_mat: ShaderMaterial
var _warm_mat: ShaderMaterial
var _glow_root: Node2D
var _lamp_tex: Texture2D          ## 路灯：灯头光晕（白图，染暖色）
var _lamp_glows: Array = []       ## 每盏路灯一组光（带轻微闪烁 phase）
var _glow_tex_empty: Texture2D    ## 没有烘焙窗光的楼用的 1×1 透明贴图
## MC 式格子光照图：路灯当光源做 flood-fill 传播，夜里用它把路面"点亮"
var _light_tex: Texture2D
var _world_origin := Vector2.ZERO
var _world_size := Vector2.ONE
## 昼夜单例（运行时通过 Engine 取，避免编辑器脚本缓存没刷新时解析报错）
var _dn: Object


func _ready() -> void:
	# 0) 水域掩码 + 小船初始状态。专用服务器也要跑这两步：
	#    服务端要校验船位、裁定谁在船上，只是不建任何视觉。
	_build_water_mask()
	_init_boats()
	_load_bridges()

	# 1) 挂校园
	campus = CAMPUS.instantiate()
	campus.name = "Campus"
	# 校园整体放大倍数：决定「一格在屏幕上多大」，配合 PlayerAvatar.ACTOR_SCALE 决定人物与楼的比例。
	# 调试：XGD_CAMPUS_SCALE=2.6 可临时指定（截图对比用）。改大 → 楼更宽更气派、草地像素更粗。
	var cs := CAMPUS_SCALE
	if OS.has_environment("XGD_CAMPUS_SCALE"):
		cs = clampf(OS.get_environment("XGD_CAMPUS_SCALE").to_float(), 1.0, 8.0)
	campus.scale = Vector2(cs, cs)
	add_child(campus)

	# 2) 把玩家容器挪进校园的 Objects 层。
	#    y 排序只在「同一个父节点的直接子节点」之间比较，
	#    玩家如果留在 Arena 下，就会整体盖在所有建筑上面（或全被盖住）。
	#    ⚠️ players 本身也必须 y_sort_enabled：Godot 4 会把嵌套的 y-sort 容器
	#    展开合并到父级那一趟排序里，角色才能和楼、树逐个体比较。
	#    不设的话玩家容器整体按自身 y=0 排，等于永远在所有建筑后面。
	var objs: Node2D = campus.get_node_or_null("Objects")
	if objs != null:
		players.reparent(objs)
		# reparent 为保持全局变换会自动给容器补 scale=0.5，这会让角色的
		# position 变成「全局值存在半尺度空间里」——y-sort 比较的是各父空间
		# 的局部 y，两套值域混用导致人物永远画在楼上面（楼后也挡不住）。
		# 归一成 1：Players 空间 = Objects 空间 = 校园局部坐标，
		# 角色视觉尺寸靠 Player.tscn 自身的 scale=0.5 保持不变。
		players.scale = Vector2.ONE
		players.y_sort_enabled = true
		spawner.spawn_path = spawner.get_path_to(players)

	# 专用服务器（--server）：只跑「碰撞 + 玩家生成 + 同步」，整套视觉全部跳过。
	# 无头模式没有渲染，光照图/小地图/夜灯既用不上又要吃掉几十秒 CPU 和几百 MB 内存。
	if Net.is_dedicated:
		queue_redraw()
		return

	# 3) 楼名标注（和网页版一样：缩放够近才显示，挂在楼体顶部）
	labels = CanvasLayer.new()
	labels.name = "BuildingLabels"
	labels.set_script(LabelsScript)
	add_child(labels)
	labels.call("setup_from_world", campus)

	# 3.5) 昼夜视觉：夜幕叠加 + 建筑夜灯（夜灯强度/染色由 DayNight 单例每帧驱动）
	_setup_daynight()

	# 4) 小地图纹理（整张校园缩略图，给 UI 用）
	minimap_tex = _build_minimap_texture()

	# 5) NPC 闲逛（纯本地，不进 "players" 分组，免得被当成真人玩家处理）
	_spawn_npcs()
	_setup_wildlife()
	_setup_lamps()
	_setup_boats()

	_collect_xray()
	queue_redraw()

	_collect_dorms()
	_collect_campus_seats()
	_build_door_hint()
	_build_voice_btn()
	Net.seat_changed.connect(_on_seat_changed)
	# 别人的认领公告一到（或自己认领成功）立刻刷新门牌；名单变化会影响「谁跟你同层」
	Net.room_claims_changed.connect(_refresh_door_plates)
	# 好友表一变，门锁跟着变（好友能进我的房、我也能进他的）
	Net.social_changed.connect(_on_social_changed)
	Net.roster_changed.connect(_update_floor_visibility)
	# 先把本地存档里的「我的房间 + 公告」灌进 Net：没连上服务器也能显示，
	# 连上了就用它把服务端丢掉的那份补回来。
	_restore_my_room()

	# 调试：启动即进房间（正常玩法走到宿舍旁按 E）
	if OS.has_environment("XGD_ROOM"):
		print("[dbg] XGD_ROOM 命中，准备自动进房间")
		_auto_enter_room()
	# 调试：模拟按一次 E，验证的是「按键 → 就近判定 → 进房间」整条链路
	if OS.has_environment("XGD_TEST_E"):
		_auto_press_e()
	# 调试：进房间后往南走，验证「走到门口自动离开」
	if OS.has_environment("XGD_TEST_DOOR"):
		_auto_walk_out()
	# 调试：进房间后走到 1 号房门口，验证门会自动滑开、人过得去
	if OS.has_environment("XGD_TEST_GATE"):
		_auto_walk_gate()
	# 调试：按住方向键走几秒（XGD_TEST_WALK=秒数）。用来核对「我动了，对面那边跟着动」
	if OS.has_environment("XGD_TEST_WALK"):
		_auto_walk_sync()

	_guard_local_spawn()
	if not (OS.has_environment("XGD_NOHOME")):
		_auto_spawn_home()
	# 调试：XGD_FORCE_SPAWN="x,y"（格）—— 连接稳定后把本地玩家硬挪过去。
	# 联机时出生点由服务端说了算，XGD_SPAWN 只对单机/首次连接有效，截图用这个。
	if OS.has_environment("XGD_FORCE_SPAWN"):
		_force_spawn_debug()
	# 调试：XGD_TEST_BOAT="船号,x,y"（格）—— 把某艘船摆到指定水域并让本地玩家上船，
	# 用来核对「小船从拱桥底下穿过」时的遮挡与水面衔接（截图用，正常玩无效）。
	if OS.has_environment("XGD_TEST_BOAT"):
		_boat_debug()


## 生成校园 NPC。挂在 Objects 下是为了和建筑/树共用 y 排序（走到树后面会被遮住）。
func _setup_wildlife() -> void:
	## 水波层 + 小动物（猫/鸟/蝴蝶），全部程序绘制、零素材
	var wf: GDScript = load("res://net/scenes/Wildlife.gd")
	var anchors: Array = _cat_anchors()
	# 水波层：贴在 Ground 之上、Objects 之下（先 add 再挪到 Objects 前）
	var fx := Node2D.new()
	fx.name = "WaterFX"
	fx.set_script(load("res://net/scenes/WaterFX.gd"))
	campus.add_child(fx)
	fx.call("setup", _water_rects())
	var objs: Node2D = campus.get_node_or_null("Objects")
	if objs != null:
		campus.move_child(fx, objs.get_index())
		# 猫/狗/兔/鸭：挂进 Objects 参与 y 排序，走到楼后会被挡住
		var ground: Node2D = wf.new()
		ground.name = "WildlifeGround"
		ground.set("mode", "ground")
		objs.add_child(ground)
		_wildlife_ground = ground
		ground.call("setup", anchors, _water_rects(), _cat_nav)
	# 鸟 + 蝴蝶：空中层，永远在人/楼上面
	var air: Node2D = wf.new()
	air.name = "WildlifeAir"
	air.set("mode", "air")
	campus.add_child(air)
	air.call("setup", anchors)


## 猫的活动锚点：NPC 活跃点打头，再按 10×10 分区在全图随机撒可走点。
## 每个点要求 3×3 邻域都可走（避开水面、建筑 footprint 和楼影）。
## 默认每局随机；调试时用 XGD_CAT_SEED 固定种子便于复现。
func _cat_anchors() -> Array:
	_cat_nav = _build_nav_grid()
	var rng := RandomNumberGenerator.new()
	if OS.has_environment("XGD_CAT_SEED"):
		rng.seed = int(OS.get_environment("XGD_CAT_SEED"))
	else:
		rng.randomize()
	var out: Array = []
	for info in NPC_SPAWNS:
		var cell: Vector2 = info["cell"] as Vector2
		# NPC 活跃点同样要查可走：有的点贴着楼影，直接拿来当猫窝会卡住
		if _cat_nav != null and not _cat_spot_open(int(cell.x), int(cell.y)):
			continue
		out.append(cell * TS)
	if _cat_nav == null:
		return out
	# 分区采样：既随机又铺满整张地图，不会全挤在一角
	var cols := 10
	var rows := 10
	for ry in range(rows):
		for rx in range(cols):
			var x0 := 40.0 + 370.0 * float(rx) / float(cols)
			var x1 := 40.0 + 370.0 * float(rx + 1) / float(cols)
			var y0 := 30.0 + 600.0 * float(ry) / float(rows)
			var y1 := 30.0 + 600.0 * float(ry + 1) / float(rows)
			for t in 16:
				var cx := rng.randi_range(int(x0), maxi(int(x0), int(x1)))
				var cy := rng.randi_range(int(y0), maxi(int(y0), int(y1)))
				if _cat_spot_open(cx, cy):
					out.append(Vector2(float(cx), float(cy)) * TS)
					break
	# 个别分区全是障碍时，纯随机补足到 100 个点位
	var tries := 0
	while out.size() < 100 and tries < 4000:
		tries += 1
		var cx := rng.randi_range(40, 410)
		var cy := rng.randi_range(30, 630)
		if _cat_spot_open(cx, cy):
			out.append(Vector2(float(cx), float(cy)) * TS)
	return out


func _cat_spot_open(cx: int, cy: int) -> bool:
	if _cat_nav == null:
		return false
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if not _cat_nav.is_walkable(Vector2i(cx + dx, cy + dy)):
				return false
	return true


func _water_rects() -> Array:
	var f := FileAccess.open("res://assets/world.json", FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		return parsed.get("water", [])
	return []


## 载入桥甲板足迹（格）。玩家站在甲板上时由 _update_bridge_z 临时抬升 z_index，
## 否则桥体（原点在甲板南缘）按 y 排序会盖住玩家、让人"消失在桥里"。
func _load_bridges() -> void:
	_bridge_decks.clear()
	var f := FileAccess.open("res://assets/world.json", FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	for b in parsed.get("bridges", []):
		_bridge_decks.append(Rect2(float(b.get("x", 0.0)), float(b.get("y", 0.0)),
			float(b.get("w", 0.0)), float(b.get("h", 0.0))))


## 玩家（校园局部像素坐标）是否落在某座桥的甲板上。
func _on_bridge_deck(local: Vector2) -> bool:
	var c := local / TS
	for r in _bridge_decks:
		if c.x >= r.position.x and c.x < r.position.x + r.size.x \
				and c.y >= r.position.y and c.y < r.position.y + r.size.y:
			return true
	return false


## 每帧：站在桥甲板上的玩家临时抬到高 z（桥体/楼/船都压在下面），
## 离开桥恢复 0（回到正常 y 排序）。只用纯视觉、无需同步。
## 划船时不抬 —— 船在桥洞底下，人必须跟着船一起被桥体挡住，否则「人穿桥而过」。
func _update_bridge_z() -> void:
	if players == null:
		return
	for a in players.get_children():
		if not (a is Node2D):
			continue
		var lifted := false
		if not bool(a.get("on_boat")):
			lifted = _on_bridge_deck((a as Node2D).position)
		(a as Node2D).z_index = 100 if lifted else 0


# ══════════════════════════════════════════════════════════════════════════
#  水上小船：水域掩码 + 本地划船 + 服务端裁定与船位同步
#
#  船位/占用由**服务端**裁决（一人一船、不能抢别人正在划的船）。
#  划船的客户端本地推进船位（手感不延迟），每 30Hz 把船位报给服务端；
#  服务端校验「人是不是这条船的乘客 / 目标点是不是水 / 单步位移是否合理」，
#  再广播给其他所有客户端。其他人看到的船位是服务端权威值，画的时候插值。
#
#  乘客的位置复用宿舍那套「本地权威 + 每 tick 推送」链路：
#  PlayerAvatar._room_freeze = true 时服务端不模拟输入，位置通过 _push_room_pose
#  推给服务端，再以负 seq 广播给远端。所以别人能看到你站在船上一起移动。
# ══════════════════════════════════════════════════════════════════════════

## 从 world.json 的 water 矩形生成 424×800 的水格掩码。
## 船和玩家的坐标都是「校园局部像素」（8px/格），查表时除以 TS 即可。
func _build_water_mask() -> void:
	_water_w = int(CELLS.x)
	_water_h = int(CELLS.y)
	var f := FileAccess.open("res://assets/world.json", FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	var mp: Dictionary = parsed.get("map", {})
	_water_w = maxi(1, int(mp.get("W", _water_w)))
	_water_h = maxi(1, int(mp.get("H", _water_h)))
	_water_mask = PackedByteArray()
	_water_mask.resize(_water_w * _water_h)
	_water_mask.fill(0)
	for r in parsed.get("water", []):
		var x0: int = int(r.get("x", 0))
		var y0: int = int(r.get("y", 0))
		var x1: int = x0 + int(r.get("w", 0))
		var y1: int = y0 + int(r.get("h", 0))
		for y in range(maxi(0, y0), mini(_water_h, y1)):
			var row: int = y * _water_w
			for x in range(maxi(0, x0), mini(_water_w, x1)):
				_water_mask[row + x] = 1


func _init_boats() -> void:
	_boats.clear()
	for i in BOAT_CELLS.size():
		var spawn := _boat_spawn(BOAT_CELLS[i] as Vector2)
		var d: Vector2 = spawn["dir"]
		_boats.append({
			"pos": spawn["pos"],
			"rider": 0,
			"moving": false,
			"dirx": d.x,
			"diry": d.y,
		})


## 船的出生点微调：只在船体会探出水面时才把它往水域内侧推最多两格，
## 其余情况原地不动 —— 位置本来就是贴着岸选的，推远了反而上不了船
## （上船判定 BOAT_NEAR_R 只有 3.75 格）。
## 朝向按水域形状定：够横着放就横放，窄河道竖放。
## 纯函数、只读水面掩码，服务端与客户端算出来必然一致（船位要两端对上）。
func _boat_spawn(cell: Vector2) -> Dictionary:
	var cx := int(cell.x)
	var cy := int(cell.y)
	var fallback := {"pos": cell * TS, "dir": Vector2.RIGHT}
	if _water_mask.is_empty() or cx < 0 or cy < 0 or cx >= _water_w or cy >= _water_h:
		return fallback
	if _water_mask[cy * _water_w + cx] == 0:
		return fallback
	# 水平方向连通段
	var x0 := cx
	while x0 > 0 and _water_mask[cy * _water_w + x0 - 1] != 0:
		x0 -= 1
	var x1 := cx
	while x1 < _water_w - 1 and _water_mask[cy * _water_w + x1 + 1] != 0:
		x1 += 1
	var span_w := x1 - x0 + 1
	# 船体横放时半长 1.9 格，留 2 格余量；竖放时半宽只有 0.8 格，不用管
	var pad := 2.0
	var px := clampf(cell.x, float(x0) + pad, float(x1 + 1) - pad)
	if float(x1 + 1) - float(x0) < pad * 2.0:
		px = float(x0 + x1 + 1) * 0.5            # 太窄就居中，反正都放不下
	# 以最终落点为列量纵向长度，判断是横条还是竖条
	var col := clampi(int(px), 0, _water_w - 1)
	var y0 := cy
	while y0 > 0 and _water_mask[(y0 - 1) * _water_w + col] != 0:
		y0 -= 1
	var y1 := cy
	while y1 < _water_h - 1 and _water_mask[(y1 + 1) * _water_w + col] != 0:
		y1 += 1
	var span_h := y1 - y0 + 1
	var dir := Vector2.RIGHT if span_w >= span_h else Vector2.DOWN
	return {"pos": Vector2(px, cy + 0.5) * TS, "dir": dir}


## 建本地小船节点。挂在 Objects 下参与 y 排序；专用服务器不建（没有渲染）。
func _setup_boats() -> void:
	var objs: Node2D = campus.get_node_or_null("Objects")
	if objs == null:
		return
	_boat_nodes.clear()
	for i in _boats.size():
		var node := Node2D.new()
		node.name = "boat_%d" % i
		node.set_script(BoatScript)
		objs.add_child(node)
		node.call("setup", i, _boats[i]["pos"])
		_boat_nodes.append(node)


func _is_water(local: Vector2) -> bool:
	if _water_mask.is_empty():
		return true                      # 数据缺失时不挡船，避免整片水域都不能划
	var cx: int = int(floor(local.x / TS))
	var cy: int = int(floor(local.y / TS))
	if cx < 0 or cy < 0 or cx >= _water_w or cy >= _water_h:
		return false
	return _water_mask[cy * _water_w + cx] != 0


## 船只能在水格中心之间走；撞到岸线时按轴分离，斜着划不会贴死。
func _slide_on_water(from: Vector2, to: Vector2) -> Vector2:
	if _is_water(to):
		return to
	var x_only := Vector2(to.x, from.y)
	if _is_water(x_only):
		return x_only
	var y_only := Vector2(from.x, to.y)
	if _is_water(y_only):
		return y_only
	return from


func _boat_input_dir(me: Node) -> Vector2:
	if bool(me.get("ui_blocked")):
		return Vector2.ZERO
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return Vector2.ZERO
	return Input.get_vector("move_left", "move_right", "move_up", "move_down").limit_length()


## 每帧驱动本机正在划的船，并把乘客位置贴在船上。
func _update_boat_control(delta: float) -> void:
	if _my_boat < 0 or _my_boat >= _boats.size():
		return
	var me: Node = _local_avatar()
	if me == null:
		_my_boat = -1
		return
	if not _boat_confirmed:
		# 本地先上船，但要等服务端确认；长时间没回包（掉线/被抢）就撤回岸上。
		_boat_wait += delta
		if _boat_wait > 2.5:
			_abort_local_ride()
			return

	var b: Dictionary = _boats[_my_boat]
	var dir := _boat_input_dir(me)
	var speed: float = BOAT_SPEED * (BOAT_SPRINT if Input.is_action_pressed("sprint") else 1.0)
	var before: Vector2 = b["pos"]
	if dir.length() > 0.05:
		var target: Vector2 = before + dir * speed * delta
		b["pos"] = _slide_on_water(before, target)
		# 船头朝移动方向：像素画法只做 4 个正交方向（左右/上下），
		# 斜着划时取分量更大的那一轴，船不会出现「斜着躺」的锯齿。
		if absf(dir.x) >= absf(dir.y):
			b["dirx"] = 1.0 if dir.x >= 0.0 else -1.0
			b["diry"] = 0.0
		else:
			b["dirx"] = 0.0
			b["diry"] = 1.0 if dir.y >= 0.0 else -1.0
		b["moving"] = (b["pos"] as Vector2).distance_to(before) > 0.02
		me.set("_face_dir", dir.normalized())
	else:
		b["moving"] = false

	# 乘客跟着船走。脚底比船心略靠南，y 排序时人物会画在船体上面。
	(me as Node2D).position = (b["pos"] as Vector2) + BOAT_RIDER_OFFSET

	# 30Hz 上报船位：本机是服务端就广播，否则发给服务端再转发。
	_boat_send_clock += delta
	if _boat_send_clock >= 1.0 / BOAT_SEND_HZ:
		_boat_send_clock = 0.0
		if Net.is_server():
			if not Net.is_offline():
				_boat_pose.rpc(_my_boat, b["pos"], bool(b["moving"]), float(b["dirx"]), float(b["diry"]))
		elif Net.has_session():
			_push_boat.rpc_id(1, _my_boat, b["pos"], bool(b["moving"]), float(b["dirx"]), float(b["diry"]))


func _update_boats() -> void:
	if Net.is_dedicated or _boat_nodes.is_empty():
		return
	for i in _boat_nodes.size():
		var node: Node = _boat_nodes[i]
		if node == null or not is_instance_valid(node):
			continue
		var b: Dictionary = _boats[i]
		node.call("set_occupied", int(b["rider"]) != 0)
		if i == _my_boat:
			node.call("set_riding", true)
			node.call("apply_local", b["pos"], bool(b["moving"]), float(b["dirx"]), float(b["diry"]))
		else:
			node.call("set_riding", false)
			node.call("set_net", b["pos"], bool(b["moving"]), float(b["dirx"]), float(b["diry"]))


func _nearest_boat(pos: Vector2) -> int:
	var best: int = -1
	var best_d: float = BOAT_NEAR_R
	for i in _boats.size():
		var d: float = pos.distance_to(_boats[i]["pos"])
		if d < best_d:
			best_d = d
			best = i
	return best


func _clear_avatar_motion(me: Node) -> void:
	var buf: Variant = me.get("buffer")
	if buf != null:
		buf.entries.clear()
	var cmds: Variant = me.get("commands")
	if cmds is Dictionary:
		(cmds as Dictionary).clear()


## 本地（乐观）上船：立刻吸附、关碰撞、进入本地权威；再让服务端裁定。
func _try_board(index: int) -> bool:
	if in_room or index < 0 or index >= _boats.size():
		return false
	var me: Node = _local_avatar()
	if me == null:
		return false
	var b: Dictionary = _boats[index]
	if int(b["rider"]) != 0 and int(b["rider"]) != Net.my_id():
		_notice("这艘小船已经有人了")
		return false
	if (me as Node2D).position.distance_to(b["pos"]) > BOAT_NEAR_R:
		return false
	_boat_return_pos = (me as Node2D).position
	_my_boat = index
	_boat_confirmed = Net.is_server()
	_boat_wait = 0.0
	_boat_send_clock = 0.0
	b["rider"] = Net.my_id()
	b["moving"] = false
	_clear_avatar_motion(me)
	me.set("_room_freeze", true)
	me.call("set_boat_state", true, (b["pos"] as Vector2) + BOAT_RIDER_OFFSET)
	if Net.is_server():
		call_deferred("_do_boat_request", 1, index, true, _boat_return_pos)
	elif Net.has_session():
		_request_boat.rpc_id(1, index, true, _boat_return_pos)
	return true


## 本地（乐观）下船：只在能靠岸时成功；落点用物理查询找最近的可行走空地。
func _try_disembark() -> bool:
	if _my_boat < 0 or _my_boat >= _boats.size():
		return false
	var idx: int = _my_boat
	var b: Dictionary = _boats[idx]
	var land := _find_land_near(b["pos"])
	if not bool(land["ok"]):
		_notice("靠岸后再按 E 下船")
		return false
	var target: Vector2 = land["pos"]
	_my_boat = -1
	_boat_confirmed = false
	# 占用不要在这里清：本机是主机时，服务端那份 _boats 就是本对象，
	# 先清零会让 _do_boat_request 以为「船已经空了」而跳过广播，其他客户端
	# 就会一直看到这艘船还有人。等服务端处理完请求再统一刷掉。
	b["moving"] = false
	var me: Node = _local_avatar()
	if me != null:
		_clear_avatar_motion(me)
		me.set("_room_freeze", false)
		me.call("set_boat_state", false, target)
	if Net.is_server():
		call_deferred("_do_boat_request", 1, idx, false, target)
	elif Net.has_session():
		_request_boat.rpc_id(1, idx, false, target)
	return true


## 服务端拒绝/超时/被别人抢走时撤回到岸上（不走路的话会一直停在原地）。
## clear_rider = false：服务端刚广播了「这艘船现在是别人的」，别把人家的占用抹掉。
func _abort_local_ride(clear_rider: bool = true) -> void:
	var idx: int = _my_boat
	_my_boat = -1
	_boat_confirmed = false
	if idx < 0 or idx >= _boats.size():
		return
	if clear_rider:
		_boats[idx]["rider"] = 0
		_boats[idx]["moving"] = false
	var me: Node = _local_avatar()
	if me == null:
		return
	_clear_avatar_motion(me)
	me.set("_room_freeze", false)
	var target: Vector2 = _boat_return_pos
	var land := _find_land_near(_boats[idx]["pos"])
	if bool(land["ok"]):
		target = land["pos"]
	me.call("set_boat_state", false, target)
	# 上船请求可能已经到服务端了（只是确认包晚到/丢了）：主动请它释放一次，
	# 服务端没记「我」在这条船上时这条请求会被安全忽略。
	if Net.is_server():
		call_deferred("_do_boat_request", 1, idx, false, target)
	elif Net.has_session():
		_request_boat.rpc_id(1, idx, false, target)


## 船附近最近的可站立陆地（从船心向外一圈圈找，最多 12 格）。
## 水面本身是实体碰撞，所以直接用物理点查询就能排除。
## 只在按 E 下船时调用（不下船就不扫物理，省 CPU）。
func _find_land_near(origin: Vector2) -> Dictionary:
	if not _is_water(origin) and _point_free(origin):
		return {"ok": true, "pos": origin}
	for ring in range(1, 13):
		var n: int = maxi(8, ring * 4)
		for i in n:
			var a: float = float(i) * TAU / float(n)
			var p: Vector2 = origin + Vector2(cos(a), sin(a)) * (float(ring) * TS)
			if _is_water(p):
				continue
			if _point_free(p):
				return {"ok": true, "pos": p}
	return {"ok": false, "pos": Vector2.ZERO}


func _point_free(local: Vector2) -> bool:
	var space := get_world_2d().direct_space_state
	var params := PhysicsPointQueryParameters2D.new()
	params.position = players.to_global(local)
	params.collision_mask = 1
	params.collide_with_areas = false
	params.collide_with_bodies = true
	return space.intersect_point(params, 1).is_empty()


## 船位附近有没有岸（只查水格掩码，不碰物理）。用于每 8Hz 刷新的提示文案，
## 避免在水中央每帧扫几百个物理点。
func _shore_near(origin: Vector2, radius_cells: int = 12) -> bool:
	if _water_mask.is_empty():
		return true
	var cx: int = int(floor(origin.x / TS))
	var cy: int = int(floor(origin.y / TS))
	for dy in range(-radius_cells, radius_cells + 1):
		for dx in range(-radius_cells, radius_cells + 1):
			var x: int = cx + dx
			var y: int = cy + dy
			if x < 0 or y < 0 or x >= _water_w or y >= _water_h:
				continue
			if _water_mask[y * _water_w + x] == 0:
				return true
	return false


func _broadcast_boat(index: int) -> void:
	if not Net.is_server() or Net.is_offline():
		return
	var b: Dictionary = _boats[index]
	_boat_rider.rpc(index, int(b["rider"]), b["pos"], float(b["dirx"]), float(b["diry"]))


func _release_boats_of(id: int) -> void:
	if not Net.is_server():
		return
	for i in _boats.size():
		if int(_boats[i]["rider"]) == id:
			_boats[i]["rider"] = 0
			_boats[i]["moving"] = false
			_broadcast_boat(i)


# ---------------------------------------------------------------- 小船 RPC
## 客户端 -> 服务端：上/下船请求。物理查询不能直接在 RPC 回调里做，延后一帧。
@rpc("any_peer", "call_remote", "reliable", 0)
func _request_boat(index: int, boarding: bool, pos: Vector2) -> void:
	if not Net.is_server():
		return
	call_deferred("_do_boat_request", multiplayer.get_remote_sender_id(), index, boarding, pos)


## 服务端裁定：船是否空着、人是否真在船边、下船落点是否是可站立的陆地。
func _do_boat_request(id: int, index: int, boarding: bool, pos: Vector2) -> void:
	if not Net.is_server() or index < 0 or index >= _boats.size():
		return
	if id != 1 and not Net.peers.has(id):
		return
	var av: Node = players.get_node_or_null(str(id))
	if av == null:
		return
	var b: Dictionary = _boats[index]

	if boarding:
		if int(b["rider"]) != 0 and int(b["rider"]) != id:
			_broadcast_boat(index)
			return
		# 一人一船：已经在别的船上就不允许再上一条（正常玩法由 E 先下船挡住）
		for i in _boats.size():
			if i != index and int(_boats[i]["rider"]) == id:
				_broadcast_boat(index)
				return
		if (av as Node2D).position.distance_to(b["pos"]) > BOAT_NEAR_R + 12.0:
			_broadcast_boat(index)
			return
		b["rider"] = id
		b["moving"] = false
		_clear_avatar_motion(av)
		av.set("_room_freeze", true)
		av.call("set_boat_state", true, (b["pos"] as Vector2) + BOAT_RIDER_OFFSET)
		_broadcast_boat(index)
		return

	if int(b["rider"]) != id:
		return
	# 客户端给的落点要复核：必须不是水、没有静态碰撞、且在船边 3 格内；
	# 不满足就由服务端自己找最近岸边（两端物理数据一致，正常不会走到这里）。
	var target: Vector2 = pos
	var ok: bool = not _is_water(target) and _point_free(target) \
		and target.distance_to(b["pos"]) <= 3.0 * TS
	if not ok:
		var land := _find_land_near(b["pos"])
		if not bool(land["ok"]):
			_broadcast_boat(index)
			return
		target = land["pos"]
	b["rider"] = 0
	b["moving"] = false
	_clear_avatar_motion(av)
	av.set("_room_freeze", false)
	av.call("set_boat_state", false, target)
	_broadcast_boat(index)


## 客户端 -> 服务端：划船时的船位。服务端只认船上的那个人，并复核水格与步长。
@rpc("any_peer", "call_remote", "unreliable_ordered", 3)
func _push_boat(index: int, pos: Vector2, moving_now: bool, dirx: float, diry: float) -> void:
	if not Net.is_server() or index < 0 or index >= _boats.size():
		return
	var b: Dictionary = _boats[index]
	if int(b["rider"]) != multiplayer.get_remote_sender_id():
		return
	if not pos.is_finite() or not is_finite(dirx) or not is_finite(diry) or not _is_water(pos):
		return
	if (pos as Vector2).distance_to(b["pos"]) > BOAT_STEP_MAX:
		# 客户端算漂了/作弊瞬移：把服务端的位置打回去（0.5 秒节流，避免刷可靠包）。
		var now := Time.get_ticks_msec() / 1000.0
		if now - _boat_snap_at > 0.5:
			_boat_snap_at = now
			_broadcast_boat(index)
		return
	b["pos"] = pos
	b["moving"] = moving_now
	b["dirx"] = dirx
	b["diry"] = diry
	Net.note_received([index, pos, moving_now, dirx, diry])
	if not Net.is_offline():
		_boat_pose.rpc(index, pos, moving_now, dirx, diry)


## 服务端 -> 客户端：占用变化 / 上下船落点 / 新玩家补发的船位（可靠）。
@rpc("authority", "call_remote", "reliable", 0)
func _boat_rider(index: int, rider: int, pos: Vector2, dirx: float, diry: float) -> void:
	if index < 0 or index >= _boats.size():
		return
	var b: Dictionary = _boats[index]
	b["rider"] = rider
	b["pos"] = pos
	b["moving"] = false
	b["dirx"] = dirx
	b["diry"] = diry
	if index == _my_boat:
		if rider == Net.my_id():
			_boat_confirmed = true
			_boat_wait = 0.0
		else:
			_abort_local_ride(false)
	var node: Node = _boat_nodes[index] if index < _boat_nodes.size() else null
	if node != null and is_instance_valid(node):
		node.call("snap", pos, dirx, diry)
		node.call("set_occupied", rider != 0)


## 服务端 -> 客户端：划船中的船位（不可靠有序，和房间姿态同一频道）。
## 自己正在划的那艘直接忽略，避免服务端回包把本地权威的位置拉着抖。
@rpc("authority", "call_remote", "unreliable_ordered", 3)
func _boat_pose(index: int, pos: Vector2, moving_now: bool, dirx: float, diry: float) -> void:
	if index < 0 or index >= _boats.size() or index == _my_boat:
		return
	var b: Dictionary = _boats[index]
	b["pos"] = pos
	b["moving"] = moving_now
	b["dirx"] = dirx
	b["diry"] = diry
	Net.note_received([index, pos, moving_now, dirx, diry])


## 沿真实路网放置路灯实体（位置由 OSM 路网一次性烘焙到 assets/lamps.json）。
## 每盏是独立 Node2D 参与 y 排序（人走到灯后会被挡），并加入 props 组逃开透视墙判定。
func _setup_lamps() -> void:
	var objs := campus.get_node_or_null("Objects")
	if objs == null:
		return
	var f := FileAccess.open("res://assets/lamps.json", FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary and parsed.has("lamps")):
		return
	var lamp_script: GDScript = load("res://net/scenes/Lamp.gd")
	var lamps: Array = parsed["lamps"]
	for i in lamps.size():
		var p: Array = lamps[i]
		var node := Node2D.new()
		node.name = "lamp_%d" % i
		node.set_script(lamp_script)
		node.position = Vector2(float(p[0]), float(p[1]))
		node.add_to_group("props")
		objs.add_child(node)
		node.call("setup", 1.0 if i % 2 == 0 else -1.0)


func _spawn_npcs() -> void:
	var objs := campus.get_node_or_null("Objects")
	if objs == null:
		return
	var nav_grid: NavGrid = _build_nav_grid()
	for i in NPC_SPAWNS.size():
		var info: Dictionary = NPC_SPAWNS[i]
		var n: Node2D = NPC.instantiate()
		n.name = "npc_%d" % i
		n.position = (info["cell"] as Vector2) * TS
		n.set("display_name", str(info["name"]))
		n.set("hero_id", str(info["hero"]))
		n.set("radius", float(info["radius"]))
		n.set("move_scale", float(info["speed"]))
		n.set("phase_seed", float(i) * 1.9)
		n.set("nav", nav_grid)
		objs.add_child(n)


## 从 world.json 的几何（建筑 footprint+阴影、水面，桥面挖空）构建可走网格 + A* 寻路。
func _build_nav_grid() -> NavGrid:
	var f := FileAccess.open("res://assets/world.json", FileAccess.READ)
	if f == null:
		return null
	var parsed = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return null
	var ng := NavGrid.new()
	ng.build(parsed, TS)
	return ng


## 收集可透视的建筑。全部用**全局坐标**记录：
## players 被 reparent 进放大 2 倍的校园层时，Godot 自动补了 scale=0.5，
## 角色的 position 是半尺度局部坐标——拿它去比建筑的校园坐标会差 2 倍，
## 结果站在楼前（南侧）的人也被判成「在楼后」，楼被错误地变半透明（穿模错觉）。
func _collect_xray() -> void:
	_xray.clear()
	if campus == null:
		return
	var objs := campus.get_node_or_null("Objects")
	if objs == null:
		return
	for n in objs.get_children():
		if not (n is StaticBody2D):
			continue
		if n.is_in_group("props"):
			continue          # 小物件不做透视墙
		var spr: Sprite2D = n.get_node_or_null("Sprite")
		if spr == null or spr.texture == null:
			continue
		# 像素级精确判定：缓存楼的贴图数据，每帧采样「玩家脚下那一点」
		# 对应贴图像素的 alpha。alpha>0 = 楼的这个像素真的会画在人身上。
		# 之前的贴图包围盒 / footprint x 范围都太粗：楼角、立面挤出、透明边距
		# 都会把站在楼旁的人误判成被挡，整栋楼莫名变透明（穿模错觉）。
		var img := spr.texture.get_image()
		if img.is_compressed():
			img.decompress()
		# 楼体材质：透视窗 + 夜间压暗 + 窗光（窗光必须画在这里，才能跟着楼一起参与
		# y 排序、被前面的楼挡住；挂在独立 CanvasLayer 上就会永远显示在最上层）
		var mat := ShaderMaterial.new()
		mat.shader = XRAY_SHADER
		mat.set_shader_parameter("tex_size", Vector2(img.get_width(), img.get_height()))
		mat.set_shader_parameter("hole_radius", Vector2(XRAY_RX, XRAY_RY))
		mat.set_shader_parameter("hole_alpha", XRAY_HOLE_ALPHA)
		mat.set_shader_parameter("strength", 0.0)
		mat.set_shader_parameter("glow_tex", _glow_tex_for(spr))
		mat.set_shader_parameter("glow_strength", 0.0)
		mat.set_shader_parameter("night_alpha", 0.0)
		mat.set_shader_parameter("night_color", Color(0.03, 0.05, 0.12))
		spr.material = mat
		_xray.append({
			"spr": spr,
			"img": img,
			"mat": mat,
			"tl": spr.get_global_transform() * spr.offset,   # 贴图左上角（全局）
			"scale": spr.global_scale.x,                     # 均匀缩放
			"foot": (n as Node2D).global_position.y,         # 楼脚线（footprint 南缘）
			"a": 0.0,                                        # 0=实心，1=完全挖开
		})
		spr.modulate.a = 1.0


## 楼体 Sprite 对应的烘焙窗光贴图（buildings/b{i}.png → assets/glow_winb_{i}.png）。
## 找不到就给一张 1×1 全透明，保证 shader 的 sampler 总有东西可采。
func _glow_tex_for(spr: Sprite2D) -> Texture2D:
	if spr.texture != null:
		var stem := spr.texture.resource_path.get_file().get_basename().trim_prefix("b")
		if stem.is_valid_int():
			var p := "res://assets/glow_winb_%s.png" % stem
			if ResourceLoader.exists(p):
				return load(p) as Texture2D
	if _glow_tex_empty == null:
		var im := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		im.fill(Color(0, 0, 0, 0))
		_glow_tex_empty = ImageTexture.create_from_image(im)
	return _glow_tex_empty


# ---------------------------------------------------------------- 昼夜
## 搭建夜幕叠加层与夜灯层。两层都是独立 CanvasLayer（有自己的画布），
## 所以既不参与校园的 y-sort，也不会被任何乘色节点影响——夜灯要的是「真亮」。
func _setup_daynight() -> void:
	_dn = DayNight
	# 夜幕：全屏矩形 + shader。shader 会采样「格子光照图」，被路灯照到的地方
	# 夜幕变薄（露出底下的砖路/草地），没照到的地方照常压暗 —— 路灯就真的"点亮附近"了。
	_night_dark = CanvasLayer.new()
	_night_dark.name = "NightDark"
	_night_dark.layer = 1

	_light_tex = _build_lightmap()

	_night_dark_rect = ColorRect.new()
	_night_dark_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_night_dark_rect.color = Color(1, 1, 1, 1)
	_night_dark_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _light_tex != null:
		_dark_mat = ShaderMaterial.new()
		_dark_mat.shader = load("res://net/shaders/night_dark.gdshader") as Shader
		_dark_mat.set_shader_parameter("lightmap", _light_tex)
		_dark_mat.set_shader_parameter("dark_color", _dn.overlay_color() if _dn != null else Color(0.02, 0.05, 0.14, 1.0))
		_dark_mat.set_shader_parameter("night_alpha", 0.0)
		_dark_mat.set_shader_parameter("world_origin", _world_origin)
		_dark_mat.set_shader_parameter("world_size", _world_size)
		_night_dark_rect.material = _dark_mat
	elif _dn != null:
		# 兜底：没有光照图就退回原来的均匀压暗
		_night_dark_rect.color = _dn.overlay_color()
		_night_dark_rect.modulate.a = 0.0
	_night_dark.add_child(_night_dark_rect)

	# 路灯照亮区的暖色补光（add）：灯脚下的路面偏暖黄，向外渐隐
	_night_warm_rect = ColorRect.new()
	_night_warm_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_night_warm_rect.color = Color(1, 1, 1, 1)
	_night_warm_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _light_tex != null:
		_warm_mat = ShaderMaterial.new()
		_warm_mat.shader = load("res://net/shaders/night_light.gdshader") as Shader
		_warm_mat.set_shader_parameter("lightmap", _light_tex)
		_warm_mat.set_shader_parameter("strength", 0.0)
		_warm_mat.set_shader_parameter("world_origin", _world_origin)
		_warm_mat.set_shader_parameter("world_size", _world_size)
		_night_warm_rect.material = _warm_mat
	else:
		_night_warm_rect.modulate.a = 0.0
	_night_dark.add_child(_night_warm_rect)
	add_child(_night_dark)

	# 夜灯：独立画布 + 一个跟随相机的根节点，里面挂每栋楼的暖光
	var glow_layer := CanvasLayer.new()
	glow_layer.name = "NightGlow"
	glow_layer.layer = 2
	_glow_root = Node2D.new()
	glow_layer.add_child(_glow_root)
	add_child(glow_layer)

	# 楼名标注抬到夜幕之上，夜里也看得清
	if labels != null and is_instance_valid(labels):
		labels.layer = 3

	_lamp_tex = _make_lamp_light_texture()
	_collect_glows()


# ---------------------------------------------------------------- MC 式格子光照图
## 照搬 Minecraft 火把的光照算法：光源有亮度等级（火把 14），向四邻 flood-fill 传播，
## 每走一格衰减固定等级、取最大值。我们世界本来就是 8px 一格，所以直接烘一张
## 「一个光照单元 = 一个像素」的光照图（LM_UNIT 格合成一单元，省 4 倍开销）。
## 夜幕 shader 采样它：有光 → 夜幕变薄 → 砖路/草地露出本色，就是"路灯点亮了附近"；
## 没光 → 照常压暗成夜色。结果缓存到 user://，改灯位或调参记得升 LIGHTMAP_VER。
const LM_CACHE := "user://lightmap_v7.png"
const LM_UNIT := 2        # 一个光照单元 = 2 格（16 校园像素）
const LAMP_LEVEL := 14    # 路灯亮度等级（= MC 火把 14），灯与灯的光会连成一条光带
const LM_FALLOFF := 2     # 每传播一单元衰减的等级 → 有效半径 ≈ 7 单元 = 14 格

## 建筑占地掩码：落在楼体 footprint 多边形内的光照单元标记为 1（挡光）。
## 光不能进入、也不能穿过这些单元 —— 楼会投下一片阴影，楼内院/楼背后保持夜里该有的黑。
func _building_block_mask(gw: int, gh: int) -> PackedByteArray:
	var blocked := PackedByteArray()
	blocked.resize(gw * gh)
	blocked.fill(0)
	var wf := FileAccess.open("res://assets/world.json", FileAccess.READ)
	if wf == null:
		return blocked
	var wd = JSON.parse_string(wf.get_as_text())
	if not (wd is Dictionary):
		return blocked
	var blist := (wd as Dictionary).get("buildings", []) as Array
	for b in blist:
		var poly := (b as Dictionary).get("poly", []) as Array
		if poly.size() < 3:
			continue
		var pts := PackedVector2Array()
		var minx := 1e9
		var maxx := -1e9
		var miny := 1e9
		var maxy := -1e9
		for p in poly:
			var vx := float((p as Array)[0])
			var vy := float((p as Array)[1])
			pts.append(Vector2(vx, vy))
			minx = minf(minx, vx)
			maxx = maxf(maxx, vx)
			miny = minf(miny, vy)
			maxy = maxf(maxy, vy)
		var gx0 := int(maxf(0.0, floorf(minx / float(LM_UNIT))))
		var gx1 := int(minf(float(gw - 1), floorf(maxx / float(LM_UNIT))))
		var gy0 := int(maxf(0.0, floorf(miny / float(LM_UNIT))))
		var gy1 := int(minf(float(gh - 1), floorf(maxy / float(LM_UNIT))))
		for gy in range(gy0, gy1 + 1):
			for gx in range(gx0, gx1 + 1):
				var idxc := gy * gw + gx
				if blocked[idxc] != 0:
					continue
				if _point_in_poly(
						Vector2((float(gx) + 0.5) * float(LM_UNIT),
								(float(gy) + 0.5) * float(LM_UNIT)), pts):
					blocked[idxc] = 1
	return blocked


## 建筑「屏幕阴影」掩码：楼是 2.5D 挤出的，它在屏幕上盖住的地面 = footprint
## + 屋顶向北挤出 hp 格的那一条带（一一对应：屏幕上楼的每个像素，反算回地面平面
## 都落在这条带里）。夜幕/暖光是全屏层，靠「屏幕像素 → 地面坐标」采样光照图，
## 所以如果不把这条带屏蔽掉，楼后面被路灯照亮的路面就会整片糊在楼墙和屋顶上
## —— 就是之前看到的「楼在发光 / 光斑形状跟楼对不上」。
## 逐列求 footprint 的上下沿，再向北扩展 hp，凹形楼（L 形）的缺口不会被误伤。
func _building_shadow_mask(gw: int, gh: int) -> PackedByteArray:
	var sh := PackedByteArray()
	sh.resize(gw * gh)
	sh.fill(0)
	var wf := FileAccess.open("res://assets/world.json", FileAccess.READ)
	if wf == null:
		return sh
	var wd = JSON.parse_string(wf.get_as_text())
	if not (wd is Dictionary):
		return sh
	var blist := (wd as Dictionary).get("buildings", []) as Array
	for b in blist:
		var bd := b as Dictionary
		var poly := bd.get("poly", []) as Array
		if poly.size() < 3:
			continue
		var pts := PackedVector2Array()
		var minx := 1e9
		var maxx := -1e9
		var miny := 1e9
		var maxy := -1e9
		for p in poly:
			var vx := float((p as Array)[0])
			var vy := float((p as Array)[1])
			pts.append(Vector2(vx, vy))
			minx = minf(minx, vx)
			maxx = maxf(maxx, vx)
			miny = minf(miny, vy)
			maxy = maxf(maxy, vy)
		var gx0 := int(clampf(floorf(minx / float(LM_UNIT)), 0.0, float(gw - 1)))
		var gx1 := int(clampf(floorf(maxx / float(LM_UNIT)), 0.0, float(gw - 1)))
		var gy0 := int(clampf(floorf(miny / float(LM_UNIT)), 0.0, float(gh - 1)))
		var gy1 := int(clampf(floorf(maxy / float(LM_UNIT)), 0.0, float(gh - 1)))
		# 每一列 footprint 覆盖的单元范围（col_lo=-1 表示该列没有楼）
		var col_lo := PackedInt32Array()
		var col_hi := PackedInt32Array()
		col_lo.resize(gw)
		col_hi.resize(gw)
		for i in gw:
			col_lo[i] = -1
			col_hi[i] = -1
		for gx in range(gx0, gx1 + 1):
			for gy in range(gy0, gy1 + 1):
				if _point_in_poly(
						Vector2((float(gx) + 0.5) * float(LM_UNIT),
								(float(gy) + 0.5) * float(LM_UNIT)), pts):
					if col_lo[gx] < 0:
						col_lo[gx] = gy
					col_hi[gx] = gy
		# 屋顶挤出高度（格）→ 向北（y 减小）扩展多少单元；+1 单元当安全余量
		var ext := int(ceilf(float(bd.get("hp", 0.0)) / float(LM_UNIT))) + 1
		for gx in range(gx0, gx1 + 1):
			if col_lo[gx] < 0:
				continue
			var y0 := maxi(0, col_lo[gx] - ext)
			var y1 := mini(gh - 1, col_hi[gx])
			for gy in range(y0, y1 + 1):
				sh[gy * gw + gx] = 1
	return sh


## 射线法判点在多边形内（格坐标）
func _point_in_poly(pt: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var pi: Vector2 = poly[i]
		var pj: Vector2 = poly[j]
		if ((pi.y > pt.y) != (pj.y > pt.y)) and \
				(pt.x < (pj.x - pi.x) * (pt.y - pi.y) / (pj.y - pi.y) + pi.x):
			inside = not inside
		j = i
	return inside


func _build_lightmap() -> Texture2D:
	var TS := 8.0
	var sc: float = campus.scale.x if campus != null else 1.0
	var gw := int(ceil(424.0 / float(LM_UNIT)))
	var gh := int(ceil(800.0 / float(LM_UNIT)))
	_world_origin = campus.to_global(Vector2(0.0, 0.0)) if campus != null else Vector2.ZERO
	_world_size = Vector2(float(gw * LM_UNIT) * TS * sc, float(gh * LM_UNIT) * TS * sc)
	var cache := ProjectSettings.globalize_path(LM_CACHE)
	if FileAccess.file_exists(LM_CACHE):
		var im := Image.load_from_file(cache)
		if im != null and im.get_width() == gw and im.get_height() == gh:
			print("[Arena] 光照图命中缓存 ", LM_CACHE)
			return ImageTexture.create_from_image(im)
	var grid := PackedByteArray()
	grid.resize(gw * gh)
	grid.fill(0)
	var queue := PackedInt32Array()
	# 建筑占地挡光（MC 里不透明方块会阻断光照）：否则光会穿过楼体，
	# 把楼内院、楼背后这些「本该被楼挡住」的地面照亮，夜里就整片露出来。
	var blocked := _building_block_mask(gw, gh)
	var lf := FileAccess.open("res://assets/lamps.json", FileAccess.READ)
	if lf != null:
		var parsed = JSON.parse_string(lf.get_as_text())
		var arr: Array = []
		if parsed is Dictionary and parsed.has("lamps"):
			arr = parsed["lamps"] as Array
		elif parsed is Array:
			arr = parsed as Array
		var unit_px := TS * float(LM_UNIT)
		for lp in arr:
			var p: Array = lp as Array
			if p == null or p.size() < 2:
				continue
			var gx := int(float(p[0]) / unit_px)
			var gy := int(float(p[1]) / unit_px)
			if gx < 0 or gy < 0 or gx >= gw or gy >= gh:
				continue
			var idx := gy * gw + gx
			if blocked[idx] != 0:
				continue
			if int(grid[idx]) < LAMP_LEVEL:
				grid[idx] = LAMP_LEVEL
				queue.append(idx)
	# flood-fill 传播（MC 的光照更新：邻格 = 本格 - 衰减，只有更亮才写入并继续扩散）
	var head := 0
	var nq := queue.size()
	while head < nq:
		var idx: int = queue[head]
		head += 1
		var v := int(grid[idx]) - LM_FALLOFF
		if v <= 0:
			continue
		var x := idx % gw
		var y := idx / gw
		if x > 0 and blocked[idx - 1] == 0 and int(grid[idx - 1]) < v:
			grid[idx - 1] = v
			queue.append(idx - 1)
			nq += 1
		if x + 1 < gw and blocked[idx + 1] == 0 and int(grid[idx + 1]) < v:
			grid[idx + 1] = v
			queue.append(idx + 1)
			nq += 1
		if y > 0 and blocked[idx - gw] == 0 and int(grid[idx - gw]) < v:
			grid[idx - gw] = v
			queue.append(idx - gw)
			nq += 1
		if y + 1 < gh and blocked[idx + gw] == 0 and int(grid[idx + gw]) < v:
			grid[idx + gw] = v
			queue.append(idx + gw)
			nq += 1
	# 轻度平滑（等价 MC 的 smooth lighting）：横竖各一次 1-2-1，去掉格子棱角
	var tmp := PackedFloat32Array()
	tmp.resize(gw * gh)
	for y in gh:
		for x in gw:
			var c0 := float(grid[y * gw + x])
			var lv_l := c0 if x == 0 else float(grid[y * gw + x - 1])
			var lv_r := c0 if x + 1 >= gw else float(grid[y * gw + x + 1])
			tmp[y * gw + x] = (lv_l + c0 * 2.0 + lv_r) * 0.25
	for y in gh:
		for x in gw:
			var c0 := float(tmp[y * gw + x])
			var lv_u := c0 if y == 0 else float(tmp[(y - 1) * gw + x])
			var lv_d := c0 if y + 1 >= gh else float(tmp[(y + 1) * gw + x])
			grid[y * gw + x] = int(round((lv_u + c0 * 2.0 + lv_d) * 0.25))
	# g 通道 = 「这块地面在屏幕上看得见」= 1 - 建筑屏幕阴影（footprint + 屋顶挤出带）。
	# 夜幕/暖光只有在这一类格子上才被挖薄，楼墙与屋顶因此绝不会糊上楼后的路灯光。
	# 直接拼像素缓冲（set_pixel 写多通道在这版引擎上不可靠，g 通道会被丢）。
	var shadow := _building_shadow_mask(gw, gh)
	var vis := PackedFloat32Array()
	vis.resize(gw * gh)
	for y in gh:
		for x in gw:
			# 3×3 均值柔化：阴影边界从「2 格的硬角」变成一格渐变，楼脚不至于割手
			var acc := 0.0
			var cnt := 0
			for dy in range(-1, 2):
				var yy := y + dy
				if yy < 0 or yy >= gh:
					continue
				for dx in range(-1, 2):
					var xx := x + dx
					if xx < 0 or xx >= gw:
						continue
					acc += float(shadow[yy * gw + xx])
					cnt += 1
			vis[y * gw + x] = 1.0 - acc / float(cnt)
	var px := PackedByteArray()
	px.resize(gw * gh * 4)
	for y in gh:
		for x in gw:
			var idxc := y * gw + x
			var lv: float = clampf(float(grid[idxc]) / 15.0, 0.0, 1.0)
			lv = pow(lv, 1.15)          # 略压暗部、抬亮部，让光池边界清楚又不生硬
			var o := idxc * 4
			var b := int(round(clampf(lv, 0.0, 1.0) * 255.0))
			px[o] = b
			px[o + 1] = int(round(clampf(vis[idxc], 0.0, 1.0) * 255.0))
			px[o + 2] = b
			px[o + 3] = 255
	var img := Image.create_from_data(gw, gh, false, Image.FORMAT_RGBA8, px)
	img.save_png(cache)
	print("[Arena] 光照图已生成 ", gw, "x", gh, " → ", LM_CACHE)
	return ImageTexture.create_from_image(img)


## 生成一盏路灯的完整光斑（白图，运行时由 modulate 染成暖色）：
##   - 地面光池：灯杆底部一圈柔和椭圆暖光，模拟灯光铺在路面（最关键的"真实"元素）
##   - 灯头光晕：灯泡自身发出的小团柔光
##   - 向下洒光：灯头→地面之间一段柔和光柱，截面高斯淡出、无硬边（不像旧版的硬三角锥）
## 锚点 = 灯杆底部（贴图中心），挂到灯的世界坐标即可。
func _make_lamp_light_texture() -> Texture2D:
	var S := 192
	var img := Image.create(S, S, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var cx := float(S) * 0.5
	# 光池中心放在贴图正中心：Sprite 默认 centered=true，锚点=贴图中心=灯杆底部，
	# 这样地面光池正好落在灯杆脚下（之前放在贴图底部，会被按中心摆放而偏离灯杆）。
	var cyc := float(S) * 0.5
	var bulb_y := cyc - 56.0             # 灯泡（灯头）在光池上方 56px
	var pool_rx := 52.0                  # 地面光池横半径
	var pool_ry := 22.0                  # 地面光池纵半径（压扁，像贴地）
	for yy in S:
		for xx in S:
			var x := float(xx)
			var y := float(yy)
			var a := 0.0
			# 1) 灯脚下热点：地面「照亮」已由 MC 式光照图（night_dark shader）负责，
			#    这里只留一小团更亮的热区，避免两层光叠加过曝
			var pdx := (x - cx) / pool_rx
			var pdy := (y - cyc) / pool_ry
			var pd := pdx * pdx + pdy * pdy
			if pd <= 1.0:
				a = maxf(a, pow(1.0 - pd, 2.0) * 0.16)
			# 2) 灯头光晕：灯泡自身发光的小团柔光
			var bd := Vector2(x - cx, y - bulb_y).length() / 18.0
			if bd <= 1.0:
				a = maxf(a, pow(1.0 - bd, 1.5) * 0.9)
			# 3) 向下洒光：灯头→地面之间柔和光柱，截面高斯淡出、无硬边
			if y >= bulb_y and y <= cyc:
				var t: float = (y - bulb_y) / (cyc - bulb_y)   # 0=灯头 1=地面
				# 用显式算式代替 lerp（Godot 4.7 的全局 lerp 返回 Variant，会破坏类型推断）
				var half_w: float = 9.0 + (pool_rx * 0.82 - 9.0) * t  # 向下张开
				var dx: float = absf(x - cx)
				if half_w > 0.001 and dx <= half_w:
					var ax: float = 1.0 - dx / half_w             # 横向高斯淡出
					var vert: float = (1.0 - t) * 0.5 + 0.18       # 越靠灯头越亮
					a = maxf(a, vert * ax * ax * 0.30)
			if a > 0.0:
				img.set_pixel(xx, yy, Color(1.0, 1.0, 1.0, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


## 夜灯：路灯光（地面光池 + 灯头光晕）。
## 楼的窗光不在这里 —— 它是楼体 shader 的一部分（见 building_xray.gdshader），
## 这样被前面的楼挡住时窗光也会一起被挡住。
## 路灯的 position 用「世界全局坐标」，_update_daynight 里 _glow_root 的相机变换
## 把它映射到屏幕——镜头移动时灯始终贴在世界里的灯杆上。
func _collect_glows() -> void:
	if campus == null or _glow_root == null:
		return
	# 路灯光：整组（地面光池+灯头光晕）贴在灯杆底部的世界坐标
	var lf := FileAccess.open("res://assets/lamps.json", FileAccess.READ)
	if lf != null:
		var parsed = JSON.parse_string(lf.get_as_text())
		if parsed is Dictionary and parsed.has("lamps"):
			for lp in parsed["lamps"]:
				var p: Array = lp
				var base: Vector2 = campus.to_global(Vector2(float(p[0]), float(p[1])))
				_add_lamp_light(base)


## 在 _glow_root 下挂一盏路灯的完整光（柔和地面光池 + 灯头光晕 + 洒光柱），锚在灯杆底部。
## 纹理本身已把三种光画在一起，运行时只改整体亮度（含轻微闪烁）。
func _add_lamp_light(world_pos: Vector2) -> void:
	var sp := Sprite2D.new()
	sp.texture = _lamp_tex
	sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	sp.position = world_pos
	sp.scale = Vector2(0.6, 0.6)
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	sp.material = mat
	sp.modulate = Color(1.0, 0.80, 0.45)
	sp.modulate.a = 0.0
	_glow_root.add_child(sp)
	_lamp_glows.append({"sprite": sp, "phase": randf() * TAU})


## 每帧：夜幕深浅 + 夜灯跟随相机 + 灯的亮度。
## _glow_root 的变换 = 「世界坐标 → 屏幕坐标」的相机投影，
## 所以子节点只要 position = 楼的世界坐标，灯就会牢牢贴在楼身上。
func _update_daynight() -> void:
	if _night_dark == null or _glow_root == null:
		return
	if _dn == null:
		_dn = DayNight
	if _dn == null:
		return
	# 夜幕：交给 shader（按光照图挖薄），没有光照图时退回原来的整体调 alpha
	var night_a := float(_dn.overlay_alpha())
	if _dark_mat != null:
		_dark_mat.set_shader_parameter("night_alpha", night_a)
	elif _night_dark_rect != null:
		_night_dark_rect.modulate.a = night_a
	var cam := get_viewport().get_camera_2d()
	if cam != null:
		var vs := get_viewport().get_visible_rect().size
		var vc := vs * 0.5
		var z: Vector2 = cam.zoom
		var c: Vector2 = cam.get_screen_center_position()
		var ox := vc.x - c.x * z.x
		var oy := vc.y - c.y * z.y
		# 世界坐标 → 屏幕坐标 的投影（x 轴=z.x, y 轴=z.y, 原点=(ox,oy)）
		_glow_root.global_transform = Transform2D(Vector2(z.x, 0.0), Vector2(0.0, z.y), Vector2(ox, oy))
		# 夜幕/暖光是屏幕空间的矩形，shader 需要相机参数把屏幕像素反算回世界坐标
		for mat in [_dark_mat, _warm_mat]:
			if mat == null:
				continue
			(mat as ShaderMaterial).set_shader_parameter("cam_center", c)
			(mat as ShaderMaterial).set_shader_parameter("zoom", z)
			(mat as ShaderMaterial).set_shader_parameter("screen_size", vs)
	var g := float(_dn.glow_strength())
	# 路灯照亮区染一层暖黄（灯脚下最暖，向外渐隐）
	if _warm_mat != null:
		_warm_mat.set_shader_parameter("strength", g * 0.36)
	# 楼体：夜幕压暗 + 窗光都走楼自己的 shader（这样窗光跟着楼参与 y 排序，
	# 被前面的楼挡住时一起被挡），每帧按当前夜色把两个参数推过去
	var nc: Color = _dn.overlay_color()
	for item in _xray:
		var bm: ShaderMaterial = item["mat"]
		bm.set_shader_parameter("night_alpha", night_a)
		bm.set_shader_parameter("night_color", nc)
		bm.set_shader_parameter("glow_strength", g)
	# 路灯：在窗户光基础上加一点正弦闪烁，更像真实气体/LED 灯
	var tnow := Time.get_ticks_msec() / 1000.0
	for item in _lamp_glows:
		var fl := 0.85 + 0.15 * sin(tnow * 3.0 + float(item["phase"]))
		(item["sprite"] as Sprite2D).modulate.a = g * fl


func _process(delta: float) -> void:
	_cat_msg_t = maxf(0.0, _cat_msg_t - delta)
	_update_boat_control(delta)
	_update_boats()
	_update_bridge_z()
	_update_xray(delta)
	_update_daynight()
	_update_interact_hint(delta)
	_place_hint_above_player()
	_update_floor_visibility()
	_update_notice(delta)
	_place_door_plates()
	_process_vk_reposition()


## 有人被楼盖住 → 在楼身上挖一个「透视窗」（只透玩家周围一小块，楼体其余实心），
## 同时把被挡的人也调淡（经典 RPG 做法：位置一眼看清）。
func _update_xray(delta: float) -> void:
	if _xray.is_empty() or players == null:
		return
	var avs := players.get_children()
	var hidden: Dictionary = {}
	for item in _xray:
		var target: float = 0.0        # 0=实心
		var img: Image = item["img"]
		var tl: Vector2 = item["tl"]
		var sc: float = item["scale"]
		for a in avs:
			if not (a is Node2D):
				continue
			# 用全局坐标和建筑比：坐标空间已统一（Players 空间 = Objects 空间）。
			# 判定点取「胸口」而不是脚：脚被楼角擦到一两像素不该开窗。
			var gp: Vector2 = (a as Node2D).global_position - Vector2(0, 16)
			# 玩家在楼的南侧（y 更大）时，楼画在人前面，不需要开窗
			if gp.y > item["foot"]:
				continue
			var px := Vector2i((gp - tl) / sc)
			if px.x < 0 or px.y < 0 or px.x >= img.get_width() or px.y >= img.get_height():
				continue
			if img.get_pixelv(px).a > 0.1:
				target = 1.0
				hidden[a] = true
				# 透视窗跟着人走：把玩家位置换算成贴图局部像素坐标
				(item["mat"] as ShaderMaterial).set_shader_parameter(
					"hole_center", Vector2(gp - tl) / sc)
		# 平滑过渡：走过楼边时不该「啪」一下开窗
		var cur: float = float(item.get("a", 0.0))
		cur = move_toward(cur, target, delta * 4.0)
		item["a"] = cur
		(item["mat"] as ShaderMaterial).set_shader_parameter("strength", cur)

	for a in avs:
		if a.has_method("set_occluded"):
			a.set_occluded(hidden.has(a))


## 底图（发布级美术版）：
##   地面降噪 → 低分辨率软阴影 → 2px/格树冠层 → 4px/格屋顶受光渐变 + 2px 描边 → 暗角。
## 分层绘制是为了性能：阴影/树在低分辨率画再放大，自带柔边；建筑在 4px/格保持锐利。
func _build_minimap_texture() -> Texture2D:
	var w: int = int(CELLS.x) * MINI_PXP
	var h: int = int(CELLS.y) * MINI_PXP
	if FileAccess.file_exists(MINIMAP_CACHE):
		var cached := Image.load_from_file(MINIMAP_CACHE)
		if cached != null and cached.get_width() == w and cached.get_height() == h:
			return ImageTexture.create_from_image(cached)

	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	out.fill(MapData.C_GROUND)
	_paint_ground(out)
	_paint_shadow(out)
	_paint_trees(out)
	_paint_buildings(out)
	_paint_vignette(out)
	out.save_png(MINIMAP_CACHE)
	return ImageTexture.create_from_image(out)


## 地面：拼接后缩到 1/2 再放大做一次降噪（保留道路/广场/湖水的大形，抹掉草地的沙粒噪点），
## 再轻微压暗降饱和，让建筑和道路从草地里跳出来。
func _paint_ground(out: Image) -> void:
	var chunk_cells: int = 1024 / int(TS)
	for cy in MapData.GROUND_ROWS:
		for cx in MapData.GROUND_COLS:
			var path := "res://assets/ground/g%d_%d.png" % [cx, cy]
			if not ResourceLoader.exists(path):
				continue
			var tex: Texture2D = load(path)
			if tex == null:
				continue
			var img := tex.get_image()
			if img == null:
				continue
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			var tw: int = maxi(1, int(round(img.get_width() / TS * MINI_PXP)))
			var th: int = maxi(1, int(round(img.get_height() / TS * MINI_PXP)))
			img.resize(tw, th, Image.INTERPOLATE_BILINEAR)
			out.blit_rect(img, Rect2i(0, 0, tw, th),
				Vector2i(cx * chunk_cells * MINI_PXP, cy * chunk_cells * MINI_PXP))
	var w := out.get_width()
	var h := out.get_height()
	out.resize(maxi(1, w / 2), maxi(1, h / 2), Image.INTERPOLATE_BILINEAR)
	out.resize(w, h, Image.INTERPOLATE_CUBIC)
	out.adjust_bcs(0.94, 1.03, 0.96)

	# 海天苑大楼中央庭院：草地 + 中央楼一圈步道（与 assets/haitian_courtyard.png 对齐）
	out.fill_rect(Rect2i(199 * MINI_PXP, 471 * MINI_PXP, 48 * MINI_PXP, 58 * MINI_PXP),
		Color("4a6f42"))
	out.fill_rect(Rect2i(205 * MINI_PXP, 480 * MINI_PXP, 36 * MINI_PXP, 34 * MINI_PXP),
		Color("b9a98a"))

	# 北门广场铺装 + 门址金点
	out.fill_rect(Rect2i(197 * MINI_PXP, 32 * MINI_PXP, 44 * MINI_PXP, 24 * MINI_PXP),
		Color("c9bda2"))
	for gx in range(197, 241, 2):
		out.fill_rect(Rect2i(gx * MINI_PXP, 32 * MINI_PXP, 1, 24 * MINI_PXP), Color("b3a78c"))
	for gy in range(32, 56, 2):
		out.fill_rect(Rect2i(197 * MINI_PXP, gy * MINI_PXP, 44 * MINI_PXP, 1), Color("b3a78c"))
	out.fill_rect(Rect2i(200 * MINI_PXP, 31 * MINI_PXP, 36 * MINI_PXP, 2 * MINI_PXP),
		Color("6f747a"))
	out.fill_rect(Rect2i(216 * MINI_PXP, 31 * MINI_PXP, 4 * MINI_PXP, 2 * MINI_PXP),
		Color("d6b45a"))

	# 图书馆前广场 + 喷泉
	_fill_disc(out, 223 * MINI_PXP, 390 * MINI_PXP, 13 * MINI_PXP, Color("c9bda2"))
	_fill_disc(out, 223 * MINI_PXP, 390 * MINI_PXP, 6 * MINI_PXP, Color("3f7fae"))
	_fill_disc(out, 223 * MINI_PXP, 390 * MINI_PXP, 2.2 * MINI_PXP, Color("9fd0e8"))

	# 东门「为国铸剑」纪念广场：切角铺装 + 中央石环（与 assets/props_plaza_east.png 对齐）
	out.fill_rect(Rect2i(380 * MINI_PXP, 331 * MINI_PXP, 27 * MINI_PXP, 27 * MINI_PXP),
		Color("d2c6ab"))
	for gx in range(380, 407, 2):
		out.fill_rect(Rect2i(gx * MINI_PXP, 331 * MINI_PXP, 1, 27 * MINI_PXP), Color("bfb39a"))
	for gy in range(331, 358, 2):
		out.fill_rect(Rect2i(380 * MINI_PXP, gy * MINI_PXP, 27 * MINI_PXP, 1), Color("bfb39a"))
	_fill_disc(out, 393 * MINI_PXP, 344 * MINI_PXP, 10.4 * MINI_PXP, Color("b3a68b"))
	_fill_disc(out, 393 * MINI_PXP, 344 * MINI_PXP, 9.0 * MINI_PXP, Color("d2c6ab"))


## 软阴影：1px/格 画楼体投影，再双线性放大到 4px/格——放大过程本身就产生了柔边，
## 比在高分辨率上做高斯模糊省几十倍。
func _paint_shadow(out: Image) -> void:
	var sh := Image.create(int(CELLS.x), int(CELLS.y), false, Image.FORMAT_RGBA8)
	sh.fill(Color(0, 0, 0, 0))
	var scol := Color(0.03, 0.05, 0.07, 0.55)
	for b in MapData.buildings():
		var poly: Array = b.get("poly", [])
		if poly.size() < 3:
			continue
		var pts := PackedVector2Array()
		for p in poly:
			var v: Vector2 = p
			pts.append(v + Vector2(1.4, 2.0))       # 光从左上打，影子往右下偏
		_fill_poly(sh, pts, scol)
	sh.resize(out.get_width(), out.get_height(), Image.INTERPOLATE_BILINEAR)
	out.blend_rect(sh, Rect2i(0, 0, out.get_width(), out.get_height()), Vector2i.ZERO)


## 树冠：2px/格 层上画「底盘 + 左上高光」两个圆，放大后自带柔边，收敛成低对比质感。
func _paint_trees(out: Image) -> void:
	var tp: int = 2
	var layer := Image.create(int(CELLS.x) * tp, int(CELLS.y) * tp, false, Image.FORMAT_RGBA8)
	layer.fill(Color(0, 0, 0, 0))
	for i in MapData.trees():
		var x: float = float(i.get("x", 0.0)) * tp
		var y: float = float(i.get("y", 0.0)) * tp
		var r: float = clampf(float(i.get("s", 2.0)) * tp * 0.72, 1.5, 5.5)
		var col: Color = MapData.C_TREE_A if int(i.get("sp", 0)) % 2 == 0 else MapData.C_TREE_B
		_fill_disc(layer, x, y, r, col)
		_fill_disc(layer, x - r * 0.32, y - r * 0.36, r * 0.52, col.lightened(0.18))
	layer.resize(out.get_width(), out.get_height(), Image.INTERPOLATE_BILINEAR)
	out.blend_rect(layer, Rect2i(0, 0, out.get_width(), out.get_height()), Vector2i.ZERO)


## 建筑：逐行做竖向受光渐变（上亮下暗），再描 2px 深色边——比单色平涂有体积感。
func _paint_buildings(out: Image) -> void:
	var w := out.get_width()
	var h := out.get_height()
	for b in MapData.buildings():
		var poly: Array = b.get("poly", [])
		if poly.size() < 3:
			continue
		var pts := PackedVector2Array()
		for p in poly:
			var v: Vector2 = p
			pts.append(v * MINI_PXP)
		var base: Color = MapData.roof_color(str(b.get("cat", "b")))
		if str(b.get("name", "")) == "海天苑大楼·中楼":
			base = Color("5f8f5a")        # 中楼是绿化屋顶
		var top_c := base.lightened(0.15)
		var bot_c := base.darkened(0.15)
		var miny := INF
		var maxy := -INF
		for p in pts:
			miny = minf(miny, p.y)
			maxy = maxf(maxy, p.y)
		var y0 := maxi(0, int(floor(miny)))
		var y1 := mini(h - 1, int(ceil(maxy)))
		var span := maxf(1.0, maxy - miny)
		var n := pts.size()
		for y in range(y0, y1 + 1):
			var col := top_c.lerp(bot_c, clampf((float(y) - miny) / span, 0.0, 1.0))
			var sy := float(y) + 0.5
			var xs: Array[float] = []
			for i in n:
				var a := pts[i]
				var bb := pts[(i + 1) % n]
				if (a.y <= sy and bb.y > sy) or (bb.y <= sy and a.y > sy):
					var tt := (sy - a.y) / (bb.y - a.y)
					xs.append(a.x + (bb.x - a.x) * tt)
			if xs.size() < 2:
				continue
			xs.sort()
			var k := 0
			while k + 1 < xs.size():
				var xa := clampi(int(round(xs[k])), 0, w - 1)
				var xb := clampi(int(round(xs[k + 1])), 0, w - 1)
				if xb > xa:
					out.fill_rect(Rect2i(xa, y, xb - xa, 1), col)
				k += 2
		_stroke_poly_thick(out, pts, MapData.C_OUTLINE, 2)


## 暗角：低分辨率算径向 alpha 再放大，边缘微微压暗，画面更聚焦。
func _paint_vignette(out: Image) -> void:
	var lw := 64
	var lh := 120
	var v := Image.create(lw, lh, false, Image.FORMAT_RGBA8)
	for y in lh:
		for x in lw:
			var nx := (float(x) + 0.5) / float(lw) * 2.0 - 1.0
			var ny := (float(y) + 0.5) / float(lh) * 2.0 - 1.0
			var d := sqrt(nx * nx + ny * ny) / 1.4142
			var a := clampf((d - 0.55) / 0.45, 0.0, 1.0)
			v.set_pixel(x, y, Color(0.03, 0.05, 0.08, a * 0.55))
	v.resize(out.get_width(), out.get_height(), Image.INTERPOLATE_BILINEAR)
	out.blend_rect(v, Rect2i(0, 0, out.get_width(), out.get_height()), Vector2i.ZERO)


## 实心圆（树冠）。逐像素画 + 边界裁剪，避免 set_pixel 越界。
func _fill_disc(img: Image, cx: float, cy: float, r: float, col: Color) -> void:
	var W := img.get_width()
	var H := img.get_height()
	var x0 := maxi(0, int(floor(cx - r)))
	var x1 := mini(W - 1, int(ceil(cx + r)))
	var y0 := maxi(0, int(floor(cy - r)))
	var y1 := mini(H - 1, int(ceil(cy + r)))
	var r2 := r * r
	for yy in range(y0, y1 + 1):
		var dy := float(yy) - cy
		for xx in range(x0, x1 + 1):
			var dx := float(xx) - cx
			if dx * dx + dy * dy <= r2:
				img.set_pixel(xx, yy, col)


## 扫描线填充多边形（支持凹多边形）。逐行用 fill_rect，比逐像素快得多。
func _fill_poly(img: Image, pts: PackedVector2Array, col: Color) -> void:
	var n := pts.size()
	if n < 3:
		return
	var miny := INF
	var maxy := -INF
	for p in pts:
		miny = minf(miny, p.y)
		maxy = maxf(maxy, p.y)
	var W := img.get_width()
	var y0 := maxi(0, int(floor(miny)))
	var y1 := mini(img.get_height() - 1, int(ceil(maxy)))
	for y in range(y0, y1 + 1):
		var sy := float(y) + 0.5
		var xs: Array[float] = []
		for i in n:
			var a := pts[i]
			var b := pts[(i + 1) % n]
			if (a.y <= sy and b.y > sy) or (b.y <= sy and a.y > sy):
				var t := (sy - a.y) / (b.y - a.y)
				xs.append(a.x + (b.x - a.x) * t)
		if xs.size() < 2:
			continue
		xs.sort()
		var k := 0
		while k + 1 < xs.size():
			var xa := clampi(int(round(xs[k])), 0, W - 1)
			var xb := clampi(int(round(xs[k + 1])), 0, W - 1)
			if xb > xa:
				img.fill_rect(Rect2i(xa, y, xb - xa, 1), col)
			k += 2


func _stroke_poly_thick(img: Image, pts: PackedVector2Array, col: Color, thick: int) -> void:
	var n := pts.size()
	for i in n:
		_line_thick(img, pts[i], pts[(i + 1) % n], col, thick)


## 整数 Bresenham 直线，可指定线宽（每个步进画 thick×thick 的方块）。
func _line_thick(img: Image, a: Vector2, b: Vector2, col: Color, thick: int) -> void:
	var W := img.get_width()
	var H := img.get_height()
	var x0 := int(round(a.x))
	var y0 := int(round(a.y))
	var x1 := int(round(b.x))
	var y1 := int(round(b.y))
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	while true:
		for oy in thick:
			for ox in thick:
				var px := x0 + ox
				var py := y0 + oy
				if px >= 0 and px < W and py >= 0 and py < H:
					img.set_pixel(px, py, col)
		if x0 == x1 and y0 == y1:
			break
		var e2 := err * 2
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy


## 世界外的底色（比纯黑柔和一点，走到地图边缘时不刺眼）
func _draw() -> void:
	draw_rect(Rect2(Vector2(-800, -800), Vector2(8600, 14600)), Color("151b21"))


## Server only: show every replicated world node to a peer whose world is ready.
func allow_peer(id: int) -> void:
	if not Net.is_server():
		return
	for node in get_tree().get_nodes_in_group("world_sync"):
		var sync: MultiplayerSynchronizer = node
		sync.set_visibility_for(id, true)
	# 新玩家进入世界时补发一遍船位：他进服之前别人可能已经把船划走了。
	if id != 1 and not Net.is_offline():
		for i in _boats.size():
			_boat_rider.rpc_id(id, i, int(_boats[i]["rider"]), _boats[i]["pos"],
				float(_boats[i]["dirx"]), float(_boats[i]["diry"]))


## Server only: create a player's avatar at a free spawn point.
func spawn_avatar(id: int) -> void:
	if not Net.is_server() or not Net.peers.has(id) or players.has_node(str(id)):
		return
	var avatar: CharacterBody2D = PLAYER.instantiate()
	avatar.name = str(id)
	# 按序号环形散开，避免两个人叠在同一点互相推挤。
	# 搜索槽位跟着房间上限走：以前写死 12，第 13 个人起就再也找不到空位，
	# 会一路落到 (0,0) 或和别人重叠。现在按 MAX_PLAYERS 展开足够多的环。
	var chosen: Vector2 = _spawn_point(0)
	for slot in range(Net.MAX_PLAYERS + 8):
		var candidate: Vector2 = _spawn_point(slot)
		var available: bool = true
		for existing in players.get_children():
			if (existing as Node2D).position.distance_to(candidate) < SPREAD * 0.8:
				available = false
				break
		if available:
			chosen = candidate
			break
		chosen = candidate      # 全满也至少用最后一个候选，别把新玩家丢到世界原点
	# 外环候选可能蹭到楼体或水面，螺旋找最近空地，保证不会出生就被卡住
	avatar.position = _find_safe(chosen)
	avatar.server_position = avatar.position
	avatar.server_state = {"seq": 0, "position": avatar.position}
	avatar.round_id = GameState.round_id
	avatar.hero_id = str(Net.peers.get(id, {}).get("hero", "adam"))
	players.add_child(avatar)


## 出生点：以开阔点为中心，第 2 人起按 8 个方向环绕散开（坐标是校园局部像素）。
## 环间步长要 > 「最小间距」SPREAD*0.8，否则相邻两环只差一点点、会被判定
## 为「离已有玩家太近」而整环作废，人一多就只能跳环，很快排满后重叠。
## 0.9*SPREAD = 72px > 0.8*SPREAD = 64px，正好保证每一环都能用。
func _spawn_point(slot: int) -> Vector2:
	var base: Vector2 = _spawn_cell() * TS
	if slot == 0:
		return base
	var k: int = (slot - 1) % 8
	var ring: int = (slot - 1) / 8
	var ang: float = float(k) * TAU / 8.0
	var rad: float = SPREAD * (1.0 + float(ring) * 0.9)
	return base + Vector2(cos(ang), sin(ang)) * rad


func remove_player(id: int) -> void:
	if not Net.is_server():
		return
	var avatar: Node = players.get_node_or_null(str(id))
	if avatar != null:
		avatar.queue_free()
	# 人掉线/退出时把他占的船释放掉，否则这艘船会永远显示「有人」
	_release_boats_of(id)


## Server only: 玩家在游戏里换外观时，把新的 hero_id 写进他的 avatar。
## hero_id 已在 SceneReplicationConfig 里（spawn + on_change），会自动同步到所有客户端。
func set_hero_of(id: int, hero: String) -> void:
	if not Net.is_server():
		return
	var avatar: Node = players.get_node_or_null(str(id))
	if avatar != null:
		avatar.hero_id = hero


func clear_run() -> void:
	if not Net.is_server():
		return
	for child in players.get_children():
		# Remove now so the next round cannot see old names this frame.
		players.remove_child(child)
		child.queue_free()
	# 回合清场：船上的人也没了，把所有船恢复成空船
	for i in _boats.size():
		if int(_boats[i]["rider"]) != 0:
			_boats[i]["rider"] = 0
			_boats[i]["moving"] = false
			_broadcast_boat(i)


# ---------------------------------------------------------------- 传送
## 网页版「点地图传送」的等价物。联机下位置是服务器权威，客户端只能请求，
## 由服务器把人放到位再同步回去（否则会被校正逻辑拉回原地）。

func request_teleport(world_pos: Vector2) -> void:
	if not Net.has_session():
		return
	if in_room:
		# 在房间内不允许从地图传到校园：会落到房间相机边界外、画面卡死。
		# 房间内全屏地图本就是「房间视图（不传送）」，这里再兜一层底。
		return
	if _my_boat >= 0:
		# 划船中不能从地图传送：船还停在原地，人突然回岸上会变成「幽灵划船」。
		return
	if Net.is_server():
		call_deferred("_do_teleport", Net.my_id(), world_pos)
	else:
		_teleport_request.rpc_id(1, world_pos)


@rpc("any_peer", "call_remote", "reliable", 0)
func _teleport_request(world_pos: Vector2) -> void:
	if not Net.is_server():
		return
	# 物理空间查询不能在 RPC 回调里直接做（会撞上物理刷写），延后一帧
	call_deferred("_do_teleport", multiplayer.get_remote_sender_id(), world_pos)


func _do_teleport(id: int, world_pos: Vector2) -> void:
	if not Net.is_server():
		return
	var avatar: Node = players.get_node_or_null(str(id))
	if avatar == null or not avatar.has_method("teleport_to"):
		return
	var local: Vector2 = players.to_local(world_pos)
	var safe: Vector2 = _find_safe(local)
	avatar.teleport_to(safe)
	if OS.has_environment("XGD_DEBUG"):
		print("[tp] id=%d world=%s → local=%s → safe=%s" % [id, world_pos, local, safe])


## 目标点压在建筑或水面上时，螺旋往外找最近的空地（步长 1 格）
func _find_safe(local: Vector2) -> Vector2:
	var space := get_world_2d().direct_space_state
	for ring in range(0, 24):
		var n: int = 1 if ring == 0 else 12
		for i in n:
			var a: float = float(i) * TAU / float(n)
			var p: Vector2 = local + Vector2(cos(a), sin(a)) * (float(ring) * TS)
			var params := PhysicsPointQueryParameters2D.new()
			params.position = players.to_global(p)
			params.collision_mask = 1
			params.collide_with_areas = false
			params.collide_with_bodies = true
			if space.intersect_point(params, 1).is_empty():
				return p
	return local



# ---------------------------------------------------------------- 房间（建筑内景）
## 房间不切场景，而是挂在校园北界之外很远的空地上（世界格坐标）。
## 这样相机、y 排序、碰撞、多人同步全都沿用原来那一套，玩家只是被传送过去；
## 也不用把玩家容器搬来搬去 —— 搬了就得重设 MultiplayerSpawner 的 spawn_path，
## 还会牵出一堆坐标空间的问题。
##
## 进出房间目前绑在 R 键上，等「走到宿舍门口自动进」做好了再换成触发器。
const RoomScript := preload("res://net/scenes/Room.gd")
signal room_changed(inside: bool)

const ROOM_ORIGIN := Vector2(0, -1500)      # 格：校园北界（y=0）之外
## 走到宿舍楼旁多少格以内显示「按 E 进入」
const DOOR_RADIUS := 8.0
## 门口检测跑得多勤（不必每帧扫 20 栋楼）
const DOOR_CHECK_HZ := 8.0
## 室内视距。房间只有 910×754 px，比视口（1280/zoom）还小 ——
## 用校园那档 1.2 进去，整间房缩在屏幕中间、四周露黑，人也只有几个像素。
## 1.9 让房间填满屏幕，人物约 34px 高，坐着/站着一眼能分清。
const ROOM_ZOOM := 2.1
const CAMPUS_ZOOM := 1.05
## 离座位多近才能坐（像素，campus/Objects 局部空间 = 8px/格）。
## 这个值必须**小于「椅子中心到隔间开口」的距离**（约 25px），否则站在隔间里
## 任何位置按 E 都是「坐下」，走出去也一直在坐下 —— 表现就是「人被卡在宿舍空间里」。
## 22px ≈ 2.75 格：贴着椅子能坐，退到隔间门口就是「离开」。
const SEAT_RADIUS := 22.0
## 座位码 ≥ 这个值表示「躺着」（5..8），和 PlayerAvatar.LIE_BASE 一致
const LIE_SEAT_CODE := 5

## ── 房间门（私人空间的门禁） ──────────────────────────────────────────
## 站到门口这么近（像素）门就往开滑；走开到这个距离再合上。两个阈值分开是
## 为了留一段滞回 —— 只用一个值的话，人站在临界线上门会疯狂开合。
const DOOR_OPEN_R := 26.0
const DOOR_CLOSE_R := 40.0
## 站得离别人多近可以按 E 加好友（3 格）。比这个远就还是原来的门牌/座椅交互。
const FRIEND_RANGE := 24.0

var room: Node2D
var in_room := false
var _return_cell := Vector2.ZERO
## 本地玩家相机原来的边界。相机被限制在校园范围内（0..6784 / 0..12800），
## 而房间远在校园之外 —— 不临时放开的话，画面会死死卡在校园边缘不动。
var _cam_limit := {}
## 可进入的建筑：[{name, rect}]。rect 是格坐标的包围盒外扩前原尺寸。
var _dorms: Array = []
var _near_dorm := ""
## 站在旁边的另一个玩家（加好友用），空字典 = 旁边没人
var _near_buddy: Dictionary = {}
var _room_title := ""
var _door_hint: Button          # 提示兼交互按钮（手机上点它就是按 E）
var _voice_btn: Button          # 坐着时右下角的「进语音」按钮（只在 B1 组队房间里出现）
var _voice_link_now := ""       # _voice_btn 当前指向的 OOPZ 链接（V 键用它）
var _door_clock := 0.0
## 座位：[{pos: Vector2(campus 局部坐标), face: String, kind: String, room: int}]
var _seats_campus: Array = []
var _seats_room: Array = []
var _near_seat: Dictionary = {}

# ── 猫咪互动 ────────────────────────────────────────────────────────────────
const CAT_PET_R := 26.0        # 能摸到猫的距离（校园局部像素）
const ADOPT_PATH := "user://adopted_cats.json"
const ADOPT_MAX := 4           # 猫窝最多养几只
const ADOPT_PETS := 3          # 摸满几次可以领养（与 Cat.gd 的 can_adopt() 一致）
var _wildlife_ground: Node2D = null   # campus/Objects/WildlifeGround，猫都在它下面
var _cat_nav: NavGrid = null          # 撒锚点 + 给猫做漫游碰撞判定
var _cat_msg := ""             # 摸猫后短暂占住提示条的反馈文字
var _cat_msg_t := 0.0
var _adopted: Array = []       # [{name, skin}]，本地存档，不进联机协议
var _adopt_loaded := false
var _adopt_layer: CanvasLayer = null
var _adopt_panel: PanelContainer = null
var _adopt_edit: LineEdit = null
var _adopt_cat: Node2D = null

# ── 小船状态 ────────────────────────────────────────────────────────────────
## 每艘船的服务端权威状态：[{pos: Vector2(campus 局部坐标), rider: peer id, moving: bool, dirx: float, diry: float}]
## 服务端改 rider/pos 后广播；客户端只做表现。离线单机时本机就是服务端。
var _boats: Array = []
## 本地表现节点（专用服务器不建视觉，这个表为空）
var _boat_nodes: Array = []
## 水域掩码（1 = 水格），从 world.json 的 water 矩形生成；服务端校验与本地划船共用
var _water_mask := PackedByteArray()
var _water_w: int = 0
var _water_h: int = 0
## 本机玩家正在划的船（-1 = 不在船上）
var _my_boat: int = -1
## 服务端是否已确认我上船（客户端本地先上、等服务端回包；超时则撤回）
var _boat_confirmed: bool = false
var _boat_wait: float = 0.0
## 上船前站的岸上位置，服务端拒绝/超时时退回去
var _boat_return_pos := Vector2.ZERO
## 船位回传节流
var _boat_send_clock: float = 0.0
var _boat_snap_at: float = 0.0
## 桥甲板足迹（格），用于判断玩家是否站在桥上。站在桥上要临时抬升 z_index，
## 否则会被桥体（原点在甲板南缘、y 排序比玩家脚底更靠南）盖住，看不到自己。
var _bridge_decks: Array = []

# ── 多层宿舍 ────────────────────────────────────────────────────────────
## 地上楼层数。1~5 层布局完全相同，只用一个房间实例 + 每玩家的楼层号复用设计。
const FLOOR_COUNT := 5
## B1 在内部用楼层号 6：Net.claim_room / _write_claim 要求楼层 >= 1，
## 用 6 就能让组队公告板直接复用现成的联机同步，不必改服务端协议。
## 界面上只显示「B1 · 游戏活动室」，玩家看不到这个数字。
const BASEMENT_FLOOR := 6
const ACTIVITY_PATH := "res://assets/rooms/activity_room.json"
const DORM_PATH := "res://assets/rooms/dorm_space.json"
## 本地玩家当前楼层（1 起；6 = B1）。异层玩家互相隐藏（见 _update_floor_visibility）。
var current_floor: int = 1
## 楼层 UI（指示 + 电梯选层面板 + 换层黑场）
var _floor_layer: CanvasLayer
var _floor_label: Label
var _floor_panel: PanelContainer
var _floor_flash: ColorRect
var _floor_open := false
var _notice_label: Label
var _notice_clock := 0.0
## 门口公告牌：[{index, side, x, y, w, h, panel, label}]，14 块，文字按 current_floor 刷新
var _door_plates: Array = []
var _door_plates_holder: Control
## 门口公告面板（懒创建，跟楼层 UI 同一个 CanvasLayer）
## _note_panel = 自己的（编辑），_note_view = 别人的（只读）
var _note_panel: PanelContainer
var _note_edit: TextEdit
var _note_title: Label
var _note_count: Label
## 组队板复用同一套公告面板，只是把提示语和「退房」按钮换成组队措辞
var _note_hint: Label
var _note_bye_btn: Button
## OOPZ 语音链接那一格（只有 B1 组队板显示，宿舍公告不会出现）
var _oopz_box: VBoxContainer
var _oopz_edit: LineEdit
var _note_view: PanelContainer
var _note_view_title: Label
var _note_view_body: Label
## 只读面板里的「加入语音」按钮（房主留了链接才显示）
var _note_view_voice: Button
var _note_view_link: String = ""
var _note_room_idx: int = -1
## 上一次量到的软键盘高度（只在手机上非 0），用来在键盘弹出时重新摆面板
var _vk_last: float = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if Net.is_dedicated or not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	if k.keycode == KEY_E and _try_interact():
		get_viewport().set_input_as_handled()
		return
	if k.keycode == KEY_F and _try_claim_room():
		get_viewport().set_input_as_handled()
		return
	# V = 进 OOPZ 语音（只在右下角那个按钮亮着时有效，坐下才会亮）
	if k.keycode == KEY_V and not _voice_link_now.is_empty() and _voice_btn != null and _voice_btn.visible:
		_open_voice(_voice_link_now)
		get_viewport().set_input_as_handled()
		return
	if k.keycode == KEY_ESCAPE and _adopt_open():
		_close_adopt_panel()
		get_viewport().set_input_as_handled()
		return
	if k.keycode == KEY_ESCAPE and _note_open():
		_close_note_all()
		get_viewport().set_input_as_handled()
		return
	if k.keycode == KEY_ESCAPE and _floor_open:
		_close_floor_panel()
		get_viewport().set_input_as_handled()


## E 键只有一个入口，按「最近、最明确」的顺序依次试。
## 顺序不是随便定的：坐着时 E 必须是起身（不然坐在椅子上没法离座就走出房间了），
## 站在椅子边 E 是坐下，站在电梯里 E 是选楼层，站到房间门口 E 才是离开。
func _try_interact() -> bool:
	var me: Node = _local_avatar()
	if me == null:
		return false
	# 命名框开着时 E = 取消（确认走按钮或回车）
	if _adopt_open():
		_close_adopt_panel()
		return true
	# 面板开着时，E 先关面板（选层 / 公告查看）
	if _note_open():
		_close_note_all()
		return true
	if _floor_open:
		_close_floor_panel()
		return true
	# 在船上：E 只有一个含义 —— 靠岸下船（找不到岸边就提示，不打断划船）
	if _my_boat >= 0:
		_try_disembark()
		return true
	if _pose_of(me) != 0:
		Net.sit_down(0, Vector2.ZERO)
		return true
	if not _near_seat.is_empty():
		var face_code := _face_code(String(_near_seat["face"]))
		# 床 = 躺下（座位码 +5 表示躺着），椅子 = 坐下
		Net.sit_down(LIE_SEAT_CODE + face_code if String(_near_seat["kind"]) == "bed" else face_code,
			_near_seat["pos"])
		return true
	if in_room and _near_elevator((me as Node2D).position):
		_open_floor_panel()
		return true
	# 身边有人：E 是加好友。必须排在「门口公告」之前 —— 两个人贴着门站着的时候，
	# 按 E 想加的显然是眼前这个人，不是墙上那块牌子。
	if not _near_buddy.is_empty():
		_try_add_friend(_near_buddy)
		return true
	# 门口公告板：站在某间宿舍门口按 E —— 空房是认领，自己的房是编写，别人的房是查看。
	# 手机上没有 F 键（提示条本身就是按钮），所以认领必须也能从 E 走通。
	if in_room and not _note_open():
		if current_floor == BASEMENT_FLOOR:
			var tb: Dictionary = _nearest_team_board((me as Node2D).position)
			if not tb.is_empty():
				_open_note_board(int(tb["index"]))   # 空板会在里面直接开队
				return true
		else:
			var rd: Dictionary = _nearest_room_door((me as Node2D).position)
			if not rd.is_empty():
				var idx0: int = int(rd["index"])
				if (Net.room_claims.get("%d:%d" % [current_floor, idx0], {}) as Dictionary).is_empty():
					_try_claim_room()
					return true
				_open_note_board(idx0)
				return true
	if in_room and _near_door((me as Node2D).position):
		leave_room()
		return true
	# 岸边小船：上船。排在宿舍之前 —— 船都停在远离宿舍楼的水边，不会打架。
	if not in_room:
		var boat_idx := _nearest_boat((me as Node2D).position)
		if boat_idx >= 0:
			_try_board(boat_idx)
			return true
	if _near_dorm != "":
		enter_room("res://assets/rooms/dorm_space.json")
		return true
	# 校园里最后一级：身边有猫就摸；摸熟了按 E 领养回宿舍。
	# 排在门/船/座位之后，不抢原有交互。
	if not in_room:
		var cat := _nearest_cat((me as Node2D).position)
		if cat != null:
			if bool(cat.call("can_adopt")) and _ensure_adopted().size() < ADOPT_MAX:
				_open_adopt_panel(cat)
			else:
				_pet_cat(cat)
			return true
	return false


## 校园里离玩家最近、且摸得到的猫（房间里没有 WildlifeGround，自然返回 null）
func _nearest_cat(pos: Vector2) -> Node2D:
	if _wildlife_ground == null or not is_instance_valid(_wildlife_ground):
		return null
	var best: Node2D = null
	var best_d := CAT_PET_R
	for c in _wildlife_ground.get_children():
		if not (c is Node2D) or not String(c.name).begins_with("Cat"):
			continue
		var d: float = pos.distance_to((c as Node2D).position)
		if d < best_d:
			best_d = d
			best = c as Node2D
	return best


## 摸猫：猫自己停下、转身、坐下、冒爱心；反馈借现成的提示条亮 1.8 秒
func _pet_cat(cat: Node2D) -> void:
	var me: Node2D = _local_avatar() as Node2D
	var reply: String = str(cat.call("pet", me))
	_cat_msg = "「%s」%s" % [str(cat.call("cat_name")), reply]
	_cat_msg_t = 1.8
	if _door_hint != null:
		_door_hint.text = _cat_msg
		_door_hint.visible = true


# ---------------------------------------------------------------- 领养 / 命名 / 宿舍猫窝

## 领养存档是纯本地的（user://），不塞进 room_claims —— 改联机协议会让公共服
## 旧服务端 checksum failed，房间和聊天一起废掉。
func _ensure_adopted() -> Array:
	if _adopt_loaded:
		return _adopted
	_adopt_loaded = true
	if FileAccess.file_exists(ADOPT_PATH):
		var f := FileAccess.open(ADOPT_PATH, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if parsed is Array:
				_adopted = parsed
	return _adopted


func _save_adopted() -> void:
	var f := FileAccess.open(ADOPT_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_adopted))
	f.close()


func _adopt_open() -> bool:
	return _adopt_panel != null and is_instance_valid(_adopt_panel) and _adopt_panel.visible


func _build_adopt_panel() -> void:
	_adopt_layer = CanvasLayer.new()
	_adopt_layer.name = "AdoptUI"
	_adopt_layer.layer = 9
	add_child(_adopt_layer)
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_adopt_layer.add_child(host)
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.13, 0.16, 0.96)
	sb.border_color = Color("b99a68")
	sb.set_border_width_all(2)
	sb.set_content_margin_all(14)
	pc.add_theme_stylebox_override("panel", sb)
	host.add_child(pc)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	pc.add_child(vb)
	var title := Label.new()
	title.text = "领养猫咪 · 给它起个名字"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color("f2e3c4"))
	vb.add_child(title)
	_adopt_edit = LineEdit.new()
	_adopt_edit.placeholder_text = "最多 12 个字"
	_adopt_edit.max_length = 12
	_adopt_edit.custom_minimum_size = Vector2(320, 38)
	_adopt_edit.text_submitted.connect(func(_t): _confirm_adopt())
	vb.add_child(_adopt_edit)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	vb.add_child(hb)
	for cfg: Array in [["带它回宿舍", _confirm_adopt], ["再想想", _close_adopt_panel]]:
		var b := Button.new()
		b.text = String(cfg[0])
		b.custom_minimum_size = Vector2(140, 40)
		b.focus_mode = Control.FOCUS_NONE
		b.pressed.connect(cfg[1] as Callable)
		hb.add_child(b)
	_adopt_panel = pc
	pc.visible = false


func _open_adopt_panel(cat: Node2D) -> void:
	_ensure_adopted()
	if _adopt_panel == null or not is_instance_valid(_adopt_panel):
		_build_adopt_panel()
	_adopt_cat = cat
	_adopt_edit.text = str(cat.call("cat_name"))
	_adopt_panel.visible = true
	_center_panel(_adopt_panel)
	_center_panel.call_deferred(_adopt_panel)   # 内容尺寸要等一帧才准
	_adopt_edit.grab_focus()
	_adopt_edit.select_all()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_show("")


func _close_adopt_panel() -> void:
	if _adopt_panel != null and is_instance_valid(_adopt_panel):
		_adopt_panel.visible = false
	if _adopt_edit != null and is_instance_valid(_adopt_edit):
		_adopt_edit.release_focus()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_hide()
	_adopt_cat = null


func _confirm_adopt() -> void:
	if _adopt_cat == null or not is_instance_valid(_adopt_cat):
		_close_adopt_panel()
		return
	var nm := _adopt_edit.text.strip_edges()
	if nm.is_empty():
		nm = str(_adopt_cat.call("cat_name"))
	nm = nm.left(12)
	_ensure_adopted()
	if _adopted.size() >= ADOPT_MAX:
		_notice("宿舍猫窝已经满了")
		_close_adopt_panel()
		return
	_adopted.append({"name": nm, "skin": int(_adopt_cat.get("skin_index"))})
	_save_adopted()
	_cat_msg = "「%s」已入住宿舍猫窝" % nm
	_cat_msg_t = 2.2
	_adopt_cat.queue_free()   # 校园里这只被抱走了
	_close_adopt_panel()
	_notice(_cat_msg)
	if in_room:
		_setup_room_cats()


## 宿舍猫窝：每个单间都摆一个（按 room_doors 的门位算），自己的猫只出现在
## 自己认领的那间房里。直接挂进 room.anchor() 的 Objects —— 它本身就是 y-sort
## 容器，单独套一层 Node2D 会让整层被当成 y=0 的一个节点，猫窝永远压在家具后面。
func _setup_room_cats() -> void:
	if room == null or not is_instance_valid(room) or current_floor == BASEMENT_FLOOR:
		return
	var host: Node2D = room.call("anchor") as Node2D
	if host == null:
		return
	# 清掉上一版可能留下的分组层，以及本函数自己造的所有节点。
	# 用 remove_child 立刻让出名字，否则同帧重建时新节点会被 Godot 自动改名。
	for grp_name in ["AdoptedCats", "AdoptedCatsOld"]:
		var grp := host.get_node_or_null(grp_name)
		if grp != null:
			host.remove_child(grp)
			grp.queue_free()
	for ch in host.get_children():
		var nm := String(ch.name)
		if nm.begins_with("CatBed_") or nm.begins_with("RoomCat_") or nm.begins_with("CatName_"):
			host.remove_child(ch)
			ch.queue_free()

	var bed_script: Script = load("res://net/scripts/room_cat_bed.gd")
	var cat_script: Script = load("res://net/scenes/Cat.gd")
	var skins: Array = cat_script.SKINS
	var cats := _ensure_adopted()

	# 自己的房间：优先服务端权威的认领关系，退回本地存档，最后默认第一间
	var my_idx := 0
	var mine := _load_my_room()
	if mine.x == current_floor and mine.y >= 0:
		my_idx = mine.y
	for key in Net.room_claims.keys():
		var parts := String(key).split(":")
		if parts.size() == 2 and int(parts[0]) == current_floor:
			var claim: Dictionary = Net.room_claims[key]
			if String(claim.get("uid", "")) == Net.local_uid:
				my_idx = int(parts[1])
				break
	if OS.has_environment("XGD_CAT_ROOM"):
		my_idx = int(OS.get_environment("XGD_CAT_ROOM"))

	var doors: Array = room.get("data").get("room_doors", [])
	for d in doors:
		if not (d is Dictionary):
			continue
		var dd: Dictionary = d
		var idx := int(dd.get("index", 0))
		var north := String(dd.get("side", "n")) == "n"
		var cx := float(dd.get("x", 0.0)) + float(dd.get("w", 3.0)) * 0.5
		# 北排房间 y≈2..10、南排 y≈20..28。往右挪 1.5 格避开正对门洞的位置，
		# 北排再抬高 1.2 格，别贴着门口那道墙；此处的书桌/椅子/绿植都不占这块地。
		var at := Vector2(cx + 1.5, 7.4 if north else 25.8) * TS
		var bed := Node2D.new()
		bed.name = "CatBed_%d" % idx
		bed.set_script(bed_script)
		bed.position = at
		host.add_child(bed)
		if idx != my_idx:
			continue
		# 自己的窝：摆上领养的猫，加名牌
		var name_text := ""
		for i in cats.size():
			if not (cats[i] is Dictionary):
				continue
			var cd: Dictionary = cats[i]
			var nm := str(cd.get("name", "猫"))
			if name_text != "":
				name_text += "、"
			name_text += nm
			var c := Node2D.new()
			c.name = "RoomCat_%d" % i
			c.set_script(cat_script)
			host.add_child(c)
			# 2 只并排趴垫子，第 3/4 只挪到窝前地板上，别叠成一坨
			var cat_at := at + Vector2(-8.0 + float(i % 2) * 15.0,
				float(int(i / 2)) * 10.0)
			c.call("setup", cat_at, skins[int(cd.get("skin", 0)) % skins.size()], 9000 + i * 71)
			c.set("pos", cat_at)
			c.set("home", cat_at)
			c.position = cat_at
			# 猫的脚底 y 比窝小，纯 y-sort 会被垫子盖住；抬一级让它趴在垫子上
			c.z_index = 1
			c.set_process(false)                # 房里不漫游，坐姿比蜷成一团更好认
			c.call("_play", "sit", true)
		if name_text != "":
			var lb := Label.new()
			lb.name = "CatName_%d" % idx
			lb.text = name_text
			# 贴着窝上方，往左偏开椅子；描边+投影保证压在深色地板上也读得清
			lb.position = at + Vector2(-34.0, -19.0)
			lb.scale = Vector2(0.5, 0.5)
			lb.add_theme_font_size_override("font_size", 14)
			lb.add_theme_color_override("font_color", Color("fff0cf"))
			lb.add_theme_color_override("font_outline_color", Color("1a1410"))
			lb.add_theme_constant_override("outline_size", 4)
			lb.add_theme_color_override("font_shadow_color", Color("1a1410"))
			lb.z_index = 60
			host.add_child(lb)


## 朝向名 → sit_dir 的编号（1..4，和 SIT_DIRS 一致）
func _face_code(face: String) -> int:
	match face:
		"down": return 1
		"left": return 2
		"right": return 3
		"up": return 4
	return 1


## 楼层号 → 房间数据。B1 用独立活动室布局，地上 1~5 层共用宿舍。
func _room_path_for(n: int) -> String:
	return ACTIVITY_PATH if n == BASEMENT_FLOOR else DORM_PATH


func _room_id_for(path: String) -> String:
	return "activity_room" if path == ACTIVITY_PATH else "dorm_space"


## 按目标楼层搭好房间：同一份布局就复用，跨 B1 / 地上则销毁重建。
## 玩家不挂在 room 节点下（只挂在校园 Objects），所以重建不会把人一起删掉。
## 必须 remove_child 立刻从树里摘掉 —— 只 queue_free 的话帧末才生效，
## 新旧两份房间会重叠一帧。
func _ensure_room_for_floor(n: int) -> bool:
	var path := _room_path_for(n)
	if room != null and is_instance_valid(room):
		if String(room.get("data").get("id", "")) == _room_id_for(path):
			room.visible = true
			return true
		if campus != null:
			var old_objs: Node2D = campus.get_node_or_null("Objects")
			if old_objs != null and room.get_parent() == old_objs:
				old_objs.remove_child(room)
		room.queue_free()
		room = null
	if campus == null:
		return false
	var objs: Node2D = campus.get_node_or_null("Objects")
	if objs == null:
		return false
	room = Node2D.new()
	room.name = "Room"
	room.set_script(RoomScript)
	room.set("node_scale", 1.0)          # Objects 空间已经是 8px/格
	objs.add_child(room)
	room.position = ROOM_ORIGIN * TS
	if not bool(room.call("load_room", path)):
		objs.remove_child(room)
		room.queue_free()
		room = null
		push_error("[arena] 房间加载失败：" + path)
		return false
	room.visible = true
	return true


## 把一个房间挂到校园的 Objects 下并把人送进去。成功返回 true。
## floor_n：进门直接落在第几层（自家所在层用它，普通进楼走默认 1 层）。
## path 留在签名里只为兼容旧调用，实际用哪份房间由楼层决定。
func enter_room(path: String, floor_n: int = 1) -> bool:
	if in_room or campus == null:
		return false
	if _my_boat >= 0:
		return false                      # 划船中不能直接进宿舍（先下船）
	var want := clampi(floor_n, 1, BASEMENT_FLOOR)
	if not _ensure_room_for_floor(want):
		return false

	var me: Node = _local_avatar()
	if me == null:
		return false
	_return_cell = (me as Node2D).position / TS

	var sp: Vector2 = room.get("spawn_px")
	var target: Vector2 = room.position + sp
	# 房间内是「本地姿势权威」（_hold_local_pose 每帧把 _local_pose 贴回 sit_dir），
	# 带着非 0 的姿势进房会被一路钉在坐姿上 —— 人站在房间里却一步也走不动。
	# 校园里坐着是能走到门口的（起身才能走），但电梯/门口交互不排除这种顺序。
	if _pose_of(me) != 0:
		me.call("stand_up")
	me.call("teleport_to", target)
	me.set("_room_freeze", true)
	# 进房前校园那边可能还有没被服务器确认的预测命令，房间期间又不发包，
	# 残留下来只会在出房后被重放（人莫名其妙往前冲一段），这里直接倒干净。
	var stale_buffer: Variant = me.get("buffer")
	if stale_buffer != null:
		stale_buffer.entries.clear()
	var stale_commands: Variant = me.get("commands")
	if stale_commands is Dictionary:
		(stale_commands as Dictionary).clear()
	_set_cam_limit(me, true)
	_fit_room_zoom(me)
	in_room = true

	# 房间没有烘焙光照图，全屏夜幕会把它压成一片黑
	if _night_dark != null:
		_night_dark.visible = false
	_collect_room_seats()
	_room_title = String(room.get("data").get("name", "房间"))
	if _door_hint != null:
		_door_hint.visible = true
	_door_clock = 0.0
	# 每次进楼默认从 1 层开始（自家在那层就直接落到自家那层；B1 则直接进活动室）
	current_floor = want
	Net.set_my_floor(current_floor)
	# 告诉服务端「我进房间了、在第几层、落在哪」：房间内不跑服务端模拟，
	# 但位置/楼层要同步出去，否则同房间的人互相看不见（房间内只有自己）。
	me.call("set_room_state", true, current_floor, target)
	_build_door_plates()
	_update_room_doors()          # 进门先按认领关系把每扇门锁好/放开
	_update_floor_label()
	_update_floor_visibility()
	_setup_room_cats()
	room_changed.emit(true)
	return true


func leave_room() -> void:
	if not in_room:
		return
	in_room = false
	# 房间会被隐藏，人还坐在椅子上就悬空了 —— 出门前先站起来
	var me: Node = _local_avatar()
	if me != null and _pose_of(me) != 0:
		Net.sit_down(0, Vector2.ZERO)
	_seats_room.clear()
	_near_seat = {}
	if _night_dark != null:
		_night_dark.visible = true
	if me != null:
		me.call("teleport_to", _return_cell * TS)
		me.call("set_room_state", false, 0, _return_cell * TS)
		me.set("_room_freeze", false)
		_set_cam_limit(me, false)
		me.set("_cam_zoom_target", CAMPUS_ZOOM)
	if room != null:
		room.visible = false
	if _door_hint != null:
		_door_hint.visible = false
	_door_clock = 0.0
	# 离开整栋楼：收起楼层面板/指示、清掉门牌、楼层归 1
	_close_floor_panel()
	_clear_door_plates()
	current_floor = 1
	Net.set_my_floor(1)
	if _floor_label != null:
		_floor_label.visible = false
	_update_floor_visibility()
	room_changed.emit(false)


## 调试用：真的注入一次 E 键事件，走 _unhandled_input 那条路。
## 直接调 enter_room() 测不出「按键到底有没有被吞掉」这类问题。
func _auto_press_e() -> void:
	var times: int = maxi(1, OS.get_environment("XGD_TEST_E").to_int())
	var delay := 3.0
	if OS.has_environment("XGD_TEST_E_DELAY"):
		delay = clampf(OS.get_environment("XGD_TEST_E_DELAY").to_float(), 0.1, 60.0)
	await get_tree().create_timer(delay).timeout
	# 调试：先站到第一把椅子旁边，方便验证「按 E 坐下」这条链路
	if OS.has_environment("XGD_TEST_SEAT") and not _seats_room.is_empty():
		var a: Node = _local_avatar()
		if a != null:
			var s: Dictionary = _seats_room[0]
			a.call("teleport_to", (s["pos"] as Vector2) + Vector2(0.0, 16.0))
			print("[arena] 已站到座位旁：座位=", s["pos"], " 朝向=", s["face"])
			await get_tree().create_timer(0.5).timeout
			print("[dbg] 玩家现在=", (a as Node2D).position, " 距离=",
				(a as Node2D).position.distance_to(s["pos"]), " _near_seat=", _near_seat,
				" in_room=", in_room, " seats_room=", _seats_room.size())
	for i in range(times):
		var down := InputEventKey.new()
		down.keycode = KEY_E
		down.physical_keycode = KEY_E
		down.pressed = true
		Input.parse_input_event(down)
		await get_tree().create_timer(0.12).timeout
		var up := InputEventKey.new()
		up.keycode = KEY_E
		up.physical_keycode = KEY_E
		up.pressed = false
		Input.parse_input_event(up)
		await get_tree().create_timer(1.6).timeout
		var a2: Node = _local_avatar()
		print("[arena] 第 %d 次 E 之后 in_room=%s sit_dir=%d pos=%s" % [
			i + 1, in_room, int(a2.get("sit_dir")) if a2 != null else -1,
			(a2 as Node2D).position if a2 != null else Vector2.ZERO])

	# 调试：坐下之后按住方向键，应该自己站起来
	if OS.has_environment("XGD_TEST_WALK"):
		await get_tree().create_timer(1.2).timeout
		var a3: Node = _local_avatar()
		print("[dbg] 按键前 sit_dir=", int(a3.get("sit_dir")))
		Input.action_press("move_up")
		await get_tree().create_timer(0.9).timeout
		Input.action_release("move_up")
		await get_tree().create_timer(0.3).timeout
		print("[dbg] 按方向键后 sit_dir=", int(a3.get("sit_dir")),
			" pos=", (a3 as Node2D).position)


## 兜底：客户端连上了、但一直收不到有效的位置同步时（服务器版本和客户端不一致
## 就会这样 —— RPC 校验和对不上，位置包全被丢弃），本地玩家会停在 (0,0)，
## 也就是校园围墙外的角落，表现就是「进游戏人就卡在地图外面，动不了也没法玩」。
## 这里把它挪回正常出生点，至少能单机玩下去，同时打一条警告方便排查。
func _guard_local_spawn() -> void:
	await get_tree().create_timer(2.5).timeout
	if Net.is_server():
		return
	var me: Node = _local_avatar()
	if me == null:
		return
	if (me as Node2D).position.length() < 1.0:
		(me as Node2D).call("teleport_to", _spawn_cell() * TS)
		push_warning("[arena] 位置同步异常（服务器与客户端版本不一致？）已挪回出生点")


## 调试：XGD_FORCE_SPAWN="x,y"（格）。等服务器把位置同步完再传送，否则会被覆盖。
func _force_spawn_debug() -> void:
	await get_tree().create_timer(2.8).timeout
	var raw := OS.get_environment("XGD_FORCE_SPAWN").split(",")
	if raw.size() != 2:
		return
	var me: Node = _local_avatar()
	if me == null:
		return
	var p: Vector2 = Vector2(float(raw[0]), float(raw[1])) * TS
	(me as Node2D).call("teleport_to", p)
	print("[dbg] 强制传送到 ", p)


## 调试：XGD_TEST_BOAT="船号,x,y"（格）。把船摆到指定水域、本地玩家上船，
## 用来核对小船钻拱桥时的 y 排序遮挡（正常玩无效）。
func _boat_debug() -> void:
	await get_tree().create_timer(3.2).timeout
	var raw := OS.get_environment("XGD_TEST_BOAT").split(",")
	if raw.size() != 3:
		return
	var idx := int(raw[0])
	var cell := Vector2(float(raw[1]), float(raw[2]))
	if idx < 0 or idx >= _boats.size():
		return
	var me: Node = _local_avatar()
	if me == null:
		return
	var p: Vector2 = cell * TS
	_boats[idx]["pos"] = p
	(me as Node2D).position = p
	if idx < _boat_nodes.size():
		_boat_nodes[idx].call("set_net", p, false, 0.0, 0.0)
	var ok := _try_board(idx)
	print("[dbg] XGD_TEST_BOAT 船 ", idx, " 摆到 ", cell, " 上船=", ok)


## 调试：进房间后一路往南走，应该踩到门垫就自动出去。
func _auto_walk_out() -> void:
	await get_tree().create_timer(2.5).timeout
	if not in_room:
		enter_room("res://assets/rooms/dorm_space.json")
	await get_tree().create_timer(2.0).timeout
	print("[dbg] 走之前 in_room=", in_room)
	Input.action_press("move_down")
	await get_tree().create_timer(3.0).timeout
	Input.action_release("move_down")
	await get_tree().create_timer(0.4).timeout
	var me: Node = _local_avatar()
	print("[dbg] 走到门口 in_room=", in_room,
		" pos=", (me as Node2D).position if me != null else Vector2.ZERO,
		" 门旁判定=", _near_door((me as Node2D).position) if me != null else false)
	# 在门口按 E 应该出门（不在门口按 E 什么都不做）
	var d := InputEventKey.new()
	d.keycode = KEY_E
	d.physical_keycode = KEY_E
	d.pressed = true
	Input.parse_input_event(d)
	await get_tree().create_timer(0.12).timeout
	var u := InputEventKey.new()
	u.keycode = KEY_E
	u.physical_keycode = KEY_E
	u.pressed = false
	Input.parse_input_event(u)
	await get_tree().create_timer(0.6).timeout
	print("[dbg] 门口按 E 之后 in_room=", in_room)


## 等玩家 spawn 出来再进房间（联机会话建立有延迟）
func _auto_enter_room() -> void:
	var t := get_tree().create_timer(4.0)
	t.timeout.connect(func():
		if _local_avatar() == null:
			# 玩家还没 spawn 出来，稍后再试一次
			var t2 := get_tree().create_timer(2.0)
			t2.timeout.connect(func(): _try_auto_room())
			return
		_try_auto_room()
	)


## 调试：把本地玩家摆到 1 号房门口正下方，按住 ↑ 两秒。
## 空房应该自动滑开、人直接走进隔间；锁着的房应该停在门洞外。
## 用 XGD_TEST_GATE=1 触发（配合 XGD_ROOM=1）。
func _auto_walk_gate() -> void:
	var t := get_tree().create_timer(6.5)
	t.timeout.connect(func() -> void:
		var me: Node = _local_avatar()
		if me == null or room == null:
			print("[dbg] 门测试：玩家或房间还没就绪")
			return
		var rp: Vector2 = (room as Node2D).position
		# 锁门场景：把 1 号房伪造成「别人认领的」，人应该被挡在门洞外
		if OS.has_environment("XGD_TEST_GATE_LOCK"):
			Net.room_claims["%d:0" % current_floor] = {"name": "隔壁老王", "uid": "xgd-someone-else"}
			Net.room_claims_changed.emit()
			print("[dbg] 门测试：1 号房伪造为他人所有")
		# 好友场景：把 1 号房设成「我某个好友的房间」，门应该照样开
		if OS.has_environment("XGD_TEST_GATE_FRIEND"):
			var fl: Array = Net.friend_list()
			if fl.size() > 0:
				var f: Dictionary = fl[0]
				Net.room_claims["%d:0" % current_floor] = {
					"name": String(f["name"]), "uid": String(f["uid"])}
				Net.room_claims_changed.emit()
				print("[dbg] 门测试：1 号房设为好友「", f["name"], "」的房间")
			else:
				print("[dbg] 门测试：好友列表是空的，跳过")
		me.call("teleport_to", rp + Vector2(8.0 * TS, 13.6 * TS))
		Input.action_press("move_up")
		var t2 := get_tree().create_timer(2.2)
		t2.timeout.connect(func() -> void:
			Input.action_release("move_up")
			var p: Vector2 = (me as Node2D).position
			var doors: Array = (room as Node2D).get("doors")
			print("[dbg] 门测试 局部=", (p - rp) / TS,
				" 门0_open=", doors[0].call("open_ratio"),
				" 门0_locked=", doors[0].get("locked"))
		)
	)


## 联机同步自检：进世界 8 秒后按住方向键走 N 秒，打印起终点。
## 另一个实例的 [dbg] 行里，同一个玩家（不带 * 的那个）的位置应该同步在变，
## 这就是「别人看得见我走」。用 XGD_TEST_WALK=<秒> 触发，
## 方向用 XGD_TEST_WALK_DIR=right/left/up/down（默认 right）。
func _auto_walk_sync() -> void:
	var secs := float(OS.get_environment("XGD_TEST_WALK"))
	if secs <= 0.0:
		secs = 2.0
	var dir := OS.get_environment("XGD_TEST_WALK_DIR").strip_edges().to_lower()
	if dir.is_empty():
		dir = "right"
	var action := "move_" + dir
	var t := get_tree().create_timer(8.0)
	t.timeout.connect(func() -> void:
		var me: Node = _local_avatar()
		if me == null:
			print("[dbg] 走位测试：玩家还没就绪")
			return
		var p0: Vector2 = (me as Node2D).position
		print("[dbg] 走位测试 起点=", p0, " 动作=", action)
		Input.action_press(action)
		var t2 := get_tree().create_timer(secs)
		t2.timeout.connect(func() -> void:
			Input.action_release(action)
			var p1: Vector2 = (me as Node2D).position
			print("[dbg] 走位测试 终点=", p1, " 位移=", (p1 - p0).length())
		)
	)


func _try_auto_room() -> void:
	# 调试：XGD_ROOM_FLOOR=6 直接落到 B1 活动室（配合 XGD_ROOM=1 截图用）
	var f := 1
	if OS.has_environment("XGD_ROOM_FLOOR"):
		f = clampi(OS.get_environment("XGD_ROOM_FLOOR").to_int(), 1, BASEMENT_FLOOR)
	if not enter_room("res://assets/rooms/dorm_space.json", f):
		push_warning("[arena] 自动进房间失败")
	else:
		print("[dbg] 自动进房成功 in_room=", in_room,
			" 玩家=", (_local_avatar() as Node2D).position if _local_avatar() != null else Vector2.ZERO)
		# 调试：XGD_ROOM_AT="x,y" 进房后落到房间局部格坐标（测门/板/座位交互用）
		if OS.has_environment("XGD_ROOM_AT"):
			var raw := OS.get_environment("XGD_ROOM_AT").split(",")
			if raw.size() == 2:
				var a := _local_avatar()
				if a != null:
					(a as Node2D).call("teleport_to",
						room.position + Vector2(float(raw[0]), float(raw[1])) * TS)
					print("[dbg] 房内落点=", (a as Node2D).position)
		# 调试：XGD_OOPZ_DEMO=1 自己是队长、=2 是别人的队（验语音按钮/编辑框用）
		if OS.has_environment("XGD_OOPZ_DEMO"):
			var demo := OS.get_environment("XGD_OOPZ_DEMO")
			var demo_note := OOPZ_TAG + "https://oopz.cn/i/demo01\n来打排位，缺 2 人，开麦"
			if demo == "2":
				Net.room_claims["%d:0" % BASEMENT_FLOOR] = {
					"name": "别人的队", "uid": "demo-other", "note": demo_note}
				Net.room_claims_changed.emit()
			else:
				Net.claim_room(BASEMENT_FLOOR, 0, "演示队")
				Net.set_team_note(0, demo_note)
			print("[dbg] 演示组队板=", Net.room_claims.get("%d:0" % BASEMENT_FLOOR, {}))
		# 自测：XGD_TEST_VOICE="<邀请链接>" 走完整链路 —— 写进 0 号板 → 读回来 →
		# 过白名单 → 唤起系统，把每一步结果打出来（验「链接到底能不能用」用）。
		if OS.has_environment("XGD_TEST_VOICE"):
			var tst := OS.get_environment("XGD_TEST_VOICE").strip_edges()
			Net.claim_room(BASEMENT_FLOOR, 0, "自测队")
			Net.set_team_note(0, OOPZ_TAG + tst + "\n自测")
			var back := _room_voice_link(0)
			print("[test-voice] 输入=", tst)
			print("[test-voice] 白名单过=", _safe_voice_link(tst))
			print("[test-voice] 读回=", back, " 像邀请=", _looks_oopz_invite(back))
			var t_probe := Time.get_ticks_msec()
			var running := _oopz_client_running()
			print("[test-voice] 客户端在跑=", running,
				" 探测耗时=", Time.get_ticks_msec() - t_probe, "ms")
			_open_voice(back)


## 进出房间时放开/恢复相机边界。只动本地玩家的相机，远端玩家不影响视角。
func _set_cam_limit(avatar: Node, free_it: bool) -> void:
	var cam: Node = avatar.get_node_or_null("Camera")
	if cam == null:
		return
	if free_it:
		if _cam_limit.is_empty():
			_cam_limit = {
				"left": cam.get("limit_left"),
				"right": cam.get("limit_right"),
				"top": cam.get("limit_top"),
				"bottom": cam.get("limit_bottom"),
			}
		# 把相机限制在**房间矩形**里，而不是把限制全放开。
		# 全放开的话，人走到房间角落就会看到墙外的纯黑 —— 房间比视口大，
		# 相机本来就该在房间内滑，不该滑到外面去。
		var rp: Vector2 = (room as Node2D).global_position
		var rs: Vector2 = (room as Node2D).get("size_px") * (room as Node2D).global_scale
		cam.set("limit_left", int(rp.x))
		cam.set("limit_top", int(rp.y))
		cam.set("limit_right", int(rp.x + rs.x))
		cam.set("limit_bottom", int(rp.y + rs.y))
	elif not _cam_limit.is_empty():
		for k in _cam_limit:
			cam.set("limit_" + String(k), _cam_limit[k])
		_cam_limit.clear()
	cam.call("reset_smoothing")
	cam.call("force_update_scroll")


## 视距只按「竖向」适配：让南北两排房间刚好一屏看全（镜头高度固定），
## 横向靠拉长的走廊去滚动 —— 走起来才有沉浸感。
## 不按宽度缩，否则 14 间这种长条楼层会被人为缩成一条、走廊的"长"也就白拉了。
##
## ⚠️ 换层时也必须重算：宿舍（高 14 格）算出 2.1 倍，B1 活动室（高 42 格）
## 要 ~1.0 倍才装得下。漏了这步，从宿舍坐电梯下 B1 后还停在 2.1 倍，
## 视野只有六百多像素、房间宽 1056 —— 屏幕上只看得见一小块地板。
func _fit_room_zoom(avatar: Node) -> void:
	if avatar == null or room == null or not is_instance_valid(room):
		return
	if OS.has_environment("XGD_ZOOM"):
		avatar.set("_cam_zoom_target", clampf(OS.get_environment("XGD_ZOOM").to_float(), 0.55, 3.0))
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var rw: Vector2 = (room as Node2D).get("size_px") * (room as Node2D).global_scale
	var fit_h: float = vp.y / maxf(rw.y, 1.0) * 0.94
	avatar.set("_cam_zoom_target", clampf(minf(ROOM_ZOOM, fit_h), 0.55, ROOM_ZOOM))


## 只有真·宿舍楼能进：星天苑 A~H、云天苑 A~F、海天苑 1/2 号楼。
##
## 早先用「名字里带『座』或『宿舍』」当判据，结果教学西楼/教学东楼 A~D 座
## 共 8 栋教学楼也被放进来 —— 站在教学楼门口也能开门进宿舍空间，明显不对。
## 现在按楼盘名前缀认：星天苑 / 云天苑 / 海天苑，且必须带「座」或「号楼」。
const DORM_PREFIXES: Array[String] = ["星天苑", "云天苑", "海天苑"]

func _collect_dorms() -> void:
	_dorms.clear()
	for b in MapData.buildings():
		var n := str(b.get("name", ""))
		var is_dorm := false
		for pf in DORM_PREFIXES:
			if n.begins_with(pf) and (n.contains("座") or n.contains("号楼")):
				is_dorm = true
				break
		if not is_dorm:
			continue
		var w := float(b.get("w_cells", 0.0))
		var h := float(b.get("h_cells", 0.0))
		if w <= 0.0 or h <= 0.0:
			continue
		var cen: Vector2 = b.get("cen", Vector2.ZERO)
		_dorms.append({
			"name": n,
			"rect": Rect2(cen - Vector2(w, h) * 0.5, Vector2(w, h)),
		})
	print("[arena] 可进入的宿舍 %d 栋" % _dorms.size())


## 提示条尺寸（逻辑像素）。够放「星天苑H座 · 按 E 进入「宿舍空间」」这一整行。
const HINT_W := 420.0
const HINT_H := 34.0
## 提示底边离人物脚底多少世界像素（人物约 18px 高，名牌到 -25）
const HINT_LIFT := 34.0


## 把提示条摆到人物头顶正上方。CanvasLayer 里的坐标是屏幕像素，
## 所以用 canvas_transform 把世界坐标换算过去（自动带上相机位置和视距）。
func _place_hint_above_player() -> void:
	if _door_hint == null or not _door_hint.visible:
		return
	var me: Node = _local_avatar()
	if me == null:
		return
	var vp := get_viewport()
	# 头顶那个名牌的具体高度会随字号/缩放变，直接拿它的世界矩形当基准，
	# 比猜一个固定偏移稳（第一版就是猜的，结果提示正好压在名字上）。
	var anchor_y: float = (me as Node2D).global_position.y - HINT_LIFT
	var nm: Control = me.get_node_or_null("Name")
	if nm != null and nm.visible and nm.size.y > 0.0:
		anchor_y = nm.get_global_rect().position.y - 6.0
	var world := Vector2((me as Node2D).global_position.x, anchor_y)
	var screen: Vector2 = vp.get_canvas_transform() * world
	var half := HINT_W * 0.5
	var x := clampf(screen.x, half + 6.0, vp.get_visible_rect().size.x - half - 6.0)
	var y := clampf(screen.y - HINT_H, 6.0, vp.get_visible_rect().size.y - HINT_H - 6.0)
	_door_hint.position = Vector2(x - half, y)


func _build_door_hint() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DoorHint"
	layer.layer = 5
	add_child(layer)

	# 做成按钮而不是纯文字：手机上根本没有 E 键，点这行字就是「按 E」。
	# flat + 空样式，看起来还是一行字，但能接点击。
	_door_hint = Button.new()
	_door_hint.flat = true
	_door_hint.focus_mode = Control.FOCUS_NONE
	_door_hint.mouse_filter = Control.MOUSE_FILTER_STOP
	for st in ["normal", "hover", "pressed", "focus", "disabled"]:
		var empty := StyleBoxEmpty.new()
		_door_hint.add_theme_stylebox_override(st, empty)
	_door_hint.pressed.connect(_on_hint_pressed)
	_door_hint.visible = false
	_door_hint.alignment = HORIZONTAL_ALIGNMENT_CENTER   # Button 叫 alignment，不是 Label 的 horizontal_alignment
	_door_hint.add_theme_font_size_override("font_size", 20)
	_door_hint.add_theme_color_override("font_color", Color("#eaf3fb"))
	_door_hint.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.95))
	# 20px 的字配 6px 描边，笔画会被糊成一坨（「离」几乎认不出），4px 刚好压住背景又不吃笔画
	_door_hint.add_theme_constant_override("outline_size", 4)
	# 位置每帧算（跟着人物头顶），这里只定尺寸和锚点。
	# 之前钉在屏幕上方居中：换场景/换分辨率都还好，但玩家眼睛盯着人物时
	# 根本注意不到上方那行字 —— 提示就该长在人物头上。
	_door_hint.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_door_hint.size = Vector2(HINT_W, HINT_H)
	layer.add_child(_door_hint)


## 坐着时的「进语音」按钮（右下角）。手机上点它、桌面上按 V，都是唤起 OOPZ。
## 只在 B1 活动室、且坐进的单间填了语音链接时才出现 —— 宿舍不涉及。
func _build_voice_btn() -> void:
	_voice_btn = Button.new()
	_voice_btn.focus_mode = Control.FOCUS_NONE
	_voice_btn.mouse_filter = Control.MOUSE_FILTER_STOP
	_voice_btn.add_theme_font_size_override("font_size", 17)
	_voice_btn.add_theme_color_override("font_color", Color("#d8ffe8"))
	_voice_btn.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.95))
	_voice_btn.add_theme_constant_override("outline_size", 3)
	# 跟项目其余 UI 一致：2px 实线边框 + 深底，不用圆角/模糊
	for st in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.07, 0.16, 0.12, 0.94) if st == "normal" else Color(0.10, 0.22, 0.16, 0.97)
		sb.border_color = Color(0.42, 0.90, 0.66, 0.95)
		sb.set_border_width_all(2)
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 8
		sb.content_margin_bottom = 8
		_voice_btn.add_theme_stylebox_override(st, sb)
	_voice_btn.pressed.connect(_on_voice_btn_pressed)
	_voice_btn.visible = false
	var layer := CanvasLayer.new()
	layer.name = "VoiceBtn"
	layer.layer = 5
	add_child(layer)
	layer.add_child(_voice_btn)


func _on_voice_btn_pressed() -> void:
	_open_voice(_voice_link_now)


## 右下角摆位（换分辨率/窗口缩放都要重算，所以每次显示前调一次）
func _place_voice_btn() -> void:
	if _voice_btn == null:
		return
	var vs := get_viewport().get_visible_rect().size
	var sz := _voice_btn.get_combined_minimum_size()
	_voice_btn.size = sz
	_voice_btn.position = Vector2(vs.x - sz.x - 18.0, vs.y - sz.y - 18.0)


## 坐着的时候每 8Hz 调一次：坐的单间有语音链接就亮按钮，没有就藏起来。
func _refresh_voice_btn(pos: Vector2) -> void:
	if _voice_btn == null:
		return
	var link := ""
	var idx := -1
	if current_floor == BASEMENT_FLOOR and in_room:
		idx = _seat_room_at(pos)
		if idx >= 0:
			link = _room_voice_link(idx)
	_voice_link_now = link
	if link.is_empty():
		_voice_btn.visible = false
		return
	_voice_btn.text = "%s · 按 V 进语音" % _team_board_name(idx)
	_voice_btn.visible = true
	_place_voice_btn()



## 每隔一小段时间看一次：人在哪栋宿舍旁 / 是否已经在房间里。
## 不每帧扫是有原因的 —— 20 栋楼 × 每帧，在一台老机器上就是白烧的 CPU。
## 每隔一小段时间看一次：坐着 / 旁边有椅子 / 在房间里 / 站在哪栋宿舍旁。
## 不每帧扫是有原因的 —— 20 栋楼 + 39 个座位 × 每帧，在一台老机器上就是白烧的 CPU。
## 提示和 E 键的优先级必须一致，否则会出现「提示说能坐、按了却走了」。
func _update_interact_hint(delta: float) -> void:
	if _door_hint == null:
		return
	_door_clock -= delta
	if _door_clock > 0.0:
		return
	_door_clock = 1.0 / DOOR_CHECK_HZ

	var me: Node = _local_avatar()
	if me == null:
		_near_dorm = ""
		_near_seat = {}
		_door_hint.visible = false
		if _voice_btn != null:
			_voice_btn.visible = false
		return

	var pos: Vector2 = (me as Node2D).position
	# 「进语音」按钮只有坐着的时候才该出现，先无条件藏掉，坐着那一支再按需点亮
	if _voice_btn != null:
		_voice_btn.visible = false
		_voice_link_now = ""

	# 门的开合每 8Hz 定一次「该开还是该关」，动画由 RoomDoor 逐帧插值
	_update_room_doors()

	# 在船上：提示只有一个 —— 靠岸后按 E 下船。船上不参与座位/好友/宿舍优先级。
	if _my_boat >= 0:
		_near_seat = {}
		_near_dorm = ""
		_near_buddy = {}
		_door_hint.visible = true
		var can_land := _shore_near(_boats[_my_boat]["pos"])
		_door_hint.text = "按 E 下船" if can_land else "靠岸后按 E 下船"
		return

	if _pose_of(me) != 0:
		_near_seat = {}
		_near_dorm = ""
		_near_buddy = {}
		_door_hint.visible = true
		# 姿势一律问 pose_now()，不要读同步属性 sit_dir：那是每 33ms 被服务器盖回来的
		# 一份旧值，本地权威姿势要等玩家自己的 _process 才贴回，而 Arena 是父节点、
		# 先跑一步 —— 提示条采样到窗口里那一帧，就会在「起床 / 躺到床上」之间反复跳。
		_door_hint.text = "按 E %s" % ("起床" if bool(me.call("is_lying")) else "站起来")
		# 坐在 B1 某个单间里、且队里留了 OOPZ 链接 → 右下角亮「进语音」
		_refresh_voice_btn(pos)
		return

	# 身边站着人：E 优先做「加好友」。比座椅/门牌都具体 —— 人都贴脸了，
	# 按 E 还去开门口的公告牌子会很怪。
	var buddy := _near_player()
	_near_buddy = buddy
	if not buddy.is_empty():
		_near_seat = {}
		_near_dorm = ""
		_door_hint.visible = true
		_door_hint.text = _buddy_hint(buddy)
		return

	var seat := _nearest_seat(pos)
	_near_seat = seat
	if not seat.is_empty():
		_near_dorm = ""
		_door_hint.visible = true
		if String(seat["kind"]) == "bed":
			_door_hint.text = "按 E 躺到床上"
		else:
			_door_hint.text = "按 E 坐下"
		return

	# 房间里：只有站到门口才提示离开（房间中间按 E 不做任何事，
	# 免得「想坐下却走出房间」）
	if in_room:
		_near_dorm = ""
		if _note_open():
			_door_hint.visible = true
			_door_hint.text = "点这里 / 按 E 关掉公告"
		elif _floor_open:
			_door_hint.visible = true
			_door_hint.text = "按 E / Esc 关掉电梯面板"
		elif _near_elevator(pos):
			_door_hint.visible = true
			_door_hint.text = "按 E 乘电梯去其他楼层"
		elif _near_door(pos):
			_door_hint.visible = true
			_door_hint.text = "按 E 离开「%s」" % _room_title
		else:
			if current_floor == BASEMENT_FLOOR:
				var tb := _nearest_team_board(pos)
				if tb.is_empty():
					_door_hint.visible = false
				else:
					var bi := int(tb["index"])
					var cur: Dictionary = Net.room_claims.get("%d:%d" % [BASEMENT_FLOOR, bi], {})
					_door_hint.visible = true
					if cur.is_empty():
						_door_hint.text = "%s · 空队 · 按 E 开队" % _team_board_name(bi)
					elif Net.is_my_team_board(cur):
						_door_hint.text = "%s · 我的队 · 按 E 编辑招募" % _team_board_name(bi)
					else:
						_door_hint.text = "%s ·「%s」的队 · 按 E 看招募" % [
							_team_board_name(bi), String(cur.get("name", "?"))]
				return
			var rd := _nearest_room_door(pos)
			if rd.is_empty():
				_door_hint.visible = false
			else:
				var no: int = int(rd["index"]) + 1
				var gate := _room_gate(int(rd["index"]))
				_door_hint.visible = true
				match String(gate["state"]):
					"empty":
						_door_hint.text = "%d 号房 · 空房 · 按 E 认领" % no
					"mine":
						_door_hint.text = "%d 号房（你的）· E 写公告 · F 撕下名牌" % no
					"friend":
						_door_hint.text = "%d 号房 ·「%s」的房间 · 好友可进" % [no, String(gate["name"])]
					_:
						_door_hint.text = "%d 号房 ·「%s」的房间 · 门锁着（E 看公告）" % [no, String(gate["name"])]
		return

	# 岸边小船：站在船边按 E 上船；被人占着就只提示、不抢。
	var boat_idx := _nearest_boat(pos)
	if boat_idx >= 0:
		_near_dorm = ""
		_near_seat = {}
		_near_buddy = {}
		_door_hint.visible = true
		if int(_boats[boat_idx]["rider"]) == 0 or int(_boats[boat_idx]["rider"]) == Net.my_id():
			_door_hint.text = "按 E 上船"
		else:
			_door_hint.text = "这艘小船已经有人了"
		return

	var cell: Vector2 = pos / TS
	var hit := ""
	for d in _dorms:
		var r: Rect2 = d["rect"]
		if r.grow(DOOR_RADIUS).has_point(cell):
			hit = String(d["name"])
			break
	_near_dorm = hit
	if hit != "":
		_door_hint.visible = true
		_door_hint.text = "%s · 按 E 进入「宿舍空间」" % hit
		return
	# 摸猫反馈短暂占住提示条，之后回到「按 E 摸猫」
	if _cat_msg_t > 0.0:
		_door_hint.visible = true
		_door_hint.text = _cat_msg
		return
	var cat := _nearest_cat(pos)
	if cat != null:
		_door_hint.visible = true
		var nm := str(cat.call("cat_name"))
		var left := ADOPT_PETS - int(cat.get("pet_count"))
		if _ensure_adopted().size() >= ADOPT_MAX:
			_door_hint.text = "按 E 摸摸「%s」· 猫窝已满" % nm
		elif left <= 0:
			_door_hint.text = "按 E 领养「%s」回宿舍" % nm
		else:
			_door_hint.text = "按 E 摸摸「%s」· 再摸 %d 次可领养" % [nm, left]
		return
	_door_hint.visible = false


## 是否站在门口（房间局部坐标，格）。门洞在 exit 矩形里，外扩 2.5 格算「门附近」——
## 太窄的话贴着门框反而判定不到，太宽又会在休息区就被误判成「可以出门」。
const DOOR_EXIT_PAD := 2.5

func _near_door(pos: Vector2) -> bool:
	if room == null or not is_instance_valid(room):
		return false
	var ex: Dictionary = room.get("data").get("exit", {})
	if ex.is_empty():
		return false
	var r := Rect2(float(ex["x"]), float(ex["y"]), float(ex["w"]), float(ex["h"]))
	return r.grow(DOOR_EXIT_PAD).has_point((pos - room.position) / TS)


## 点提示文字 = 按 E。手机上唯一的交互入口。
func _on_hint_pressed() -> void:
	_try_interact()


func _nearest_seat(pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_d := SEAT_RADIUS
	var list: Array = _seats_room if in_room else _seats_campus
	for item in list:
		var s: Dictionary = item
		var d: float = pos.distance_to(s["pos"])
		if d < best_d:
			best_d = d
			best = s
	return best


## 校园里的长椅。world.tscn 里它们是 Objects 下的 StaticBody2D，名字带「长椅」，
## position 是椅子左下角：碰撞占 x 0..16、y -8..0，所以坐面中心在 +8,-4 一带。
## 脚底放得比坐面略低一点，人物才会「陷进」椅子里而不是浮在上面。
func _collect_campus_seats() -> void:
	_seats_campus.clear()
	if campus == null:
		return
	var objs: Node2D = campus.get_node_or_null("Objects")
	if objs == null:
		return
	for c in objs.get_children():
		if not (c is Node2D) or not String(c.name).contains("长椅"):
			continue
		_seats_campus.append({
			"pos": (c as Node2D).position + Vector2(8.0, -1.0),
			"face": "down",
			"kind": "bench",
		})
	print("[arena] 校园长椅可坐 %d 处" % _seats_campus.size())


## 房间里的椅子：Room 已经算好每把朝哪儿（对着最近的桌子），
## 这里只要把房间局部坐标搬到 Objects 空间。
func _collect_room_seats() -> void:
	_seats_room.clear()
	if room == null or not is_instance_valid(room):
		return
	for item in room.get("seats"):
		var s: Dictionary = item
		_seats_room.append({
			"pos": (room as Node2D).position + (s["pos"] as Vector2),
			"face": String(s["face"]),
			"kind": "chair",
			"room": int(s.get("room", -1)),
		})
	# 每张床也是一个「座位」（kind=bed），躺在床上是躺姿而不是坐姿
	for b in room.get("data").get("beds", []):
		var cx: float = float(b["x"]) + float(b["w"]) * 0.5
		# 落点取床垫正中：躺姿是把身体绕中心转 90°（见 PlayerAvatar._apply_sit_anim），
		# 中心对准床垫中心，人才是「躺在床面上」而不是「站在床上、脚踩着床尾」。
		var cy: float = float(b["y"]) + float(b["h"]) * 0.5
		_seats_room.append({
			"pos": room.position + Vector2(cx, cy) * TS,
			"face": "up",
			"kind": "bed",
			"index": int(b["index"]),
		})
	print("[arena] 房间椅子可坐 %d 把、床 %d 张" % [_seats_room.size() - _count_beds(), _count_beds()])


func _count_beds() -> int:
	var n := 0
	for item in _seats_room:
		if String(Dictionary(item).get("kind", "")) == "bed":
			n += 1
	return n


## 某号房的床中心在哪（Objects 空间坐标）；没有这张床就返回零向量
func _bed_of(index: int) -> Vector2:
	for item in _seats_room:
		var s: Dictionary = item
		if String(s.get("kind", "")) == "bed" and int(s.get("index", -1)) == index:
			return s["pos"]
	return Vector2.ZERO


## 座位状态变了（本地自己按的，或别人坐下了）。
## 按 owner_peer_id 找到对应玩家再改姿势 —— 远端玩家的位置由服务端同步，
## 这里的 teleport 只是让坐下的那一帧就到位，不用等下一次位置包。
func _on_seat_changed(id: int, dir: int, pos: Vector2) -> void:
	for c in players.get_children():
		if c == null or not is_instance_valid(c):
			continue
		if int(c.get("owner_peer_id")) != id:
			continue
		if dir == 0:
			c.call("stand_up")
		elif dir >= LIE_SEAT_CODE:
			c.call("lay_at", pos, _face_name(dir - LIE_SEAT_CODE))
		else:
			c.call("sit_at", pos, _face_name(dir))
		return


func _face_name(dir: int) -> String:
	match dir:
		2:
			return "left"
		3:
			return "right"
		4:
			return "up"
	return "down"



# ── 「回家的宿舍」：认领过房间的人，一上线直接出生在自己床上了 ─────────
const MY_ROOM_CFG := "user://my_room.cfg"

## 进游戏时决定是否直接落到自己房间里。没认领过 → 老规矩从校园出生。
func _auto_spawn_home() -> void:
	if Net.is_dedicated:
		return
	var me: Node = await _wait_local_avatar(15.0)
	if me == null:
		return
	await get_tree().create_timer(0.8).timeout      # 等服务端把认领快照发下来

	var claim: String = Net.my_claim()
	if claim.is_empty():
		# 服务端还没记住（或自己单机）—— 本地存档里若记过「我的房间」，重新认领一次。
		# 房间要是被别人占着，服务端的 uid 校验会直接驳回，不会抢别人的。
		var saved := _load_my_room()
		if saved.x < 1:
			return
		Net.claim_room(saved.x, saved.y, Net.local_name)
		await get_tree().create_timer(0.5).timeout
		claim = Net.my_claim()
		if claim.is_empty():
			_clear_my_room()                        # 已经被别人占了，别再惦记
			return

	var parts := claim.split(":")
	if parts.size() < 2:
		return
	var floor_n: int = int(parts[0])
	var idx: int = int(parts[1])
	# 本地存档里有房 → 顺手再向服务端贴一次（幂等；房被别人占了服务端会驳回）
	Net.claim_room(floor_n, idx, Net.local_name)
	# 服务端那份没有公告（重启 / 旧版服务端）→ 用本地存档里的正文补回去
	var cur: Dictionary = Net.room_claims.get("%d:%d" % [floor_n, idx], {})
	if String(cur.get("note", "")).is_empty():
		var saved_note := _load_my_room_note()
		if not saved_note.is_empty():
			Net.set_room_note(idx, saved_note)
	if not enter_room(DORM_PATH, floor_n):
		return
	var bed: Vector2 = _bed_of(idx)
	if bed == Vector2.ZERO:
		return
	# 每次上线都睡在自己的床上（站嫌疑人身上出生会卡住，躺着是物理关闭的状态，稳）
	me.call("teleport_to", bed)
	Net.sit_down(LIE_SEAT_CODE + _face_code("up"), bed)
	print("[arena] 回到了自己的宿舍：%d 层 %d 号房" % [floor_n, idx + 1])


func _wait_local_avatar(timeout: float) -> Node:
	var left := timeout
	while left > 0.0:
		var me := _local_avatar()
		if me != null:
			return me
		await get_tree().create_timer(0.3).timeout
		left -= 0.3
	return null


func _load_my_room() -> Vector2i:
	var cfg := ConfigFile.new()
	if cfg.load(MY_ROOM_CFG) != OK:
		return Vector2i(-1, -1)
	var f: int = int(cfg.get_value("room", "floor", 0))
	var r: int = int(cfg.get_value("room", "index", -1))
	# 旧版把 B1 组队板当成「我的房间」写进了存档（开队即退宿舍）。这份存档
	# 不能用来决定出生点，也不能灌进 Net.my_room_cache —— 一律当作没认领。
	if f == Net.TEAM_FLOOR:
		return Vector2i(-1, -1)
	return Vector2i(f, r)


## 存档里的门口公告正文（没写过就是空串）
func _load_my_room_note() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(MY_ROOM_CFG) != OK:
		return ""
	return String(cfg.get_value("room", "note", ""))


## 记下「我的房间」：楼层、房号、房名、门口公告正文。
## 服务端只把认领存在内存里，重启/换服就没了；本地这一份保证退出重进还认自己的房，
## 公告也就跟着留了下来。
func _save_my_room(floor_n: int, idx: int, note: String = "") -> void:
	if floor_n < 1 or idx < 0:
		return
	var cfg := ConfigFile.new()
	cfg.load(MY_ROOM_CFG)                       # 合并写：别把没改的字段抹掉
	cfg.set_value("room", "floor", floor_n)
	cfg.set_value("room", "index", idx)
	cfg.set_value("room", "name", Net.local_name)
	cfg.set_value("room", "note", note)
	cfg.save(MY_ROOM_CFG)
	Net.set_cached_room(floor_n, idx, Net.local_name, note)


## 开局把存档里那间房灌进 Net：还没连上服务器时，门牌和公告就该显示自己的
func _restore_my_room() -> void:
	var saved := _load_my_room()
	if saved.x < 1:
		# 迁移：旧版开 B1 队伍时把 6:idx 写成了「我的房间」，清掉这份坏存档，
		# 否则下次上线又会被灌回 Net，宿舍照样丢。
		var cfg := ConfigFile.new()
		if cfg.load(MY_ROOM_CFG) == OK \
			and int(cfg.get_value("room", "floor", 0)) == Net.TEAM_FLOOR:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(MY_ROOM_CFG))
			Net.my_room_cache = {}
		return
	Net.set_cached_room(saved.x, saved.y, Net.local_name, _load_my_room_note())


func _clear_my_room() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(MY_ROOM_CFG))
	Net.my_room_cache = {}


func _local_avatar() -> Node:
	for c in players.get_children():
		if c != null and c.get("is_local_player") == true:
			return c
	return null


## 这个 avatar 现在实际摆着的姿势（0 = 站着）。**别直接读 sit_dir 做交互判定** ——
## 那是同步属性，服务器每 33ms 盖回来一次，而本地权威姿势要等玩家的 _process 才贴回，
## Arena 是父节点、跑在前面，正好卡在那一帧里读到旧值（提示条就是这么抖起来的）。
func _pose_of(n: Node) -> int:
	if n == null or not is_instance_valid(n) or not n.has_method("pose_now"):
		return 0
	return int(n.call("pose_now"))


# ══════════════════════════════════════════════════════════════════════════
#  多层宿舍楼：电梯换层 + 门口公告
#
#  核心做法：**只实例化一个楼层**。每层布局完全一样（同一份 dorm_space.json），
#  所以「换层」不搬任何几何，只改每个玩家身上的楼层号 ——
#  省内存（5 层也只有一份房间节点），也保证多层布局天然一致。
#  楼层号随 roster 同步（Net.peers[id]["floor"]），
#  「同层的人才互相看得见」用 visible 过滤；认领公告是服务端权威字典，广播全量快照。
# ══════════════════════════════════════════════════════════════════════════

## 站在多近才算「门口」（格）：15 间的门间距 13 格，3.2 只会命中正对着的那间
const CLAIM_RADIUS := 3.2
## 电梯呼叫范围（格）：电梯本体 6×6，外扩 1 格就可以站在门口按 E
const ELEV_PAD := 1.0
## 公告牌离门洞的偏移（格）：往下/往上让开半格，别压在门框上
const PLATE_OFF := 0.6


## 楼层 UI 是懒创建的：进党楼才有，校园里不占任何节点。
func _ensure_floor_ui() -> void:
	if _floor_layer != null and is_instance_valid(_floor_layer):
		return
	_floor_layer = CanvasLayer.new()
	_floor_layer.name = "FloorUI"
	_floor_layer.layer = 6
	add_child(_floor_layer)

	var host := Control.new()
	host.name = "Host"
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_floor_layer.add_child(host)
	_door_plates_holder = host

	# 楼层指示（左上角）
	_floor_label = Label.new()
	_floor_label.position = Vector2(12, 10)
	_floor_label.add_theme_font_size_override("font_size", 18)
	_floor_label.add_theme_color_override("font_color", Color("#e8f2ff"))
	_floor_label.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.95))
	_floor_label.add_theme_constant_override("outline_size", 4)
	_floor_label.visible = false
	host.add_child(_floor_label)

	# 底部提示条（认领成功 / 已被别人占了）
	_notice_label = Label.new()
	_notice_label.add_theme_font_size_override("font_size", 17)
	_notice_label.add_theme_color_override("font_color", Color("#ffe9a8"))
	_notice_label.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.95))
	_notice_label.add_theme_constant_override("outline_size", 4)
	_notice_label.visible = false
	host.add_child(_notice_label)

	# 选层面板
	_floor_panel = _build_floor_panel()
	_floor_panel.visible = false
	host.add_child(_floor_panel)

	# 门口公告面板（要在换层黑场之前加，黑场才盖得住它）
	_note_panel = _build_note_panel()
	_note_panel.visible = false
	host.add_child(_note_panel)
	_note_view = _build_note_view()
	_note_view.visible = false
	host.add_child(_note_view)

	# 换层黑场（加在最后 → 盖在最上层）
	_floor_flash = ColorRect.new()
	_floor_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_floor_flash.color = Color(0.02, 0.03, 0.05, 1.0)
	_floor_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_floor_flash.visible = false
	host.add_child(_floor_flash)


func _build_floor_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.14, 0.96)
	sb.border_color = Color(0.62, 0.70, 0.82, 0.95)
	sb.set_border_width_all(2)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	pc.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	pc.add_child(vb)

	var title := Label.new()
	title.text = "电梯 · 选择楼层"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color("#dfeaff"))
	title.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.95))
	title.add_theme_constant_override("outline_size", 4)
	vb.add_child(title)

	var g := GridContainer.new()
	g.columns = 3                       # 5 个地上层 + B1 = 6 个按钮，两行三列
	g.add_theme_constant_override("h_separation", 8)
	g.add_theme_constant_override("v_separation", 8)
	vb.add_child(g)
	for i in FLOOR_COUNT:
		var b := Button.new()
		b.text = "%d 层" % (i + 1)
		b.custom_minimum_size = Vector2(88, 42)
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 17)
		b.add_theme_color_override("font_color", Color("#e8f4ff"))
		b.pressed.connect(_on_floor_picked.bind(i + 1))
		g.add_child(b)
	var bb := Button.new()
	bb.text = "B1 · 活动室"
	bb.custom_minimum_size = Vector2(88, 42)
	bb.focus_mode = Control.FOCUS_NONE
	bb.add_theme_font_size_override("font_size", 17)
	bb.add_theme_color_override("font_color", Color("#ffd88a"))
	bb.pressed.connect(_on_floor_picked.bind(BASEMENT_FLOOR))
	g.add_child(bb)
	return pc


func _layout_floor_panel() -> void:
	var vs := get_viewport().get_visible_rect().size
	var sz := _floor_panel.get_combined_minimum_size()
	_floor_panel.position = Vector2((vs.x - sz.x) * 0.5, (vs.y - sz.y) * 0.5)


func _open_floor_panel() -> void:
	if _floor_open:
		return
	_ensure_floor_ui()
	_layout_floor_panel()
	_floor_panel.visible = true
	_floor_open = true


func _close_floor_panel() -> void:
	_floor_open = false
	if _floor_panel != null and is_instance_valid(_floor_panel):
		_floor_panel.visible = false


func _on_floor_picked(n: int) -> void:
	_go_floor(n)


## 换层的全部事情：改楼层号（广播给别人）+ 站到新楼层的电梯口 + 刷新门牌 + 黑场淡入。
## 地上 1~5 层布局相同，只换层号；地上 ↔ B1 则连房间布局一起换（4 个大单间 vs 14 间小隔间）。
func _go_floor(n: int) -> void:
	var want: int = clampi(n, 1, BASEMENT_FLOOR)
	_close_floor_panel()
	if want == current_floor:
		return
	var was_basement := current_floor == BASEMENT_FLOOR
	var is_basement := want == BASEMENT_FLOOR
	current_floor = want
	Net.set_my_floor(want)
	if is_basement != was_basement:
		_ensure_room_for_floor(want)
		_collect_room_seats()
		_build_door_plates()
		_update_room_doors()
		_setup_room_cats()   # 房间整份重建后，猫窝也要重新挂
	var me: Node = _local_avatar()
	if me != null:
		# 跨布局换层时房间是整份重建的，相机边界必须重新按新房间矩形算一遍。
		# 漏了这一步的话：从宿舍（窄）切到 B1 活动室（132 格宽）后，limit_right 还
		# 停在旧房间的右墙 —— 人走过那道看不见的线，相机就顶死不动，角色一路走出
		# 屏幕，表现就是「活动室右半边视角不跟随、看不到人」。
		if is_basement != was_basement:
			_set_cam_limit(me, true)
			_fit_room_zoom(me)
		var spot: Vector2 = _elevator_step_out()
		me.call("teleport_to", spot)
		# 换层 = 房间里换一个「层号」：同层才互相可见，位置也一起同步过去
		me.call("set_room_state", true, want, spot)
	_refresh_door_plates()
	_update_floor_label()
	_update_floor_visibility()
	_fade_flash()


## 从轿厢里退出到走廊的那一点：电梯西边 2 格、走廊中线，落地就在电梯门口而不会贴在门上。
func _elevator_step_out() -> Vector2:
	if room == null or not is_instance_valid(room):
		return Vector2.ZERO
	var el: Dictionary = room.get("data").get("elevator", {})
	if el.is_empty():
		return room.position + room.get("spawn_px")
	var cell := Vector2(float(el["x"]) - 2.0, float(el["y"]) + float(el["h"]) * 0.5)
	return room.position + cell * TS


func _fade_flash() -> void:
	_ensure_floor_ui()
	_floor_flash.visible = true
	_floor_flash.modulate = Color(1, 1, 1, 1)
	var tw := create_tween()
	tw.tween_property(_floor_flash, "modulate:a", 0.0, 0.45)
	tw.tween_callback(func() -> void:
		if _floor_flash != null and is_instance_valid(_floor_flash):
			_floor_flash.visible = false)


func _update_floor_label() -> void:
	if not in_room:
		if _floor_label != null and is_instance_valid(_floor_label):
			_floor_label.visible = false
		return
	_ensure_floor_ui()
	_floor_label.visible = true
	if current_floor == BASEMENT_FLOOR:
		_floor_label.text = "B1 · 游戏活动室"
	else:
		_floor_label.text = "宿舍楼 · %d / %d 层" % [current_floor, FLOOR_COUNT]


## 是否站在电梯前（房间局部坐标，格）
func _near_elevator(pos: Vector2) -> bool:
	if room == null or not is_instance_valid(room):
		return false
	var el: Dictionary = room.get("data").get("elevator", {})
	if el.is_empty():
		return false
	var r := Rect2(float(el["x"]), float(el["y"]), float(el["w"]), float(el["h"]))
	return r.grow(ELEV_PAD).has_point((pos - room.position) / TS)


# ── 房间门禁：谁能进自己的房间 ──────────────────────────────────────────
## 返回这扇门的判定结果：
##   state  empty（空房，谁都能进）/ mine / friend / locked
##   open   我能不能通过（false = 门锁着，碰撞在）
##   locked 门要不要挂锁标
##
## 认领关系是服务端权威的（Net.room_claims），好友关系也是（Net.is_friend），
## 这里只做一次组合判断，不改任何状态。
func _room_gate(idx: int) -> Dictionary:
	var key := "%d:%d" % [current_floor, idx]
	var cur: Dictionary = Net.room_claims.get(key, {})
	if cur.is_empty():
		return {"state": "empty", "open": true, "locked": false, "name": "", "uid": ""}
	var owner_uid := String(cur.get("uid", ""))
	var owner_name := String(cur.get("name", "某人"))
	if owner_uid.is_empty() or owner_uid == Net.local_uid:
		return {"state": "mine", "open": true, "locked": false, "name": owner_name, "uid": owner_uid}
	if Net.is_friend(owner_uid):
		return {"state": "friend", "open": true, "locked": false, "name": owner_name, "uid": owner_uid}
	return {"state": "locked", "open": false, "locked": true, "name": owner_name, "uid": owner_uid}


## 8Hz 巡检（和提示条同一拍）：按「我在哪 + 这扇门归谁」决定每扇门开还是关。
## 动画本身在 RoomDoor._process 里逐帧插值，所以离散判定看不出来。
func _update_room_doors() -> void:
	if not in_room or room == null or not is_instance_valid(room):
		return
	if current_floor == BASEMENT_FLOOR:
		# B1 没有会锁的宿舍门，8Hz 巡检改成刷组队板的「已入座几人」
		_refresh_team_plates()
		return
	var me: Node = _local_avatar()
	if me == null:
		return
	var my_pos: Vector2 = (me as Node2D).position
	var doors: Array = room.get("doors")
	for raw in doors:
		var dr: Node = raw
		if dr == null or not is_instance_valid(dr):
			continue
		var idx: int = int(dr.get("claim_index"))
		var cel: Rect2 = dr.get("cell")
		var wp: Vector2 = (room as Node2D).position + Vector2(
			cel.get_center().x * TS, cel.get_center().y * TS)
		var dist: float = my_pos.distance_to(wp)
		var gate := _room_gate(idx)
		dr.call("set_locked", bool(gate["locked"]))
		if bool(gate["open"]) and dist < DOOR_OPEN_R:
			dr.call("set_open", true)
		elif dist > DOOR_CLOSE_R:
			dr.call("set_open", false)
		# 没权限还贴到门口：锁闪一下，比干站着推门有反馈
		if bool(gate["locked"]) and dist < DOOR_OPEN_R * 0.75:
			dr.call("warn")


## 站在旁边（FRIEND_RANGE 内）的另一个玩家。房间/楼层要一致，否则会加到
## 另一个楼层上看得见名字、实际不在身边的人。
func _near_player() -> Dictionary:
	var me: Node = _local_avatar()
	if me == null or players == null or not is_instance_valid(players):
		return {}
	var my_pos: Vector2 = (me as Node2D).position
	var best: Dictionary = {}
	var best_d := FRIEND_RANGE
	for c in players.get_children():
		if c == null or not is_instance_valid(c):
			continue
		if bool(c.get("is_local_player")):
			continue
		if bool(c.get("room_inside")) != in_room:
			continue
		if in_room and int(c.get("room_floor")) != current_floor:
			continue
		var d: float = (c as Node2D).position.distance_to(my_pos)
		if d >= best_d:
			continue
		var pid: int = int(c.get("owner_peer_id"))
		var info: Dictionary = Net.peers.get(pid, {})
		if info.is_empty():
			continue
		best_d = d
		best = {
			"id": pid,
			"name": String(info.get("name", "?")),
			"uid": String(info.get("uid", "")),
		}
	return best


## 站在别人旁边时提示条写什么。四种状态各一句，按 E 的动作也各不相同。
func _buddy_hint(b: Dictionary) -> String:
	var nm := String(b.get("name", "?"))
	match Net.friend_state(String(b.get("uid", ""))):
		"friend":
			return "你和「%s」是好友 · 他的房间你能进" % nm
		"out":
			return "已向「%s」发送好友请求，等回应" % nm
		"in":
			return "按 E 接受「%s」的好友请求" % nm
		_:
			return "按 E 和「%s」成为好友" % nm


## E 键加好友：已经是好友 / 已发过 / 对方求我 / 全新，四种情况各走各的。
func _try_add_friend(b: Dictionary) -> void:
	var uid := String(b.get("uid", ""))
	var nm := String(b.get("name", "?"))
	if uid.is_empty():
		return
	match Net.friend_state(uid):
		"friend":
			_notice("你和「%s」已经是好友了" % nm)
		"out":
			_notice("已经发过请求了，等「%s」回应" % nm)
		"in":
			Net.friend_accept(uid)
			_notice("已接受「%s」的好友请求" % nm)
		_:
			Net.friend_request(uid)
			_notice("已向「%s」发送好友请求，等对方按 E 接受" % nm)


## 好友表变了（自己加/删、别人通过）：门锁和门牌都得跟着变。
func _on_social_changed() -> void:
	_refresh_door_plates()
	_update_room_doors()


## 离玩家最近的那扇宿舍门（CLAIM_RADIUS 内），没有就返回空字典
func _nearest_room_door(pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	if room == null or not is_instance_valid(room):
		return best
	var lp: Vector2 = (pos - room.position) / TS
	var best_d := CLAIM_RADIUS
	for item in room.get("data").get("room_doors", []):
		var d: Dictionary = item
		var dist: float = lp.distance_to(Vector2(
			float(d["x"]) + float(d["w"]) * 0.5,
			float(d["y"]) + float(d["h"]) * 0.5))
		if dist < best_d:
			best_d = dist
			best = d
	return best


# ── B1 组队板 ───────────────────────────────────────────────────────────
## 组队板直接复用宿舍的认领/公告同步：一块板 = Net.room_claims 里的 "6:idx"。
## 开队就是认领，招募正文就是 note，撤队就是退认领 —— 服务端协议一行没改。
func _team_board_name(idx: int) -> String:
	if room == null or not is_instance_valid(room):
		return "%d 区" % (idx + 1)
	for b in room.get("data").get("team_boards", []):
		if int(b.get("index", -1)) == idx:
			return String(b.get("name", "%d 区" % (idx + 1)))
	return "%d 区" % (idx + 1)


## 站在哪块组队板前（房间局部坐标，格）。半径沿用门口认领的 CLAIM_RADIUS。
func _nearest_team_board(pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	if room == null or not is_instance_valid(room):
		return best
	var lp: Vector2 = (pos - room.position) / TS
	var best_d := CLAIM_RADIUS
	for b in room.get("data").get("team_boards", []):
		var bd: Dictionary = b
		var dist: float = lp.distance_to(Vector2(
			float(bd["x"]) + float(bd["w"]) * 0.5,
			float(bd["y"]) + float(bd["h"]) * 0.5))
		if dist < best_d:
			best_d = dist
			best = bd
	return best


## 这间活动室此刻坐着几个人。「进去找空位坐下」就是加入队伍，不用另做一套报名状态。
func _team_seated_count(idx: int) -> int:
	if room == null or not is_instance_valid(room) or players == null:
		return 0
	var rr: Array = []
	for b in room.get("data").get("team_boards", []):
		if int(b.get("index", -1)) == idx:
			rr = b.get("room_rect", [])
			break
	if rr.size() < 4:
		return 0
	var area := Rect2(
		room.position + Vector2(float(rr[0]), float(rr[1])) * TS,
		Vector2(float(rr[2]), float(rr[3])) * TS)
	var n := 0
	for c in players.get_children():
		if c == null or not is_instance_valid(c):
			continue
		if _pose_of(c) == 0:
			continue
		if int(c.get("room_floor")) != BASEMENT_FLOOR:
			continue
		if area.has_point((c as Node2D).position):
			n += 1
	return n


# ── OOPZ 语音 ────────────────────────────────────────────────────────────
## OOPZ 没有开放平台（官方无 API/SDK，社区那套是逆向的私有协议），
## 所以做不到「坐下就被拉进语音」。能做的是：房主把自己的语音频道分享链接
## 贴在组队板上，队员坐下时右下角出现「进语音」，点一下唤起 OOPZ 落到频道。
## **只接受「语音频道」邀请，不接受「域」邀请**（用户明确要求）：域邀请点开只到
## 域首页，用户还得自己找频道点进去，等于没生效。两者 URL 形态一样（oopz.cn/i/xxxx），
## 程序无法分辨，只能靠面板文案 + 打开后那句提示引导自查。
## 链接存在公告首行、带 @oopz: 前缀 —— room_claims 本来就是个自由文本 note，
## 这样不用动服务端 schema，老版本客户端也不会 checksum failed。
const OOPZ_TAG := "@oopz:"

## 把公告拆成 [语音链接, 正文]。链接只在首行、靠前缀标记，展示时剥掉。
func _note_split(note: String) -> Array:
	var link := ""
	var body := PackedStringArray()
	for ln in note.split("\n", true):
		var t: String = ln.strip_edges()
		if link.is_empty() and t.to_lower().begins_with(OOPZ_TAG):
			link = t.substr(OOPZ_TAG.length()).strip_edges()
			continue
		body.append(ln)
	return [link, "\n".join(body).strip_edges()]


## 只放行 http/https/oopz 三种 scheme。OS.shell_open 是把字符串直接丢给系统，
## 任意 scheme（file://、ms-msdt: 之类）都可能被当成可执行协议，必须白名单。
## 没写 scheme 的（房主直接粘 oopz.cn/xxx）按 https 补上。
func _safe_voice_link(s: String) -> String:
	var t: String = s.replace("\r", "").replace("\n", "").strip_edges()
	if t.is_empty():
		return ""
	var low := t.to_lower()
	if not low.contains("://"):
		# 没写 scheme 的（房主直接粘 oopz.cn/xxx）按 https 补，但先挡掉
		# javascript:/data:/file: 这类「有冒号没双斜杠」的伪协议
		if low.contains(":") or not low.contains("."):
			return ""
		return "https://" + t
	if low.begins_with("https://") or low.begins_with("http://") or low.begins_with("oopz://"):
		return t
	return ""


## 粗判「像不像 OOPZ 邀请」。注意：域邀请和语音频道邀请的 URL 形态完全一样
## （都是 oopz.cn/i/xxxxxx，网页渲染也一模一样），程序**没法**区分两者，
## 这里只能挡掉明显不是邀请的东西（别的网站、oopz 主站首页），剩下的靠面板文案约束。
func _looks_oopz_invite(s: String) -> bool:
	var low := s.to_lower()
	if low.begins_with("oopz://"):
		return true
	if not low.contains("oopz.cn"):
		return false
	return low.contains("/i/")


## 某个单间的组队板上留的语音链接（没有就返回空串）
func _room_voice_link(room_idx: int) -> String:
	var cur: Dictionary = Net.room_claims.get("%d:%d" % [BASEMENT_FLOOR, room_idx], {})
	if cur.is_empty():
		return ""
	var parts := _note_split(String(cur.get("note", "")))
	return _safe_voice_link(String(parts[0]))


## 坐着的人在哪个单间：找脚下最近的那把椅子，读它数据里的 room。
func _seat_room_at(pos: Vector2) -> int:
	var best := -1
	var best_d := 4.0 * TS          # 4 格内都算「坐在这把椅子上」
	for item in _seats_room:
		var s: Dictionary = item
		if String(s.get("kind", "")) != "chair":
			continue
		if int(s.get("room", -1)) < 0:
			continue
		var d: float = pos.distance_to(s["pos"])
		if d < best_d:
			best_d = d
			best = int(s["room"])
	return best


## 连一下本机端口看通不通（回环连接正常几毫秒，最坏 60ms 收手）。
## OOPZ 主进程固定监听 127.0.0.1:10274（webview 壳）和 49266（健康检查），
## 客户端没开时两个都连不上 —— 实测重启两次端口都不变（2026-11-05）。
## 这里刻意**不用 tasklist**：那玩意儿在这台机器上要 1.1 秒，按一下 V 卡一秒，
## 联机时位置同步会直接跳。
func _port_open(port: int) -> bool:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host("127.0.0.1", port) != OK:
		return false
	var deadline := Time.get_ticks_msec() + 60
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var st := peer.get_status()
		if st == StreamPeerTCP.STATUS_CONNECTED:
			peer.disconnect_from_host()
			return true
		if st == StreamPeerTCP.STATUS_ERROR:
			peer.disconnect_from_host()
			return false
		OS.delay_msec(2)
	peer.disconnect_from_host()
	return false


## 本机 OOPZ 客户端有没有开着。
## 为什么要判：2026-11-05 实测，系统里根本没注册任何 oopz 协议
## （HKCR/HKCU 全无 oopz*），客户端也不认命令行参数，所以链接只能落浏览器。
## 客户端已经开着的时候再甩一个浏览器出来纯属添乱 —— 那种情况只把链接复制到剪贴板。
func _oopz_client_running() -> bool:
	if not OS.has_feature("windows"):
		return false
	return _port_open(10274) or _port_open(49266)


## 唤起 OOPZ。客户端开着 → 只复制链接（不抢焦点）；没开 → 打开邀请页（落 web.oopz.cn）。
## 打不开就把链接塞剪贴板，至少用户还能自己粘。
func _open_voice(link: String) -> void:
	var safe := _safe_voice_link(link)
	if safe.is_empty():
		_notice("这支队还没留 OOPZ 语音频道链接")
		return
	if _oopz_client_running():
		DisplayServer.clipboard_set(safe)
		_notice("OOPZ 正在运行 · 链接已复制，在客户端里粘贴即可加入")
		return
	var err := OS.shell_open(safe)
	if err != OK:
		DisplayServer.clipboard_set(safe)
		_notice("没能唤起 OOPZ（没装客户端？）· 链接已复制：%s" % safe.left(46))
		return
	if _looks_oopz_invite(safe):
		# 实测（2026-11-05）：系统里没有注册任何 oopz 协议，客户端只能托盘常驻，
		# 链接一律落到浏览器（web.oopz.cn）。所以文案写实际会发生的事，别骗用户。
		_notice("已打开 OOPZ 邀请页 · 点「进入」后再选语音频道（不会自动进麦）")
	else:
		_notice("已在系统里打开，但这链接不像语音频道邀请 · 可能进不去频道")


func _on_note_view_voice_pressed() -> void:
	_open_voice(_note_view_link)



# ── 门口公告 ─────────────────────────────────────────────────────────────
## 每间宿舍门口一块牌子（世界坐标锚定，跟着相机走）。
## 没被认领时显示淡色房号；被认领后显示「某某的房间」亮字。
func _build_door_plates() -> void:
	_clear_door_plates()
	if room == null or not is_instance_valid(room):
		return
	_ensure_floor_ui()
	# B1 没有会锁的宿舍门，牌子改挂在 4 块组队板上；ax/ay 是组队板专用锚点。
	var is_b1 := current_floor == BASEMENT_FLOOR
	var plate_src: Array = (room.get("data").get("team_boards", []) if is_b1
		else room.get("data").get("room_doors", []))
	for item in plate_src:
		var d: Dictionary = item
		var pc := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.05, 0.07, 0.11, 0.88)
		sb.border_color = Color(0.55, 0.62, 0.72, 0.85)
		sb.set_border_width_all(2)
		sb.content_margin_left = 6
		sb.content_margin_right = 6
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		pc.add_theme_stylebox_override("panel", sb)
		var lb := Label.new()
		lb.add_theme_font_size_override("font_size", 13)
		lb.add_theme_color_override("font_color", Color("#cfe2f5"))
		lb.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.95))
		lb.add_theme_constant_override("outline_size", 3)
		pc.add_child(lb)
		pc.visible = false
		pc.z_index = -1
		_door_plates_holder.add_child(pc)
		_door_plates.append({
			"index": int(d["index"]), "side": String(d.get("side", "n")),
			"x": float(d["x"]), "y": float(d["y"]),
			"w": float(d["w"]), "h": float(d["h"]),
			"ax": (float(d["x"]) + float(d["w"]) * 0.5) if is_b1 else -1.0,
			"ay": (float(d["y"]) + float(d["h"]) * 0.5) if is_b1 else -1.0,
			"team": is_b1,
			"panel": pc, "label": lb,
		})
	_refresh_door_plates()


func _clear_door_plates() -> void:
	for item in _door_plates:
		var pc: PanelContainer = item["panel"]
		if is_instance_valid(pc):
			pc.queue_free()
	_door_plates.clear()


# ── 门口公告板（自我介绍） ─────────────────────────────────────────────
## 牌子上只写房名（有人住 / 空房），公告正文不外显：
## 站到自己房门口按 E 是编写，站到别人房门口按 E 是打开一个只读面板看全文。
## 这样走廊上不会挂满长文字，但想看的人一按就能看到。

func _build_note_panel() -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.14, 0.97)
	sb.border_color = Color(0.95, 0.78, 0.38, 0.95)
	sb.set_border_width_all(2)
	sb.content_margin_left = 16
	sb.content_margin_right = 16
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	pc.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 9)
	pc.add_child(vb)
	_note_title = Label.new()
	_note_title.add_theme_font_size_override("font_size", 17)
	_note_title.add_theme_color_override("font_color", Color("#ffe9a8"))
	_note_title.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.95))
	_note_title.add_theme_constant_override("outline_size", 4)
	vb.add_child(_note_title)
	_note_hint = Label.new()
	_note_hint.text = "写点自我介绍：叫什么、哪个学院、作息、想认识什么样的人…（最多 160 字）"
	_note_hint.add_theme_font_size_override("font_size", 12)
	_note_hint.add_theme_color_override("font_color", Color(0.62, 0.70, 0.80))
	vb.add_child(_note_hint)

	# OOPZ 语音链接（只有 B1 组队板显示）。OOPZ 没开放平台，做不到游戏内直接连麦，
	# 但把频道分享链接存在板子上，队员坐下就能一键唤起客户端进同一个频道。
	_oopz_box = VBoxContainer.new()
	_oopz_box.add_theme_constant_override("separation", 4)
	_oopz_box.visible = false
	vb.add_child(_oopz_box)
	var ol := Label.new()
	ol.text = "OOPZ 语音频道邀请 · 选填（只认语音频道的邀请）"
	ol.add_theme_font_size_override("font_size", 12)
	ol.add_theme_color_override("font_color", Color(0.55, 0.86, 0.72))
	_oopz_box.add_child(ol)
	_oopz_edit = LineEdit.new()
	_oopz_edit.placeholder_text = "粘贴「语音频道」的邀请链接（不是域的邀请）"
	_oopz_edit.custom_minimum_size = Vector2(460, 38)
	_oopz_edit.add_theme_font_size_override("font_size", 14)
	_oopz_edit.add_theme_color_override("font_color", Color("#dff5e8"))
	_oopz_box.add_child(_oopz_edit)
	# 这一行是重点：域邀请和频道邀请的 URL 长得一模一样，程序分辨不出来，
	# 只能靠文案把「必须是语音频道」讲清楚，否则房主随手贴域的邀请，队员点进去
	# 停在域首页、还以为游戏坏了。
	var oh := Label.new()
	oh.text = "在 OOPZ 里点开要用的那个语音频道 → 复制邀请 → 粘到这里。\n" \
		+ "别贴「域」的邀请：打开后卡片写「你收到了一个域邀请」就是贴错了，\n" \
		+ "那样只能进到域首页，队员还得自己找频道、点了也听不到人。"
	oh.add_theme_font_size_override("font_size", 11)
	oh.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	oh.custom_minimum_size = Vector2(460, 0)
	oh.add_theme_color_override("font_color", Color(0.58, 0.66, 0.74))
	_oopz_box.add_child(oh)

	_note_edit = TextEdit.new()
	_note_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_note_edit.custom_minimum_size = Vector2(460, 150)
	_note_edit.add_theme_font_size_override("font_size", 15)
	_note_edit.add_theme_color_override("font_color", Color("#e6effb"))
	_note_edit.text_changed.connect(_update_note_count)
	vb.add_child(_note_edit)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	vb.add_child(hb)
	_note_count = Label.new()
	_note_count.add_theme_font_size_override("font_size", 12)
	_note_count.add_theme_color_override("font_color", Color(0.55, 0.62, 0.72))
	hb.add_child(_note_count)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)
	for cfg: Array in [["保存", _save_note_board], ["擦掉", _clear_note_board], ["取消", _close_note_board]]:
		var b := Button.new()
		b.text = String(cfg[0])
		b.custom_minimum_size = Vector2(96, 46)      # 手机上 34px 高的按钮太难点
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 16)
		b.pressed.connect(cfg[1] as Callable)
		hb.add_child(b)
	# 退房（= 撕下名牌）。桌面上按 F 就行，但手机没有 F 键，必须给个能点的入口，
	# 否则手机上认了房就再也退不掉。
	_note_bye_btn = Button.new()
	_note_bye_btn.text = "退房"
	_note_bye_btn.custom_minimum_size = Vector2(96, 46)
	_note_bye_btn.focus_mode = Control.FOCUS_NONE
	_note_bye_btn.add_theme_font_size_override("font_size", 16)
	_note_bye_btn.add_theme_color_override("font_color", Color("#ff9a84"))
	_note_bye_btn.pressed.connect(_leave_my_room)
	hb.add_child(_note_bye_btn)
	return pc


## 退房：撕下自己门口的名牌，存档一起清掉（下次上线回校园出生）。
func _leave_my_room() -> void:
	if _note_room_idx < 0:
		return
	var idx: int = _note_room_idx
	_close_note_board()
	Net.claim_room(current_floor, idx, "")          # 空名字 = 撕下来
	var key := "%d:%d" % [current_floor, idx]
	var is_b1 := current_floor == BASEMENT_FLOOR
	if Net.room_claims.has(key):
		_notice(("没能撤掉 %s 的队伍（服务器没接受请求）" % _team_board_name(idx)) if is_b1 else \
			("没能退掉 %d 层 %d 号房（服务器没接受请求）" % [current_floor, idx + 1]))
		return
	# 撤队只撤组队板，绝不能清「我的宿舍」存档 —— 以前这里连 _clear_my_room()
	# 一起调，房主撤个队，宿舍就没了。
	if not is_b1:
		_clear_my_room()
	if is_b1:
		_notice("已撤下 %s 的组队招募" % _team_board_name(idx))
	else:
		_notice("已撕下 %d 层 %d 号房的名牌，下次上线从校园出生" % [current_floor, idx + 1])


func _update_note_count() -> void:
	if _note_count != null:
		_note_count.text = "%d / 160 字" % _note_edit.text.length()


## 只读面板：别人家的公告全文（可换行、按宽度自动折行）。
func _build_note_view() -> PanelContainer:
	var pc := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.13, 0.97)
	sb.border_color = Color(0.55, 0.66, 0.80, 0.95)
	sb.set_border_width_all(2)
	sb.content_margin_left = 18
	sb.content_margin_right = 18
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	pc.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	pc.add_child(vb)
	_note_view_title = Label.new()
	_note_view_title.add_theme_font_size_override("font_size", 17)
	_note_view_title.add_theme_color_override("font_color", Color("#ffe9a8"))
	_note_view_title.add_theme_color_override("font_outline_color", Color(0.02, 0.03, 0.05, 0.95))
	_note_view_title.add_theme_constant_override("outline_size", 4)
	vb.add_child(_note_view_title)
	_note_view_body = Label.new()
	_note_view_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note_view_body.custom_minimum_size = Vector2(420, 0)
	_note_view_body.add_theme_font_size_override("font_size", 15)
	_note_view_body.add_theme_color_override("font_color", Color("#dbe7f5"))
	vb.add_child(_note_view_body)
	# 队长留了 OOPZ 频道才显示：站在板前就能直接进语音（不用先坐下）
	_note_view_voice = Button.new()
	_note_view_voice.text = "加入 OOPZ 语音频道"
	_note_view_voice.custom_minimum_size = Vector2(0, 48)
	_note_view_voice.focus_mode = Control.FOCUS_NONE
	_note_view_voice.add_theme_font_size_override("font_size", 16)
	_note_view_voice.add_theme_color_override("font_color", Color("#d8ffe8"))
	for st in ["normal", "hover", "pressed", "focus"]:
		var vsb := StyleBoxFlat.new()
		vsb.bg_color = Color(0.07, 0.16, 0.12, 0.95) if st == "normal" else Color(0.10, 0.22, 0.16, 0.98)
		vsb.border_color = Color(0.42, 0.90, 0.66, 0.95)
		vsb.set_border_width_all(2)
		vsb.content_margin_left = 12
		vsb.content_margin_right = 12
		vsb.content_margin_top = 8
		vsb.content_margin_bottom = 8
		_note_view_voice.add_theme_stylebox_override(st, vsb)
	_note_view_voice.visible = false
	_note_view_voice.pressed.connect(_on_note_view_voice_pressed)
	vb.add_child(_note_view_voice)
	var foot_row := HBoxContainer.new()
	vb.add_child(foot_row)
	var foot := Label.new()
	foot.text = "按 E / Esc 关闭"
	foot.add_theme_font_size_override("font_size", 12)
	foot.add_theme_color_override("font_color", Color(0.55, 0.62, 0.72))
	foot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot_row.add_child(foot)
	# 手机上没有 E/Esc 键：给一个能点的关闭按钮
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(96, 44)
	close_btn.focus_mode = Control.FOCUS_NONE
	close_btn.add_theme_font_size_override("font_size", 16)
	close_btn.pressed.connect(_close_note_view)
	foot_row.add_child(close_btn)
	return pc


## 打开某间房的公告板：自己的可编辑，别人的只读，空房提示先认领。
func _open_note_board(idx: int) -> void:
	var is_b1 := current_floor == BASEMENT_FLOOR
	if _note_hint != null:
		_note_hint.text = "想玩什么、几缺几、什么段位、开麦吗…（最多 160 字）" if is_b1 else \
			"写点自我介绍：叫什么、哪个学院、作息、想认识什么样的人…（最多 160 字）"
	if _note_bye_btn != null:
		_note_bye_btn.text = "撤队" if is_b1 else "退房"
	var label := _team_board_name(idx) if is_b1 else "%d 号房" % (idx + 1)
	var key := "%d:%d" % [current_floor, idx]
	var cur: Dictionary = Net.room_claims.get(key, {})
	if cur.is_empty():
		if not is_b1:
			_notice("%d 号房还没人认领 · 先按 E 认领，再来写公告" % (idx + 1))
			return
		# B1 空板 = 直接开队。claim_room 客户端会先本地预写，所以马上能读到。
		Net.claim_room(BASEMENT_FLOOR, idx, Net.local_name)
		cur = Net.room_claims.get(key, {})
		if cur.is_empty():
			_notice("这块组队板刚被别人开了，稍等一下再看")
			return
	# 组队板归 team uid 管，宿舍归裸 uid 管；两边别再混着比
	var mine_board := Net.is_my_team_board(cur) if is_b1 else \
		(String(cur.get("uid", "")) == Net.local_uid)
	if not mine_board:
		_note_view_title.text = ("%s ·「%s」的队伍" % [label, String(cur.get("name", "?"))]) if is_b1 else \
			("%d 号房 ·「%s」" % [idx + 1, String(cur.get("name", "?"))])
		var note_raw := String(cur.get("note", ""))
		var parts := _note_split(note_raw)
		_note_view_link = _safe_voice_link(String(parts[0])) if is_b1 else ""
		var note := String(parts[1])
		if is_b1:
			var body := note if not note.is_empty() else "队长还没写招募内容。"
			body += "\n\n已入座 %d / 6 人 · 进去找空位坐下就算加入" % _team_seated_count(idx)
			_note_view_body.text = body
		else:
			_note_view_body.text = note if not note.is_empty() else "这间房的房主还没写公告。"
		_note_view_voice.visible = not _note_view_link.is_empty()
		_note_view_body.add_theme_color_override("font_color",
			Color("#e6effb") if not note.is_empty() else Color(0.60, 0.66, 0.74))
		_note_view.visible = true
		_center_panel.call_deferred(_note_view)
		return
	_note_room_idx = idx
	_note_title.text = ("发布 %s 组队招募" % label) if is_b1 else \
		("编写 %d 号房的门口公告" % (idx + 1))
	var mine := _note_split(String(cur.get("note", "")))
	_oopz_box.visible = is_b1
	_oopz_edit.text = _safe_voice_link(String(mine[0])) if is_b1 else ""
	_note_edit.text = String(mine[1])
	_update_note_count()
	_note_panel.visible = true
	_center_panel(_note_panel)
	_note_edit.grab_focus()
	# 手机点进来就弹软键盘，不用再点一下输入框
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_show("")


## 面板居中（内容尺寸要等一帧才稳定，所以打开时也允许 deferred 调）
func _center_panel(pc: Control) -> void:
	if pc == null or not is_instance_valid(pc):
		return
	var vs := get_viewport().get_visible_rect().size
	var sz := pc.get_combined_minimum_size()
	# 手机弹软键盘时会盖掉下半屏：面板往上让，否则正在打的输入框被键盘压住
	var area_h: float = maxf(vs.y - _vk_inset(), sz.y + 16.0)
	pc.position = Vector2((vs.x - sz.x) * 0.5, maxf(8.0, (area_h - sz.y) * 0.5))


## 软键盘挡住的高度（逻辑像素），没弹出来就是 0。
## 只有移动端有软键盘，桌面调这个 API 会刷警告 —— 先挡掉。
func _vk_inset() -> float:
	if not OS.has_feature("mobile"):
		return 0.0
	var h := DisplayServer.virtual_keyboard_get_height()
	if h <= 0:
		return 0.0
	var win_y := float(DisplayServer.window_get_size().y)
	if win_y <= 0.0:
		return 0.0
	return h * (get_viewport().get_visible_rect().size.y / win_y)


## 软键盘收起/弹出时把公告面板重新摆一次（键盘高度是异步变的）
func _process_vk_reposition() -> void:
	if _note_panel == null or not _note_panel.visible:
		return
	var vk := _vk_inset()
	if absf(vk - _vk_last) < 1.0:
		return
	_vk_last = vk
	_center_panel(_note_panel)


func _save_note_board() -> void:
	if _note_room_idx < 0:
		return
	var idx := _note_room_idx
	var body := _note_edit.text.strip_edges()
	# 语音链接存在公告首行（@oopz: 前缀）—— 服务端只认 note 一个字符串，
	# 这样加功能不用改协议，老版本客户端看到的就是一段多了一行前缀的文字。
	var link := _safe_voice_link(_oopz_edit.text) if current_floor == BASEMENT_FLOOR else ""
	var txt := body
	if not link.is_empty():
		txt = OOPZ_TAG + link + ("\n" + body if not body.is_empty() else "")
	_close_note_board()
	if current_floor == BASEMENT_FLOOR:
		# 组队板的招募走 team note 通道：不写宿舍公告、不写 my_room.cfg
		Net.set_team_note(idx, txt)
	else:
		Net.set_room_note(idx, txt)
		# 同步落本地存档：服务端只把认领/公告存在内存里，重启就没了，
		# 而旧版服务端连请求都收不到 —— 不存本地就是「退出之后公告没保存」。
		_save_my_room(current_floor, idx, txt.strip_edges().left(160))
	if current_floor == BASEMENT_FLOOR:
		if txt.strip_edges().is_empty():
			_notice("组队招募已撤下")
		elif link.is_empty():
			_notice("组队招募已发布 · B1 的同学都能看到")
		elif not _looks_oopz_invite(link):
			_notice("已发布，但这链接不像语音频道邀请（应为 oopz.cn/i/…）· 队员可能进不去")
		else:
			_notice("组队招募已发布（含语音频道）· 队员坐下按 V 唤起 OOPZ")
	else:
		_notice("门口公告已擦掉" if txt.strip_edges().is_empty() else "门口公告已更新")


func _clear_note_board() -> void:
	_note_edit.text = ""
	_oopz_edit.text = ""
	_save_note_board()


func _close_note_board() -> void:
	if _note_panel != null:
		_note_panel.visible = false
	if _note_edit != null and _note_edit.is_inside_tree():
		_note_edit.release_focus()
	if OS.has_feature("mobile"):
		DisplayServer.virtual_keyboard_hide()
	_note_room_idx = -1
	_vk_last = 0.0


func _close_note_view() -> void:
	if _note_view != null:
		_note_view.visible = false


## 两个公告面板任一个是开着的
func _note_open() -> bool:
	return (_note_panel != null and _note_panel.visible) or (_note_view != null and _note_view.visible)


func _close_note_all() -> void:
	_close_note_board()
	_close_note_view()


## B1：把 4 块组队板刷成「谁开的队 / 已入座几人」。
## 空板按 E 开队，队长的板是金色，别人的队是青色；人数来自此刻坐在房里的玩家。
func _refresh_team_plates() -> void:
	for item in _door_plates:
		if not bool(item.get("team", false)):
			continue
		var pc: PanelContainer = item["panel"]
		var lb: Label = item["label"]
		if not is_instance_valid(pc) or not is_instance_valid(lb):
			continue
		var idx: int = int(item["index"])
		var label := _team_board_name(idx)
		var cur: Dictionary = Net.room_claims.get("%d:%d" % [BASEMENT_FLOOR, idx], {})
		var sb := pc.get_theme_stylebox("panel") as StyleBoxFlat
		var seated := _team_seated_count(idx)
		# 文案压短：牌子是屏幕空间 Label（13px≈每字 13px，一块牌子只有 ~120px 宽），
		# 写长了会和隔壁板子的牌子横向叠住，字被后画的那块盖掉。
		if cur.is_empty():
			lb.text = "%s · 空队" % label
			lb.add_theme_color_override("font_color", Color(0.74, 0.80, 0.88, 0.85))
			pc.modulate = Color(0.72, 0.74, 0.78, 0.90)
			if sb != null:
				sb.border_color = Color(0.55, 0.62, 0.72, 0.85)
		elif Net.is_my_team_board(cur):
			lb.text = "%s · 我的队 %d/6" % [label, seated]
			lb.add_theme_color_override("font_color", Color("#ffe9a8"))
			pc.modulate = Color(1, 1, 1, 1)
			if sb != null:
				sb.border_color = Color(0.95, 0.78, 0.38, 0.95)
		else:
			# 名字最多 5 字，超长的 ID 会把牌子撑爆
			var who := String(cur.get("name", "?"))
			if who.length() > 5:
				who = who.left(4) + "…"
			lb.text = "%s · %s %d/6" % [label, who, seated]
			lb.add_theme_color_override("font_color", Color("#9ff0d0"))
			pc.modulate = Color(1, 1, 1, 1)
			if sb != null:
				sb.border_color = Color(0.42, 0.90, 0.72, 0.95)


## 按 current_floor 重算每块牌子的文字。认领是「楼层:房号」为键的，换层自然切换。
## 被认领的牌子亮边暖字，还带房主写的公告一行；空房是淡灰的小号牌。
func _refresh_door_plates() -> void:
	if current_floor == BASEMENT_FLOOR:
		_refresh_team_plates()
		return
	_remember_my_home()
	for item in _door_plates:
		var pc: PanelContainer = item["panel"]
		var lb: Label = item["label"]
		if not is_instance_valid(pc) or not is_instance_valid(lb):
			continue
		var idx: int = int(item["index"])
		var gate := _room_gate(idx)
		var sb := pc.get_theme_stylebox("panel") as StyleBoxFlat
		match String(gate["state"]):
			"empty":
				lb.text = "%d号 · 空房" % (idx + 1)
				lb.add_theme_color_override("font_color", Color(0.74, 0.80, 0.88, 0.80))
				pc.modulate = Color(0.72, 0.74, 0.78, 0.85)
				if sb != null:
					sb.border_color = Color(0.55, 0.62, 0.72, 0.85)
			"mine":
				lb.text = "%d号 ·「%s」的房间 · 我的" % [idx + 1, String(gate["name"])]
				lb.add_theme_color_override("font_color", Color("#ffe9a8"))
				pc.modulate = Color(1, 1, 1, 1)
				if sb != null:
					sb.border_color = Color(0.95, 0.78, 0.38, 0.95)
			"friend":
				# 好友的房：青绿色，一眼和「锁着的陌生人」分开
				lb.text = "%d号 ·「%s」的房间 · 好友" % [idx + 1, String(gate["name"])]
				lb.add_theme_color_override("font_color", Color("#9ff0d0"))
				pc.modulate = Color(1, 1, 1, 1)
				if sb != null:
					sb.border_color = Color(0.42, 0.90, 0.72, 0.95)
			_:
				# 别人的房：压暗 + 挂个锁字，别再让人以为能随便推门
				lb.text = "%d号 ·「%s」的房间 · 锁" % [idx + 1, String(gate["name"])]
				lb.add_theme_color_override("font_color", Color(0.78, 0.72, 0.66, 0.90))
				pc.modulate = Color(0.82, 0.78, 0.76, 0.92)
				if sb != null:
					sb.border_color = Color(0.62, 0.52, 0.42, 0.90)
	# 门锁状态跟着认领一起变（刚认领的房要立刻能进）
	_update_room_doors()


## 每帧把牌子摆到门口：用 canvas_transform 把房门口的世界坐标换成屏幕坐标，
## 跟门提示条是同一套换算，所以牌子会牢牢钉在门上（相机怎么走都不飘）。
func _place_door_plates() -> void:
	if _door_plates_holder == null or not is_instance_valid(_door_plates_holder):
		return
	var show: bool = in_room and room != null and is_instance_valid(room)
	if not show:
		for item in _door_plates:
			var pc2: PanelContainer = item["panel"]
			if is_instance_valid(pc2):
				pc2.visible = false
		return
	var ct := get_viewport().get_canvas_transform()
	var vs := get_viewport().get_visible_rect().size
	var view := Rect2(Vector2(-140.0, -80.0), vs + Vector2(280.0, 160.0))
	for item in _door_plates:
		var pc: PanelContainer = item["panel"]
		if not is_instance_valid(pc):
			continue
		# 组队板自带 ax/ay 锚点；宿舍门牌仍按 side 把牌子挂到门洞下方/上方。
		var ax: float = float(item.get("ax", -1.0))
		var ay: float = float(item.get("ay", -1.0))
		if ax < 0.0:
			var side: String = String(item["side"])
			ax = float(item["x"]) + float(item["w"]) * 0.5
			ay = float(item["y"]) + (float(item["h"]) + PLATE_OFF if side == "n" else -PLATE_OFF)
		var world: Vector2 = room.to_global(Vector2(ax * TS, ay * TS))
		var sp: Vector2 = ct * world
		var sz: Vector2 = pc.get_combined_minimum_size()
		pc.position = sp - Vector2(sz.x * 0.5, sz.y * 0.5)
		pc.visible = view.has_point(sp)


func _notice(text: String) -> void:
	_ensure_floor_ui()
	_notice_label.text = text
	_notice_clock = 2.4
	_notice_label.visible = true
	var vs := get_viewport().get_visible_rect().size
	var sz := _notice_label.get_combined_minimum_size()
	_notice_label.position = Vector2((vs.x - sz.x) * 0.5, vs.y - sz.y - 64.0)


func _update_notice(delta: float) -> void:
	if _notice_clock <= 0.0:
		return
	_notice_clock -= delta
	if _notice_clock <= 0.0:
		_notice_label.visible = false


## F 认领身边的人还在门前的房间（再按一次撕下自己的公告）。
## 服务端快照里有自己的名字 → 记到本地存档（下次上线据此直接回宿舍）。
## 只在「快照里有我」时才写，避免服务端的认领还没同步过来就把存档清了。
func _remember_my_home() -> void:
	var claim: String = Net.my_claim()
	if claim.is_empty():
		return
	var parts := claim.split(":")
	if parts.size() < 2:
		return
	_save_my_room_keep_note(int(parts[0]), int(parts[1]))


## 写存档但保留已有的公告正文（同一间房才保留，换房就该是空白的）
func _save_my_room_keep_note(floor_n: int, idx: int) -> void:
	var saved := _load_my_room()
	var note := _load_my_room_note() if saved == Vector2i(floor_n, idx) else ""
	_save_my_room(floor_n, idx, note)


func _try_claim_room() -> bool:
	# B1 的板子是「开队」不是「认领宿舍」，F 键不该走宿舍认领 / 存档这条链
	if not in_room or _floor_open or current_floor == BASEMENT_FLOOR:
		return false
	var me: Node = _local_avatar()
	if me == null:
		return false
	var d := _nearest_room_door((me as Node2D).position)
	if d.is_empty():
		return false
	var idx: int = int(d["index"])
	var key := "%d:%d" % [current_floor, idx]
	var cur: Dictionary = Net.room_claims.get(key, {})
	var no: int = idx + 1
	if cur.is_empty():
		Net.claim_room(current_floor, idx, Net.local_name)
		# 别急着宣布成功：以 room_claims 的实际结果为准。否则服务端一旦不认
		# （旧版服务端 / 请求被丢掉），就成了「提示说贴上了、牌子上还是空房」。
		var now: Dictionary = Net.room_claims.get(key, {})
		if Net.local_uid.is_empty() or String(now.get("uid", "")) != Net.local_uid:
			_notice("没能认领 %d 层 %d 号房（服务器没接受请求，可能是服务端版本较旧）" % [current_floor, no])
			return false
		_save_my_room_keep_note(current_floor, idx)   # 记下来：下次上线直接从这间房的床上出生
		_notice("已在 %d 层 %d 号房门口贴上公告：这是「%s」的房间" % [current_floor, no, Net.local_name])
		return true
	if String(cur.get("uid", "")) == Net.local_uid and Net.local_uid != "":
		Net.claim_room(current_floor, idx, "")      # 空名字 = 撕下来
		if Net.room_claims.has(key):
			_notice("没能撕下 %d 层 %d 号房的公告（服务器没接受请求）" % [current_floor, no])
			return false
		_clear_my_room()
		_notice("已撕下 %d 层 %d 号房的公告，下次上线从校园出生" % [current_floor, no])
		return true
	_notice("%d 层 %d 号房已经是「%s」的了" % [current_floor, no, String(cur.get("name", "?"))])
	return false


## 不同楼层的人互相看不见：只有 1 份几何，"你在 3 层、他在 1 层"就是靠这里区分的。
## 出了楼所有人恢复可见。
func _update_floor_visibility() -> void:
	if players == null or not is_instance_valid(players):
		return
	for c in players.get_children():
		if c == null or not is_instance_valid(c):
			continue
		if bool(c.get("is_local_player")):
			c.visible = true
			continue
		# 房间里 / 校园里是两个互不相干的坐标空间（房间在校园北界外 1500 格，
		# 同一份几何复制 5 层）。所以要按「在不在房间里」先分一次，
		# 再按楼层分 —— 只看楼层号的话，校园里的人楼层也是 1，
		# 会和你房间里的人混在一起。
		var peer_in_room: bool = bool(c.get("room_inside"))
		if peer_in_room != in_room:
			c.visible = false
			continue
		if not in_room:
			c.visible = true
			continue
		c.visible = int(c.get("room_floor")) == current_floor
