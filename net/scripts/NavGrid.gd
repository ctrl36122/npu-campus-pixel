class_name NavGrid
extends RefCounted
## 校园可走网格 + A* 寻路（Godot 内置 AStarGrid2D，零外链依赖）。
## 障碍 = 建筑 footprint + 建筑阴影区 + 水面（桥面甲板挖空，可走）。
## 坐标系：格（cell）。对外接口用「校园局部像素」，内部换算。

var _grid: AStarGrid2D
var _W := 0
var _H := 0
var _TS := 8.0


func build(world: Dictionary, ts: float) -> void:
	_TS = ts
	_W = int(world["map"]["W"])
	_H = int(world["map"]["H"])
	_grid = AStarGrid2D.new()
	_grid.region = Rect2(0, 0, _W, _H)
	_grid.cell_size = Vector2(1, 1)
	_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE
	_grid.update()

	var solid := PackedByteArray()
	solid.resize(_W * _H)
	solid.fill(0)

	# 水面 → 障碍
	for r in world.get("water", []):
		_fill_rect(solid, int(r["x"]), int(r["y"]), int(r["w"]), int(r["h"]))
	# 桥面甲板 → 挖空（可走，让 NPC 能过桥）
	for br in world.get("bridges", []):
		_clear_rect(solid, int(br["x"]), int(br["y"]), int(br["w"]), int(br["h"]))
	# 建筑 footprint + 阴影区 → 障碍
	for b in world.get("buildings", []):
		_fill_poly(solid, b.get("poly", []), float(b.get("hp", 20)))

	for y in range(_H):
		for x in range(_W):
			if solid[y * _W + x] == 1:
				_grid.set_point_solid(Vector2i(x, y), true)


# ---------------------------------------------------------------- 障碍填充

func _fill_rect(s: PackedByteArray, x0: int, y0: int, w: int, h: int) -> void:
	for y in range(maxi(0, y0), mini(_H, y0 + h)):
		for x in range(maxi(0, x0), mini(_W, x0 + w)):
			s[y * _W + x] = 1


func _clear_rect(s: PackedByteArray, x0: int, y0: int, w: int, h: int) -> void:
	for y in range(maxi(0, y0), mini(_H, y0 + h)):
		for x in range(maxi(0, x0), mini(_W, x0 + w)):
			s[y * _W + x] = 0


func _fill_poly(s: PackedByteArray, poly: Array, hp: float) -> void:
	if poly.size() < 3:
		return
	var pts := PackedVector2Array()
	var minx := 1e9
	var miny := 1e9
	var maxx := -1e9
	var maxy := -1e9
	for p in poly:
		var v := Vector2(float(p[0]), float(p[1]))
		pts.append(v)
		minx = minf(minx, v.x); maxx = maxf(maxx, v.x)
		miny = minf(miny, v.y); maxy = maxf(maxy, v.y)
	for y in range(maxi(0, int(miny)), mini(_H, int(maxy) + 1)):
		for x in range(maxi(0, int(minx)), mini(_W, int(maxx) + 1)):
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), pts):
				s[y * _W + x] = 1
	# 阴影区：footprint 北侧（y 更小）向上 hp 格，整片不可走
	var sy0 := maxi(0, int(miny - hp))
	for y in range(sy0, mini(_H, int(miny) + 1)):
		for x in range(maxi(0, int(minx)), mini(_W, int(maxx) + 1)):
			s[y * _W + x] = 1


# ---------------------------------------------------------------- 对外接口（像素）

func _to_cell(px: Vector2) -> Vector2i:
	return Vector2i(int(floor(px.x / _TS)), int(floor(px.y / _TS)))


func _nearest_walkable(c: Vector2i) -> Vector2i:
	for ring in range(1, 24):
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				var x := c.x + dx
				var y := c.y + dy
				if x < 0 or y < 0 or x >= _W or y >= _H:
					continue
				if not _grid.is_point_solid(Vector2i(x, y)):
					return Vector2i(x, y)
	return c


## 像素起点 → 像素终点，返回一串像素路点（含起点与终点）。无解返回空数组。
func find_path(from_px: Vector2, to_px: Vector2) -> Array:
	var a := _to_cell(from_px)
	var b := _to_cell(to_px)
	if _grid.is_point_solid(a):
		a = _nearest_walkable(a)
	if _grid.is_point_solid(b):
		b = _nearest_walkable(b)
	if a == b:
		return []
	var ids := _grid.get_id_path(a, b)
	if ids.is_empty():
		return []
	var out: Array = []
	for idv in ids:
		out.append(Vector2(idv.x + 0.5, idv.y + 0.5) * _TS)
	return out


## 在 center 周围 radius 格内随机挑一个可走格，返回其像素中心（退化时返回 center）。
func random_walkable_near(center_px: Vector2, radius_cells: int) -> Vector2:
	var c := _to_cell(center_px)
	for i in 40:
		var ang := randf() * TAU
		var rad := randf() * float(radius_cells)
		var cx := int(c.x + cos(ang) * rad)
		var cy := int(c.y + sin(ang) * rad)
		if cx < 0 or cy < 0 or cx >= _W or cy >= _H:
			continue
		if not _grid.is_point_solid(Vector2i(cx, cy)):
			return Vector2(cx + 0.5, cy + 0.5) * _TS
	return center_px
