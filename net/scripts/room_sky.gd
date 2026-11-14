extends Node2D
## 房间背后的那整幅天（会动）。
##
## 以前房间是「一块亮着的地板漂在纯黑虚空里」：走到边上看出去就是黑色，
## 北墙的落地窗就算放大到十几格高，窗外那片天也只是一条亮边。
## 这一层把 pixel-sky 的天空铺在整间房后面，房间就变成漂在云上摊开的平面图 ——
## 和 SkyOffice 那种观感是一个路数。
##
## 北墙的玻璃幕墙和回字中庭中间那块都是**真透明**的（窗只画框、中庭抠掉地板
## 的 alpha），所以它们透出来的就是这一层。
##
## 分三层叠，只有云在动：
##   room_sky_bg.png      上沿一带的渐变 + 日月 + 星空（钉死）
##   room_sky_fill.png    往下那段渐变 + 夜里的星（钉死；中庭的大洞透的是它）
##   room_sky_clouds.png  云层（横向无缝），自己往西飘，镜头移动时还带一点视差
## 天色跟着 DayNight 走，用 RoomProp.sky_pair() 在两档之间交叉淡入 ——
## 一个天色、几处开口，不会有两套天。

const RoomProp := preload("res://net/scripts/room_prop.gd")

## 贴图尺寸（像素）。
## 上沿只取源图最上面 176 行 —— 再往下天空就发白发灰了，落地窗会显得褪色。
const BAND_TEX := Vector2(640.0, 176.0)
const FILL_TEX := Vector2(640.0, 512.0)
const CLOUD_TEX := Vector2(640.0, 512.0)
## 游戏里画多大：上沿和纵深放大一倍（2 个局部像素一块），云保持 1:1。
## 云放大一倍会大到一扇落地窗只装得下半朵，「半朵云」就是这么来的。
const BAND_DRAW := Vector2(1280.0, 352.0)
const FILL_DRAW := Vector2(1280.0, 1024.0)
const CLOUD_DRAW := Vector2(640.0, 512.0)

## 云往西飘的速度（局部像素/秒）。8px 一格，约 1 格/秒 ——
## 一朵云飘过整间阅览厅要两三分钟，是「看得见在动」而不是赶路。
const CLOUD_SPEED := 7.0
## 云层跟随镜头的比例。云比房间远：镜头挪 1 像素，云只挪这么多 ——
## 走动时能看出层次，站着不动它照样自己飘。
const CLOUD_PARALLAX := 0.12
## 带子底边压到房间上沿（局部 y=0）以下这么深：接缝藏在地板底下，
## 窗顶和天空之间就不会露出一条硬边。
## 这个值同时决定「落地窗对着天空的哪一段」—— 压得越深，窗里看到的天越高、
## 越蓝；压得浅，窗玻璃就落在贴近地平线的那段发白的天光里。
const BAND_OVER := 60.0
## 贴图缺了时兜底的天空色（顺序同 SKY_TIMES：dawn / noon / sunset / night）
const FALLBACK: Array[Color] = [
	Color("b67281"), Color("82bee2"), Color("c15d6a"), Color("172449"),
]

## 要覆盖的局部矩形（房间左上角为原点，所以 y 是负的）
var area := Rect2()
var _drift := 0.0
var _last_t := -1.0


## room_size：房间尺寸（局部像素，8px/格）；pad：左右各外扩多少
func setup(room_size: Vector2, pad: float) -> void:
	area = Rect2(-pad, BAND_OVER - BAND_DRAW.y, room_size.x + pad * 2.0,
		room_size.y + BAND_DRAW.y - BAND_OVER)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	queue_redraw()


## 云一直在飘，所以这一层每帧重画；画的东西就几个贴图矩形，比逐个家具便宜得多。
## 天色那两档只在时刻走够 0.0015（约 2 分钟）时重算一次，省下每帧的插值。
func _process(delta: float) -> void:
	_drift = fposmod(_drift + CLOUD_SPEED * delta, CLOUD_DRAW.x)
	var t: float = DayNight.t
	if absf(t - _last_t) > 0.0015:
		_last_t = t
	queue_redraw()


