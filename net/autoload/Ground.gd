extends Node
## 地面材质查询（autoload 名 Ground）。
##
## assets/ground_kind.png 是 tools/bake_ground_kind.py 烘出来的分类图：
## 1 格 1 像素（424x800），R 通道存材质编号。运行时当 Image 读，
## 每次采样就是一次 get_pixel，比按像素去查 28 张地面分块（80MB）便宜得多。
##
## 坐标：玩家 position 是**校园层局部坐标**（campus 缩放前），1 格 = 8 像素，
## 和地面贴图一一对应，所以 tile = position / 8，不需要再换算。
##
## 材质：grass 草地 / stone 石板广场 / asphalt 沥青路面 / water 水面 / other 认不出

const PATH := "res://assets/ground_kind.png"
const CELL := 8.0
const KINDS := ["grass", "stone", "asphalt", "water", "other"]

var _img: Image
var _ok := false


func _ready() -> void:
	var tex: Texture2D = load(PATH)
	if tex != null:
		_img = tex.get_image()
	_ok = _img != null and not _img.is_empty()
	if not _ok:
		push_warning("[ground] 缺 %s，材质判定全部按 other 处理（脚步声退化成一种）" % PATH)


func available() -> bool:
	return _ok


## 世界像素（校园局部坐标）-> 材质名
func kind_at(pos: Vector2) -> String:
	if not _ok:
		return "other"
	return kind_at_tile(int(floor(pos.x / CELL)), int(floor(pos.y / CELL)))


func kind_at_tile(tx: int, ty: int) -> String:
	if not _ok:
		return "other"
	if tx < 0 or ty < 0 or tx >= _img.get_width() or ty >= _img.get_height():
		return "other"
	var c := _img.get_pixel(tx, ty)
	var idx := int(round(c.r * 255.0))
	return KINDS[clampi(idx, 0, KINDS.size() - 1)]
