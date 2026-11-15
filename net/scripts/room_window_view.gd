extends Node2D
## 北墙窗洞里透出来的那条「窗外」。
##
## 房间背后那层天（room_sky.gd）是给整间房铺的：它的地平线在房间上沿往下
## 60px（BAND_OVER），也就是北墙立面那一带正好落在近景山林的「脚」上 ——
## 从窗洞里看出去会是一片糊掉的深绿。所以窗洞单独用这条带子：
## 把天空包压成一条二十来像素高的横带，天在上、四层山景压在下面，
## 窗里就有天、有远山、有一道地平面。
##
## 它画在**地板下面、墙后面**（z=-150），玻璃本身什么都不画，
## 所以窗是**真透明**的：透出来就是这条带子 —— 走远走近、白天黑夜都是真背景，
## 不是贴在墙上的一张风景照。天色跟 RoomSky 共用同一张图和同一套插值，
## 窗里窗外不会出现两个天色。

const RoomProp := preload("res://net/scripts/room_prop.gd")

## 天空包里每段贴图的尺寸（一行一个时段）
const BAND_TEX := Vector2(640.0, 176.0)
const RIDGE_TEX := Vector2(640.0, 320.0)

## 四层山景（远→近）。只取每层「有山的那一截」源图（山体上沿以下），再压进
## 下面这么高 —— 整张 320px 一起压的话，山只占图的下半截，压完就只剩一两个
## 像素，窗里还是会空一片。
##   crop  源图里山体上沿的偏移（每层的轮廓起点不同）
##   hdr   压进带子里的高度
##   fog   被雨雾吃掉的程度（跟 room_sky 一样：远山先没影）
const RIDGES := [
	{"key": "far", "crop": 140.0, "hdr": 9.0, "fog": 0.88},
	{"key": "mid", "crop": 186.0, "hdr": 7.5, "fog": 0.62},
	{"key": "woods", "crop": 228.0, "hdr": 6.0, "fog": 0.30},
	{"key": "fore", "crop": 255.0, "hdr": 5.0, "fog": 0.10},
]

## 这条带子覆盖的局部矩形（房间左上角为原点）
var area := Rect2()
var _last_t := -1.0


## top/bottom：带子在房间局部坐标里的上下沿（像素）。
## 北墙的窗洞在 y≈3..16 那一带，带子上下各多留几像素，山脚才不会露边。
func setup(room_w: float, top: float, bottom: float) -> void:
	area = Rect2(0.0, top, room_w, bottom - top)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_last_t = DayNight.t if DayNight != null else 0.5
	queue_redraw()


## 只有天色变档才重画：一条纯渐变的带子，没必要每帧算。
func _process(_delta: float) -> void:
	var t: float = DayNight.t if DayNight != null else 0.5
	if absf(t - _last_t) < 0.002:
		return
	_last_t = t
	queue_redraw()


func _draw() -> void:
	if area.size.x <= 0.0 or area.size.y <= 0.0:
		return
	var pair := RoomProp.sky_pair(_last_t)
	var row_a := int(pair[0])
	var row_b := int(pair[1])
	var mix := float(pair[2])

	# 1) 天：整段天光压进带子（天顶深、地平线发白），横向铺满
	var band := RoomProp.sky_bg_tex()
	if band == null:
		draw_rect(area, Color("6fa8d0"))
	else:
		draw_texture_rect_region(band, area,
			Rect2(0.0, float(row_a) * BAND_TEX.y, BAND_TEX.x, BAND_TEX.y), Color.WHITE)
		if mix > 0.02:
			draw_texture_rect_region(band, area,
				Rect2(0.0, float(row_b) * BAND_TEX.y, BAND_TEX.x, BAND_TEX.y),
				Color(1.0, 1.0, 1.0, mix))

	# 2) 山：由远及近，山脚压在同一条地平线上（窗台那条线往上 1px）
	var wcloud: float = clampf(Weather.cloud(), 0.0, 1.0)
	var base_y := area.position.y + area.size.y - 5.0
	for rd in RIDGES:
		var key := String(rd["key"])
		var tex := RoomProp.sky_ridge_tex(key)
		if tex == null:
			continue
		var hdr := float(rd["hdr"])
		var crop := float(rd["crop"])
		var src_h := RIDGE_TEX.y - crop
		var a := 1.0 - wcloud * float(rd["fog"])
		if a <= 0.03:
			continue
		var x := area.position.x
		while x < area.end.x - 0.5:
			var ww := minf(RIDGE_TEX.x, area.end.x - x)
			draw_texture_rect_region(tex,
				Rect2(x, base_y - hdr, ww, hdr),
				Rect2(0.0, float(row_a) * RIDGE_TEX.y + crop, ww, src_h),
				Color(1.0, 1.0, 1.0, a))
			if mix > 0.02:
				draw_texture_rect_region(tex,
					Rect2(x, base_y - hdr, ww, hdr),
					Rect2(0.0, float(row_b) * RIDGE_TEX.y + crop, ww, src_h),
					Color(1.0, 1.0, 1.0, a * mix))
			x += RIDGE_TEX.x