func _draw() -> void:
	if area.size.x <= 0.0 or area.size.y <= 0.0:
		return
	var pair := RoomProp.sky_pair(0.5 if _last_t < 0.0 else _last_t)
	var row_a := int(pair[0])
	var row_b := int(pair[1])
	var mix := float(pair[2])

	var band_rect := Rect2(area.position, Vector2(area.size.x, BAND_DRAW.y))
	var fill_rect := Rect2(area.position.x, area.position.y + BAND_DRAW.y, area.size.x,
		maxf(0.0, area.end.y - area.position.y - BAND_DRAW.y))

	var bg_tex := RoomProp.sky_bg_tex()
	var fill_tex := RoomProp.sky_fill_tex()
	var cloud_tex := RoomProp.sky_clouds_tex()

	# 1) 底：下半截渐变（中庭那种大洞透的就是它）+ 上沿那条带
	var c := FALLBACK[row_a].lerp(FALLBACK[row_b], mix)
	if fill_tex == null:
		_paint_flat(fill_rect, c)          # 缺图退回一条冷色渐变，至少不是黑块
	else:
		_tile(fill_tex, fill_rect, row_a, FILL_TEX, FILL_DRAW, 1.0, 0.0)
		if mix > 0.02:
			_tile(fill_tex, fill_rect, row_b, FILL_TEX, FILL_DRAW, mix, 0.0)
	if bg_tex == null:
		_paint_flat(band_rect, c)
	else:
		_tile(bg_tex, band_rect, row_a, BAND_TEX, BAND_DRAW, 1.0, 0.0)
		if mix > 0.02:
			_tile(bg_tex, band_rect, row_b, BAND_TEX, BAND_DRAW, mix, 0.0)

	if cloud_tex == null:
		return
	# 2) 云：整块云场盖满整个区域（上下两块接得上），横向自己飘 + 跟镜头错位。
	#    云场的竖向接缝是镜像做的，滚动时不会露出来。
	var shift := -_drift - _cam_local_x() * CLOUD_PARALLAX
	_tile(cloud_tex, area, row_a, CLOUD_TEX, CLOUD_DRAW, 1.0, shift)
	if mix > 0.02:
		_tile(cloud_tex, area, row_b, CLOUD_TEX, CLOUD_DRAW, mix, shift)


## 镜头在房间局部空间里的 x。云拿它算视差：镜头往右，云往左让一点，
## 房间和云就分成前后两层。房间里没相机（或跑在别处）时当 0。
func _cam_local_x() -> float:
	var vp := get_viewport()
	if vp == null:
		return 0.0
	var cam := vp.get_camera_2d()
	if cam == null:
		return 0.0
	return to_local(cam.get_screen_center_position()).x


## 把贴图某一行在 rect 里平铺。
## tex_cell：贴图上单块多少像素；draw_cell：单块在游戏里占多大。
func _tile(tex: Texture2D, rect: Rect2, row: int, tex_cell: Vector2,
		draw_cell: Vector2, alpha: float, offset_x: float) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var src_row := float(row) * tex_cell.y
	var x0 := rect.position.x + fposmod(offset_x, draw_cell.x) - draw_cell.x
	var y := rect.position.y
	while y < rect.end.y - 0.5:
		var h := minf(draw_cell.y, rect.end.y - y)
		var x := x0
		while x < rect.end.x - 0.5:
			# 左/上边界那一块可能被裁掉一截，源矩形按裁掉多少平移，
			# 不能直接拉伸 —— 拉伸会把云压扁。
			var cut_l := maxf(0.0, rect.position.x - x)
			var cut_t := maxf(0.0, rect.position.y - y)
			var w := minf(draw_cell.x - cut_l, rect.end.x - maxf(x, rect.position.x))
			if w > 0.5 and h - cut_t > 0.5:
				var kx := tex_cell.x / draw_cell.x
				var ky := tex_cell.y / draw_cell.y
				draw_texture_rect_region(
					tex,
					Rect2(maxf(x, rect.position.x), maxf(y, rect.position.y), w, h - cut_t),
					Rect2(cut_l * kx, src_row + cut_t * ky, w * kx, (h - cut_t) * ky),
					Color(1.0, 1.0, 1.0, alpha))
			x += draw_cell.x
		y += draw_cell.y


## 兜底：纯色块 + 一条很轻的竖向渐变，往下越浅
func _paint_flat(rect: Rect2, c: Color) -> void:
	if rect.size.y <= 0.0:
		return
	var steps := 12
	var lo := c.lightened(0.12)
	for i in range(steps):
		var t0 := float(i) / float(steps)
		var t1 := float(i + 1) / float(steps)
		var ya := lerpf(rect.position.y, rect.end.y, t0)
		var yb := lerpf(rect.position.y, rect.end.y, t1)
		draw_rect(Rect2(rect.position.x, ya, rect.size.x, yb - ya), c.lerp(lo, t0))
