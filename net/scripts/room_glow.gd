extends Node2D
## 房间的发光层：屏幕冷光 / 贩卖机紫光 / 白板反光。
##
## 用径向渐变贴图 + additive 混合。一开始是拿几圈同心圆叠出来的，
## 大面积上环状分层非常明显（一圈一圈的台阶），所以换成真正的渐变。
##
## 贴图只有一张（128×128 径向渐变），每个光斑是一个 Sprite2D 缩放过去，
## 颜色由 modulate 决定；父节点的 additive 材质通过 use_parent_material 继承。

const TEX_SIZE := 128
const TEX_HALF := 64.0

var _tex: Texture2D


func setup(spots: Array) -> void:
	for c in get_children():
		c.queue_free()
	if _tex == null:
		_tex = _make_tex()
	for item in spots:
		var s: Dictionary = item
		var spr := Sprite2D.new()
		spr.texture = _tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		spr.position = s.get("pos", Vector2.ZERO)
		var r: float = s.get("r", 40.0)
		spr.scale = Vector2.ONE * (r / TEX_HALF)
		spr.modulate = s.get("color", Color(1, 1, 1, 0.2))
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		spr.material = m
		add_child(spr)


## 径向渐变：中心不透明白 → 边缘全透明，alpha 走二次衰减（比线性更柔）。
## 用 GradientTexture2D 生成出来是空图（试过，画不出东西），所以直接铺像素。
## 注意用 create_from_data 而不是逐点 set_pixel —— 后者在 4.x 上写多通道会丢通道。
func _make_tex() -> Texture2D:
	var n := TEX_SIZE
	var data := PackedByteArray()
	data.resize(n * n * 4)
	var c := float(n - 1) * 0.5
	for y in range(n):
		for x in range(n):
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a
			var i := (y * n + x) * 4
			data[i] = 255
			data[i + 1] = 255
			data[i + 2] = 255
			data[i + 3] = int(a * 255.0)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, data)
	return ImageTexture.create_from_image(img)
