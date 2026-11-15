extends Node2D
## 雨点落水的涟漪层：挂在 WaterFX 下、积水 sprite 之后 —— 这样涟漪画在
## 积水上面，不会被积水层盖掉。数据（ripples）由 WaterFX 每帧推进，
## 这里只负责画，不推进、不挑落点。

var ripples: Array = []       # WaterFX 的 _ripples（同一份引用）


func _draw() -> void:
	for rp in ripples:
		var t: float = float(rp["t"])
		var k := t / 0.62
		var rad: float = float(rp["r"]) * (0.22 + 0.78 * (1.0 - (1.0 - k) * (1.0 - k)))
		var c := Vector2(float(rp["x"]), float(rp["y"]))
		var a: float = float(rp["a"]) * (1.0 - k) * (1.0 - k)
		_ring(c, rad, a, Color(0.88, 0.95, 1.0))
		if k > 0.13:
			_ring(c, rad * 0.56, a * 0.55, Color(0.88, 0.95, 1.0))
		if k < 0.22:
			draw_rect(Rect2(roundf(c.x), roundf(c.y), 2.0, 1.0),
				Color(0.94, 0.98, 1.0, 0.55 * (1.0 - k / 0.22)))


## 一圈压扁的椭圆水纹（俯视水面，竖向压到 0.62 才像摊开的水波）
func _ring(c: Vector2, rad: float, a: float, col: Color) -> void:
	if a <= 0.02 or rad < 0.8:
		return
	var pts := PackedVector2Array()
	var n := 14
	for i in n:
		var ang := TAU * float(i) / float(n)
		pts.append(c + Vector2(cos(ang) * rad, sin(ang) * rad * 0.62))
	pts.append(pts[0])
	draw_polyline(pts, Color(col.r, col.g, col.b, a), 1.0, false)
