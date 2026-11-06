extends SceneTree
## 聊天守卫回归：分级处置 / 等长打码 / 白名单 / 变形绕过 / 刷屏 / 兼容接口。
## 纯静态，不进场景、不联网、不碰 user:// 存档。
##
##   APPDATA=<临时目录> XGD_OFFLINE=1 godot --headless --script res://tools/_test_chat_guard.gd

const ChatGuard := preload("res://net/chat_guard.gd")

var checks := 0
var fails: Array[String] = []
var done := false


func _ok(cond: bool, label: String, extra := "") -> void:
	checks += 1
	if cond:
		print("  OK   ", label, (" " + extra) if not extra.is_empty() else "")
	else:
		print("  FAIL ", label, (" " + extra) if not extra.is_empty() else "")
		fails.append(label)


func _process(_d: float) -> bool:
	if done:
		return true
	done = true
	_run()
	if fails.is_empty():
		print("结果 PASS：聊天守卫 %d 项全过" % checks)
		quit(0)
	else:
		print("结果 FAIL：%s" % ", ".join(fails))
		quit(1)
	return true


func _scan(text: String) -> Dictionary:
	return ChatGuard.scan_full(text)


func _run() -> void:
	print("[1] 兼容老接口（Net.gd / chat.gd 一直在调）")
	_ok(ChatGuard.MIN_INTERVAL_MS == 1200, "MIN_INTERVAL_MS 保持 1200")
	_ok(ChatGuard.REPEAT_LIMIT == 3, "REPEAT_LIMIT 保持 3")
	_ok(ChatGuard.filter("你傻逼啊") == "你**啊", "filter 仍然把违规词换成等长 *",
		ChatGuard.filter("你傻逼啊"))
	_ok(ChatGuard.has_blocked("你傻逼啊"), "has_blocked 认得出中文语境里的辱骂")
	_ok(not ChatGuard.has_blocked("明天操场见"), "has_blocked 不误伤正常句子")
	_ok(ChatGuard.too_fast(1000, 2199), "too_fast：间隔 1199ms 算太快")
	_ok(not ChatGuard.too_fast(1000, 2200), "too_fast：间隔 1200ms 放行")
	_ok(not ChatGuard.too_fast(0, 1000), "too_fast：首次发言放行")
	var twice := ChatGuard.filter(ChatGuard.filter("傻逼 加微信"))
	_ok(twice == ChatGuard.filter("傻逼 加微信"), "filter 幂等（客户端/服务端过滤两次结果一致）")

	print("[2] 等长打码铁律")
	for s in ["你傻逼啊", "加微信找我", "别赌博了", "ＦＵＣＫ", "傻 逼", "fuck off"]:
		_ok(ChatGuard.filter(s).length() == s.length(),
			"长度不变：%s" % s, "%d→%d" % [s.length(), ChatGuard.filter(s).length()])
	var long_one := "a".repeat(200)
	var long_scan := _scan(long_one)
	_ok(String(long_scan["filtered_text"]).length() == ChatGuard.MAX_TEXT_LENGTH,
		"超长截断到 MAX_TEXT_LENGTH", str(String(long_scan["filtered_text"]).length()))
	_ok(int(long_scan["action"]) == ChatGuard.Action.WARN, "超长只给警告不拦截")

	print("[3] 词库与白名单")
	var all_multi := true
	for level in ChatGuard.WORD_LIBRARY:
		var cats: Dictionary = ChatGuard.WORD_LIBRARY[level]
		for cat in cats:
			var words: Array = cats[cat]
			for w in words:
				if String(w).length() < 2:
					all_multi = false
	_ok(all_multi, "词库不收单字（杜绝操场/操作误伤）")
	_ok(_scan("去操场打球")["passed"], "白名单词本身放行")
	_ok(ChatGuard.filter("去操场打球") == "去操场打球", "白名单词不被打码")
	_ok(int(_scan("操场 赌博")["action"]) == ChatGuard.Action.BLOCK,
		"白名单不整条豁免：混进 Lv3 仍被拦（不给自己开后门）")

	print("[4] 分级处置")
	var severe := _scan("一起赌博吧")
	_ok(int(severe["action"]) == ChatGuard.Action.BLOCK, "Lv3 严重违规 → BLOCK")
	_ok(int(severe["level"]) == ChatGuard.Level.SEVERE, "Lv3 等级正确")
	var moderate := _scan("你这个傻逼")
	_ok(int(moderate["action"]) == ChatGuard.Action.MASK, "Lv2 辱骂 → MASK")
	_ok(int(moderate["level"]) == ChatGuard.Level.MODERATE, "Lv2 等级正确")
	_ok(String(moderate["filtered_text"]) == "你这个**", "Lv2 打码结果正确",
		String(moderate["filtered_text"]))
	var mild := _scan("代练吗")
	_ok(int(mild["action"]) == ChatGuard.Action.MASK, "Lv1 引流 → MASK")
	_ok(int(mild["level"]) == ChatGuard.Level.MILD, "Lv1 等级正确")
	_ok(not String(mild["reason"]).is_empty(), "处置原因会回给发送者")
	_ok((moderate["hit_words"] as Array).size() > 0, "hit_words 有内容")
	_ok((moderate["hit_categories"] as Array).size() > 0, "hit_categories 有内容")

	print("[5] 中文无词边界 / 变形绕过 / 全角")
	_ok(int(_scan("你傻逼啊")["level"]) == ChatGuard.Level.MODERATE,
		"中文词后跟汉字也能命中（边界匹配会漏）")
	_ok(int(_scan("傻 逼")["level"]) == ChatGuard.Level.MODERATE, "中间插空格能检测出来")
	_ok(ChatGuard.filter("傻 逼") == "***", "变形命中也能等长打码", ChatGuard.filter("傻 逼"))
	_ok(int(_scan("ＦＵＣＫ")["level"]) == ChatGuard.Level.MILD, "全角英文能检测出来")
	_ok(ChatGuard.filter("ＦＵＣＫ") == "****", "全角命中也能等长打码",
		ChatGuard.filter("ＦＵＣＫ"))
	_ok(bool(_scan("fucky")["passed"]), "英文按边界匹配：fucky 不误伤")
	_ok(int(_scan("shit happens")["level"]) == ChatGuard.Level.MILD,
		"英文词后跟空格能命中")

	print("[6] 刷屏：间隔 / 窗口 / 复读")
	_ok(bool(ChatGuard.check_spam(10000, [9000], "hi", [])["spam"]), "间隔过短拦下")
	_ok(not bool(ChatGuard.check_spam(10000, [5000], "hi", [])["spam"]), "间隔够就放行")
	_ok(not bool(ChatGuard.check_spam(10000, [], "hi", [])["spam"]), "首次发言放行")
	var window: Array = []
	for i in range(25):
		window.append(10000 + i * 2000)
	var later := 10000 + 25 * 2000
	_ok(bool(ChatGuard.check_spam(later, window, "hi", [])["spam"]),
		"60s 窗口内 25 条拦下")
	_ok(bool(ChatGuard.check_spam(999999, [1000], "同一句",
		["同一句", "同一句", "同一句"])["spam"]), "连续重复拦下")
	_ok(not bool(ChatGuard.check_spam(999999, [1000], "同一句",
		["同一句", "别的"])["spam"]), "只重复两次放行")
	_ok(not String(ChatGuard.check_spam(10000, [9000], "hi", [])["reason"]).is_empty(),
		"刷屏原因会回给发送者")
