extends RefCounted
## 校园地图几何的唯一数据源：从 assets/world.json 读取建筑轮廓 / 树木 / 水系 / POI。
##
## 用 `const MapData := preload("res://scripts/ui/map_data.gd")` 引用，
## 不依赖全局 class_name 注册（新脚本在 headless 下可能还没进全局类缓存）。
##
## 以前小地图和全屏图的楼名各自从场景 Sprite 推算「贴图顶部中心」——
## 那是 2.5D 挤出的屋顶，比地面 footprint 高出一截，且每栋楼高度不同，
## 于是名字整体偏北、各偏各的；这就是「文字错位」的根因。
## 现在底图和楼名都用 world.json 的**轮廓质心**，天然对齐。

const WORLD_JSON := "res://assets/world.json"
const CELLS := Vector2(424.0, 800.0)      # 世界格数
const TS := 8.0                            # 每格校园局部像素
const GROUND_COLS := 4
const GROUND_ROWS := 7

# 底图配色：偏沉稳的插画感，接近一张正式的校园导览图
const C_GROUND := Color("3a6135")
const C_COLLEGE := Color("4d73a6")
const C_TEACH := Color("6193c9")
const C_DORM := Color("5d9b69")
const C_DINING := Color("c4713c")
const C_SPORT := Color("419c94")
const C_LIB := Color("e2bd5e")
const C_MISC := Color("74818f")
const C_SCULPT := Color("b3bdc9")
const C_TREE_A := Color("2b5130")
const C_TREE_B := Color("325a37")
const C_OUTLINE := Color("1b2430")

static var _doc: Dictionary = {}
static var _loaded: bool = false


static func doc() -> Dictionary:
	if not _loaded:
		_loaded = true
		var raw := FileAccess.get_file_as_string(WORLD_JSON)
		if not raw.is_empty():
			var parsed = JSON.parse_string(raw)
			if parsed is Dictionary:
				_doc = parsed
	return _doc


## 建筑列表（按体量从大到小）。每项：
##   name / cat / poly(格坐标 Vector2 数组) / cen(质心·格) / pos(质心·校园局部像素) / w_cells
static func buildings() -> Array:
	var d := doc()
	var out: Array = []
	for b in d.get("buildings", []):
		var nm := str(b.get("name", ""))
		var named: bool = not nm.is_empty() and nm != "无名建筑"
		var box: Dictionary = b.get("box", {})
		var poly: Array = []
		for p in b.get("poly", []):
			if p is Array and p.size() >= 2:
				poly.append(Vector2(float(p[0]), float(p[1])))
		var cat := str(b.get("cat", "b"))
		var cen := _centroid(poly, box)
		var w_cells: float = maxf(1.0, float(box.get("maxx", cen.x)) - float(box.get("minx", cen.x)))
		var h_cells: float = maxf(1.0, float(box.get("maxy", cen.y)) - float(box.get("miny", cen.y)))
		out.append({
			"name": nm,
			"named": named,
			"cat": cat,
			"poly": poly,
			"cen": cen,
			"pos": cen * TS,
			"w_cells": w_cells,
			"h_cells": h_cells,
			"area_cells": w_cells * h_cells,
		})
	out.sort_custom(func(a, b): return float(a["area_cells"]) > float(b["area_cells"]))
	return out


## 小地图用的短名：去掉「西北工业大学」前缀与「学生」二字，超长专名单独缩写。
## 200px 的小地图上 12 个字会横跨半个屏幕，短名才像正式地图的标注。
static func short_name(nm: String) -> String:
	var s := nm.replace("西北工业大学", "")
	s = s.replace("学生宿舍", "")
	s = s.replace("学生食堂", "食堂")
	s = s.replace("海天苑大楼·", "海天苑")
	match s:
		"力学与交通运载工程学院": return "力学交通学院"
		"军工素质教育实践中心": return "军工实践中心"
		"星天苑综合服务大楼": return "星天苑服务楼"
		"亚洲最大水上图书馆": return "水上图书馆"
		"工程实践训练中心": return "工程训练中心"
		"动力与能源学院": return "动力能源学院"
	return s


static func trees() -> Array:
	var out: Array = []
	for i in doc().get("instances", []):
		if str(i.get("k", "")) == "tree":
			out.append(i)
	return out


static func water() -> Array:
	return doc().get("water", [])


static func pois() -> Array:
	return doc().get("poi", [])


static func roof_color(cat: String) -> Color:
	match cat:
		"lib": return C_LIB
		"dining": return C_DINING
		"sport": return C_SPORT
		"dorm": return C_DORM
		"teach": return C_TEACH
		"college": return C_COLLEGE
		"sculpture": return C_SCULPT
		_: return C_MISC


## 楼名锚点（格坐标）：优先用面积质心；若质心落在多边形外（U 形 / 回字形宿舍、
## 中庭式教学楼，质心会落进天井），改用「最宽水平跨度的中点」——保证锚点在楼体上。
static func _centroid(poly: Array, box: Dictionary) -> Vector2:
	if poly.size() >= 3:
		var c := _area_centroid(poly)
		if _point_in_poly(c, poly):
			return c
		var rp := _widest_row_point(poly)
		if rp.size() > 0:
			return rp[0]
	return Vector2(
		(float(box.get("minx", 0.0)) + float(box.get("maxx", 0.0))) * 0.5,
		(float(box.get("miny", 0.0)) + float(box.get("maxy", 0.0))) * 0.5)


static func _area_centroid(poly: Array) -> Vector2:
	var a := 0.0
	var cx := 0.0
	var cy := 0.0
	var n := poly.size()
	for i in n:
		var p0: Vector2 = poly[i]
		var p1: Vector2 = poly[(i + 1) % n]
		var cross := p0.x * p1.y - p1.x * p0.y
		a += cross
		cx += (p0.x + p1.x) * cross
		cy += (p0.y + p1.y) * cross
	a *= 0.5
	if absf(a) > 0.0001:
		return Vector2(cx / (6.0 * a), cy / (6.0 * a))
	var s := Vector2.ZERO
	for p in poly:
		s += p
	return s / float(maxi(1, n))


## 在多边形内部找一条最宽的水平跨度，返回它的中点（一定在楼体内）。
static func _widest_row_point(poly: Array) -> Array:
	var miny := INF
	var maxy := -INF
	for p in poly:
		miny = minf(miny, p.y)
		maxy = maxf(maxy, p.y)
	if maxy - miny < 0.001:
		return []
	var n := poly.size()
	var best_w := -1.0
	var best := Vector2.ZERO
	var found := false
	for k in range(1, 20):
		var sy: float = miny + (maxy - miny) * float(k) / 20.0
		var xs: Array[float] = []
		for i in n:
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % n]
			if (a.y <= sy and b.y > sy) or (b.y <= sy and a.y > sy):
				var t := (sy - a.y) / (b.y - a.y)
				xs.append(a.x + (b.x - a.x) * t)
		if xs.size() < 2:
			continue
		xs.sort()
		var j := 0
		while j + 1 < xs.size():
			var w := xs[j + 1] - xs[j]
			if w > best_w:
				best_w = w
				best = Vector2((xs[j] + xs[j + 1]) * 0.5, sy)
				found = true
			j += 2
	return [best] if found else []


static func _point_in_poly(pt: Vector2, poly: Array) -> bool:
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
