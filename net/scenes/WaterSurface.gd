extends Node2D
## 运行时补画「桥下新增水道」的蓝面。
##
## world.json 的 water 数组里虽然已加上这 4 条通道水（供 船掩码 / 波光 / 桥下免碰撞用），
## 但烘焙地面 PNG 里并没有它们（地面还是陆地）。这里在 Ground 层（Objects 之下）实时
## 补一层水色，颜色与烘焙水面主色 rgb(88,168,200) 一致，让小船从桥下划过时有连续水面。
## 已有水面的波光由 WaterFX 负责（它读 world.json 的 water 数组，通道水会自动有波光）。

const CELL := 8.0
const WATER    := Color(0.345, 0.659, 0.784)   # 烘焙水面主色 (88,168,200)
const WATER_DK := Color(0.282, 0.596, 0.722)   # 岸线/暗部 (72,152,184)
const WATER_LT := Color(0.408, 0.690, 0.816)   # 受光高光 (104,176,208)

var _rects: Array = []


## 自己读 world.json，不依赖生成器写进来的数据 —— Array/Rect2 这类成员存不进
## world.tscn（和 Bridge.deck_w 同一个坑），场景一加载就空，蓝面全丢。
func _ready() -> void:
	if _rects.is_empty():
		_load_from_world()


func _load_from_world() -> void:
	var f := FileAccess.open("res://assets/world.json", FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	setup((parsed as Dictionary).get("bridges", []))


func setup(bridges: Array) -> void:
	_rects.clear()
	for b in bridges:
		var cx := float(b.get("cx", 0.0))
		var cy := float(b.get("cy", 0.0))
		var cw := float(b.get("cw", 0.0))
		var ch := float(b.get("ch", 0.0))
		_rects.append(Rect2(cx * CELL, cy * CELL, cw * CELL, ch * CELL))
	queue_redraw()


func _draw() -> void:
	for r in _rects:
		draw_rect(r, WATER)
		# 上缘略暗（岸线/水深感），下缘略亮（受光）
		draw_rect(Rect2(r.position.x, r.position.y, r.size.x, 2.0), WATER_DK)
		draw_rect(Rect2(r.position.x, r.position.y + r.size.y - 2.0, r.size.x, 2.0), WATER_LT)
