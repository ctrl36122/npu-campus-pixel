extends Node2D
## 水面动效：在烘焙好的静态水面贴图上叠加「波光粼粼」。
## 波光点按固定种子撒在大块水域内，各自按相位正弦闪烁、横向缓慢漂移。
## 全程序生成，零素材；挂在 campus 下、Objects 之前（水上、人物楼底下）。

const CELL := 8.0            # world.json 的格边长（校园局部像素）
const MIN_AREA := 4.0        # 细河条也给波光（≥4 格）
const MAX_SPARKS := 380      # 波光点总量上限

var _sparkles: Array = []    # {x, y, phase, speed, len}
var _t: float = 0.0
var _rng := RandomNumberGenerator.new()
## 晴天色：按 water_mask 铺满整张地面的加法层，晴天让湖水更蓝更清。
## 阴雨天强度归零 —— 那时候水本来就该浑一点，加蓝反而假。
var _sun_tint: Sprite2D
var _sun_mat: ShaderMaterial
var _sun_now: float = -1.0
## 雨天积水：puddle_mask 烘出来的水洼形状，shader 用屏幕纹理做倒影涟漪。
## 雨大水洼才显形（strength 跟雨强走），停雨慢慢收。
var _puddle: Sprite2D
var _puddle_mat: ShaderMaterial
var _puddle_now: float = -1.0
## 雨点落进湖里/水洼里的涟漪：雨强越大，荡开的圈越多。
## 湖面只在可视水域内随机落点（整张地图 4096×7168，撒全图等于看不见）；
## 水洼里按造波纹理挑「深水区」的格子，跟 shader 的裁形完全同源。
var _ripples: Array = []       # {x, y, t, r, a}
var _ripple_acc := 0.0
var _areas: Array = []         # 水域矩形（世界像素），落点用
var _ripple_layer: Node2D      # 涟漪画在这层（积水之上）
## 造波纹理的 Image 数据：给水洼涟漪挑落点用，和 shader 同一张图同数值
const PUDDLE_TH := 0.60        # 与 puddle.gdshader 的 TH / INSET 保持一致
const PUDDLE_INSET := 0.055
var _wave_img: Image = null
var _mask_img: Image = null


## water: world.json 里的 water 数组（格坐标 {x,y,w,h}）
func setup(water: Array) -> void:
	_build_sun_tint()
	_build_puddle()
	_build_ripple_layer()
	_rng.seed = 20261028
	for r in water:
		var rw := float(r.get("w", 0))
		var rh := float(r.get("h", 0))
		if rw * rh < MIN_AREA:
			continue
		# 落涟漪用的世界矩形（和水波点同一套换算）
		_areas.append(Rect2(float(r.get("x", 0)) * CELL, float(r.get("y", 0)) * CELL,
			rw * CELL, rh * CELL))
		if _sparkles.size() >= MAX_SPARKS:
			continue
		var n := clampi(int(rw * rh / 70.0), 1, 4)
		for i in n:
			_sparkles.append({
				"x": (float(r.get("x", 0)) + _rng.randf_range(0.12, 0.88) * rw) * CELL,
				"y": (float(r.get("y", 0)) + _rng.randf_range(0.12, 0.88) * rh) * CELL,
				"phase": _rng.randf_range(0.0, TAU),
				"speed": _rng.randf_range(1.1, 2.3),
				"len": _rng.randf_range(2.0, 5.0),
			})


## 水体染色的底图：water_mask.png 一格一像素，放大 8 倍正好盖住整张地面
func _build_sun_tint() -> void:
	if _sun_tint != null:
		return
	var tex: Texture2D = null
	if ResourceLoader.exists("res://assets/water_mask.png"):
		tex = load("res://assets/water_mask.png") as Texture2D
	if tex == null:
		return
	var sh := load("res://net/shaders/water_sun.gdshader") as Shader
	if sh == null:
		return
	_sun_mat = ShaderMaterial.new()
	_sun_mat.shader = sh
	_sun_mat.set_shader_parameter("strength", 0.0)
	_sun_tint = Sprite2D.new()
	_sun_tint.name = "SunTint"
	_sun_tint.texture = tex
	_sun_tint.centered = false
	_sun_tint.scale = Vector2(CELL, CELL)
	_sun_tint.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sun_tint.material = _sun_mat
	add_child(_sun_tint)


