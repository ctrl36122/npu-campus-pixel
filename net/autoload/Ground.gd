extends Node
## 地面材质查询（autoload 名 Ground）。
##
## tools/bake_ground_kind.py 烘出两张等价的东西：
##   assets/ground_kind.png  1 格 1 像素（424x800），R 通道存材质编号（给人看的源图）
##   assets/ground_kind.bin  同样的网格、每格 1 字节的纯数据（运行时真正读的）
##
## ⚠️ 为什么运行时读 .bin 而不是 .png：导出 Windows 包时 `texture_format/s3tc_bptc=true`
## 会把所有纹理转成 S3TC **有损**压缩。编辑器里 `get_image()` 拿得到原始 R 值，所以正常；
## 但导出的 exe 里 R 值被压缩破坏、`get_image()` 甚至直接失败 —— 结果全部判成 other，
## Sfx 回退成 grass，听起来就是「只有一种脚步声」。纯数据文件不走纹理管线，彻底避开。
##
## 坐标：玩家 position 是**校园层局部坐标**（campus 缩放前），1 格 = 8 像素，
## 和地面贴图一一对应，所以 tile = position / 8，不需要再换算。
##
## 材质：grass 草地 / stone 石板广场 / asphalt 沥青路面 / water 水面 / other 认不出

const BIN_PATH := "res://assets/ground_kind.bin"
const PNG_PATH := "res://assets/ground_kind.png"   # 仅在 .bin 缺失时兜底（编辑器里可用）
const CELL := 8.0
const KINDS := ["grass", "stone", "asphalt", "water", "other"]

var _data: PackedByteArray
var _w := 0
var _h := 0
var _ok := false
var _src := "none"


func _ready() -> void:
	if not _load_bin():
		_load_png()          # 兜底：源图还在时至少编辑器中能用
	if not _ok:
		push_warning("[ground] 材质图缺失，判定全部按 other（脚步声会退化成一种）")
	elif OS.has_environment("XGD_GROUND_DEBUG"):
		_write_probe()


## 读预烘焙的字节数据：magic "GKD1" + u16 宽 + u16 高 + 宽*高 个材质索引
func _load_bin() -> bool:
	if not FileAccess.file_exists(BIN_PATH):
		return false
	var f := FileAccess.open(BIN_PATH, FileAccess.READ)
	if f == null:
		return false
	var head := f.get_buffer(8)
	if head.size() != 8 or head.slice(0, 4).get_string_from_ascii() != "GKD1":
		return false
	var w := head.decode_u16(4)
	var h := head.decode_u16(6)
	if w <= 0 or h <= 0:
		return false
	var body := f.get_buffer(w * h)
	if body.size() != w * h:
		return false
	_w = w
	_h = h
	_data = body
	_ok = true
	_src = "bin"
	return true


## 兜底：从纹理取图（编辑器中可用；导出的 exe 里可能因 S3TC 失效）
func _load_png() -> void:
	var tex: Texture2D = load(PNG_PATH)
	if tex == null:
		return
	var img: Image = tex.get_image()
	if img == null or img.is_empty():
		return
	_w = img.get_width()
	_h = img.get_height()
	var buf := PackedByteArray()
	buf.resize(_w * _h)
	for y in _h:
		for x in _w:
			buf[y * _w + x] = int(round(img.get_pixel(x, y).r * 255.0))
	_data = buf
	_ok = true
	_src = "png"


## 导出环境自查：把加载结果落盘，便于在 exe 里确认（XGD_GROUND_DEBUG=1 时写一次）
func _write_probe() -> void:
	var c := [0, 0, 0, 0, 0]
	var step := maxi(1, (_w * _h) / 20000)
	var i := 0
	while i < _data.size():
		var k := int(_data[i])
		if k >= 0 and k < c.size():
			c[k] += 1
		i += step
	var f := FileAccess.open("user://ground_probe.txt", FileAccess.WRITE)
	if f != null:
		f.store_line("src=%s ok=%s w=%d h=%d" % [_src, str(_ok), _w, _h])
		f.store_line("kinds 0..4 = %s" % str(c))
		f.close()


func available() -> bool:
	return _ok


func source() -> String:
	return _src


## 世界像素（校园局部坐标）-> 材质名
func kind_at(pos: Vector2) -> String:
	if not _ok:
		return "other"
	return kind_at_tile(int(floor(pos.x / CELL)), int(floor(pos.y / CELL)))


func kind_at_tile(tx: int, ty: int) -> String:
	if not _ok:
		return "other"
	if tx < 0 or ty < 0 or tx >= _w or ty >= _h:
		return "other"
	return KINDS[clampi(int(_data[ty * _w + tx]), 0, KINDS.size() - 1)]
