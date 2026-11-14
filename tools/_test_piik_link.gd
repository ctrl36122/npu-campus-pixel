extends SceneTree
## Piik 屏幕共享联动的纯逻辑回归：公告标签拆分、白名单、老客户端兼容、160 字上限。
## 跑法：godot --headless --path . --script res://tools/_test_piik_link.gd
## 只调用 Arena 里不依赖场景树的字符串函数，不连服务器、不弹浏览器。

## Arena.gd 顶层引用了 Net 这个 autoload，--script 模式下脚本会比 autoload 先编译，
## 所以不在文件顶层 preload，等第一帧（autoload 已注册）再 load。
var _ok := 0
var _fail := 0


func _check(cond: bool, label: String) -> void:
	if cond:
		_ok += 1
		print("  PASS  ", label)
	else:
		_fail += 1
		printerr("  FAIL  ", label)


func _init() -> void:
	call_deferred("_run_tests")


func _run_tests() -> void:
	var arena_script = load("res://net/scenes/Arena.gd")
	if arena_script == null:
		printerr("  FAIL  加载 Arena.gd 失败")
		quit(1)
		return
	var a = arena_script.new()
	var old_note := "@oopz:https://oopz.cn/i/demo01\n来打排位"
	_check(String(a._note_split(old_note)[0]) == "https://oopz.cn/i/demo01", "旧格式：语音链接照常读出")
	_check(String(a._note_split(old_note)[1]) == "来打排位", "旧格式：正文不变")

	var new_note := "@oopz:https://oopz.cn/i/demo01\n@piik:4821\n来打排位，看我屏幕"
	_check(String(a._note_split(new_note)[0]) == "https://oopz.cn/i/demo01", "新格式：语音链接仍在")
	_check(String(a._note_split(new_note)[1]) == "来打排位，看我屏幕", "新格式：两个标记行都不进正文")
	_check(a._note_piik(new_note) == "4821", "取回 4 位房间号")
	_check(a._note_piik(new_note).length() == 4, "房间号只有 4 位")

	_check(a._safe_share_target("4821") == "4821", "白名单：4 位房间号")
	_check(a._safe_share_target("https://demo.piik.tv/r/abc?k=xyz") == "https://demo.piik.tv/r/abc?k=xyz",
		"白名单：完整 https 邀请")
	_check(a._safe_share_target("https://xxxx-yyyy.trycloudflare.com/i/1234") != "",
		"白名单：App 公网邀请临时域名也放行")
	_check(a._safe_share_target("") == "", "白名单：空串")
	_check(a._safe_share_target("javascript:alert(1)") == "", "白名单：拒绝 javascript:")
	_check(a._safe_share_target("file:///C:/evil.exe") == "", "白名单：拒绝 file://")
	_check(a._safe_share_target("piik://room/1") == "", "白名单：拒绝未登记的 scheme")
	_check(a._safe_share_target("https://a b.com") == "", "白名单：拒绝含空格")
	_check(a._safe_share_target("x".repeat(200)) == "", "白名单：拒绝超长")
	_check(a._safe_share_target("12") == "", "白名单：房间号至少 3 位")

	_check(a._note_piik("@PIIK:https://demo.piik.tv/x") == "https://demo.piik.tv/x",
		"标签大小写不敏感")
	_check(a._note_piik("随便写的公告\n没有标记") == "", "没有标记时返回空")
	_check(a._safe_share_target(a._note_piik("@piik:javascript:alert(1)")) == "",
		"标签里塞伪协议也过不了白名单")

	# 模拟老版客户端：它的 _note_split 只认 @oopz:，会把 @piik: 行当正文，
	# 但重新保存时那一行还留在 note 里 —— 新版客户端必须仍能读回链接。
	var legacy_link := ""
	var legacy_body := PackedStringArray()
	for ln in new_note.split("\n", true):
		var t: String = ln.strip_edges()
		if legacy_link.is_empty() and t.to_lower().begins_with("@oopz:"):
			legacy_link = t.substr(6).strip_edges()
			continue
		legacy_body.append(ln)
	var rebuilt := "@oopz:" + legacy_link + "\n" + "\n".join(legacy_body).strip_edges()
	_check(a._note_piik(rebuilt) == "4821", "老客户端重存后 @piik: 仍可解析")
	_check("\n".join(legacy_body).contains("@piik:4821"),
		"老客户端会把 @piik: 当正文显示（已知兼容表现）")

	# 公告整串上限 160 字（Net._clean_note 的 left(160)，客户端/服务端都截）
	var short_note := "@oopz:https://oopz.cn/i/demo01\n@piik:4821\n来打排位，看我屏幕"
	_check(short_note.length() <= 160, "语音 + 房间号 + 短正文在 160 字内")
	_check(short_note.left(160) == short_note, "不会被 _clean_note 截掉尾巴")

	a.free()
	print("Piik 联动自检：%d 通过 / %d 失败" % [_ok, _fail])
	quit(1 if _fail > 0 else 0)