## 积水层：puddle_mask.png 一格一像素放大 8 倍，与 sun_tint 同一套对齐方式
func _build_puddle() -> void:
	if _puddle != null:
		return
	var tex: Texture2D = null
	if ResourceLoader.exists("res://assets/puddle_mask.png"):
		tex = load("res://assets/puddle_mask.png") as Texture2D
	if tex == null:
		return
	var sh := load("res://net/shaders/puddle.gdshader") as Shader
	if sh == null:
		return
	_puddle_mat = ShaderMaterial.new()
	_puddle_mat.shader = sh
	_puddle_mat.set_shader_parameter("strength", 0.0)
	_puddle = Sprite2D.new()
	_puddle.name = "Puddles"
	_puddle.texture = tex
	_puddle.centered = false
	_puddle.scale = Vector2(CELL, CELL)
	_puddle.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_puddle.material = _puddle_mat
	add_child(_puddle)
	# 造波纹理：shader 拿它裁形；GDScript 读 Image 给涟漪挑落点，两边同源
	var wt: Texture2D = null
	if ResourceLoader.exists("res://assets/wave_noise.png"):
		wt = load("res://assets/wave_noise.png") as Texture2D
	if wt != null:
		_puddle_mat.set_shader_parameter("wave_tex", wt)
		_wave_img = wt.get_image()
		if _wave_img != null and _wave_img.is_compressed():
			_wave_img.decompress()
	if _puddle.texture != null:
		_mask_img = _puddle.texture.get_image()
		if _mask_img != null and _mask_img.is_compressed():
			_mask_img.decompress()


## 涟漪层：排在积水 sprite 之后，画出来的圈不会被积水盖掉
func _build_ripple_layer() -> void:
	if _ripple_layer != null:
		return
	var sc := load("res://net/scripts/water_ripples.gd") as GDScript
	if sc == null:
		return
	_ripple_layer = Node2D.new()
	_ripple_layer.name = "Ripples"
	_ripple_layer.set_script(sc)
	_ripple_layer.set("ripples", _ripples)
	add_child(_ripple_layer)


## 积水强度跟雨强走：雨强 0.7 以上水洼全显，停雨后随过渡收干。
func _sync_puddle() -> void:
	if _puddle_mat == null:
		return
	var k := clampf(Weather.rain_strength() * 1.3, 0.0, 1.0)
	if absf(k - _puddle_now) < 0.01:
		return
	_puddle_now = k
	_puddle_mat.set_shader_parameter("strength", k)


## 晴天的染色强度：晴 ~0.9，阴 ~0.12，雨雪 0。
## 只在变化超过 0.01 时才写 shader 参数，避免每帧推一个常量。
func _sync_sun() -> void:
	if _sun_mat == null:
		return
	var k := 0.0
	match Weather.kind:
		Weather.Kind.CLEAR:
			k = 0.74
		Weather.Kind.CLOUDY:
			k = 0.12
		_:
			k = 0.0
	# 天气过渡期间按 cloud 再收一道，晴天权重低的时候水也不该突然变蓝
	k *= clampf(1.0 - Weather.cloud() * 0.85, 0.0, 1.0) * 1.35
	k = clampf(k, 0.0, 1.0)
	if absf(k - _sun_now) < 0.01:
		return
	_sun_now = k
	_sun_mat.set_shader_parameter("strength", k)


func _process(delta: float) -> void:
	_t += delta
	_sync_sun()
	_sync_puddle()
	_tick_ripples(delta)
	queue_redraw()
	if _ripple_layer != null and is_instance_valid(_ripple_layer):
		_ripple_layer.queue_redraw()


## 雨点落进湖里：每秒按雨强撒一批涟漪，落点只在可视水域内随机。
## 之前是「人物踩水」，改成雨打湖面 —— 人走着不该自带水纹，
## 而雨落进水里的圈才是每场雨都该有的。
func _tick_ripples(delta: float) -> void:
	var rain := Weather.rain_strength()
	if rain < 0.05 or _areas.is_empty():
		_ripples.clear()
		_ripple_acc = 0.0
		return
	_ripple_acc += delta * (7.0 + 58.0 * rain)
	while _ripple_acc >= 1.0:
		_ripple_acc -= 1.0
		if _ripples.size() < 160:
			_spawn_ripple()
	for i in range(_ripples.size() - 1, -1, -1):
		var rp: Dictionary = _ripples[i]
		rp["t"] = float(rp["t"]) + delta
		if float(rp["t"]) >= 0.62:
			_ripples.remove_at(i)


## 挑一个落点：四成概率落水洼（按造波值选「深水区」，和 shader 同源），
## 其余落湖面（按可视交集面积加权，大湖里落得多）
func _spawn_ripple() -> void:
	var vis := _view_world()
	if _wave_img != null and _mask_img != null and _rng.randf() < 0.42:
		var p := _puddle_point(vis)
		if p != Vector2.INF:
			_ripples.append({
				"x": p.x, "y": p.y, "t": 0.0,
				"r": _rng.randf_range(4.5, 8.5),
				"a": 0.62,
			})
			return
	# 湖面：按交集面积加权
	var total := 0.0
	var cands: Array = []
	for a in _areas:
		var r: Rect2 = (a as Rect2).intersection(vis).grow(-8.0)  # 往岸内收一圈
		if r.size.x > 2.0 and r.size.y > 2.0:
			cands.append(r)
			total += r.size.x * r.size.y
	if total <= 0.0:
		return
	var pick := _rng.randf() * total
	var hit: Rect2 = cands[cands.size() - 1]
	for r in cands:
		var rr: Rect2 = r
		pick -= rr.size.x * rr.size.y
		if pick <= 0.0:
			hit = rr
			break
	_ripples.append({
		"x": hit.position.x + _rng.randf() * hit.size.x,
		"y": hit.position.y + _rng.randf() * hit.size.y,
		"t": 0.0,
		"r": _rng.randf_range(5.5, 11.5),
		"a": 0.5,
	})


## 在可视范围内挑一个水洼落点：随机点 → 查硬面掩码 + 造波值，
## 只要「深水区」（内切之后那层），涟漪就不会压在薄水边上
func _puddle_point(vis: Rect2) -> Vector2:
	for i in 24:
		var px := vis.position.x + _rng.randf() * vis.size.x
		var py := vis.position.y + _rng.randf() * vis.size.y
		var cx := int(px / CELL)
		var cy := int(py / CELL)
		if cx < 0 or cy < 0 or cx >= _mask_img.get_width() or cy >= _mask_img.get_height():
			continue
		if _mask_img.get_pixel(cx, cy).r < 0.5:
			continue
		if _wave_img.get_pixel(cx, cy).r < PUDDLE_TH + PUDDLE_INSET + 0.02:
			continue
		return Vector2(px, py)
	return Vector2.INF


## 当前镜头看到的矩形，换算到本节点的局部坐标。
## 不能直接用 get_canvas_transform()：那给的是画布空间，campus 自己有偏移，
## 不换算的话可视矩形整体平移几百像素，落点全落到水域外面（表现是「没有涟漪」）。
func _view_world() -> Rect2:
	var xf := get_global_transform().affine_inverse() * get_canvas_transform().affine_inverse()
	return xf * get_viewport_rect()


func _draw() -> void:
	# 涟漪在子节点 Ripples 层画（积水之上）；这里只剩水面的波光点
	for s in _sparkles:
		var a := 0.5 + 0.5 * sin(_t * float(s["speed"]) + float(s["phase"]))
		a *= a                                   # 大部分时间比较淡，偶尔亮一下
		if a < 0.05:
			continue
		var dx := sin(_t * 0.55 + float(s["phase"])) * 1.6
		var col := Color(1.0, 1.0, 1.0, 0.18 + 0.42 * a)
		var ln: float = float(s["len"]) * 1.6
		draw_rect(Rect2(float(s["x"]) + dx, float(s["y"]), ln, 1.2), col)
		# 波光下方拖一条更淡的短尾，让涟漪感更强
		draw_rect(Rect2(float(s["x"]) + dx - 2.0, float(s["y"]), ln * 0.5, 1.0),
			Color(1.0, 1.0, 1.0, 0.06 + 0.14 * a))
