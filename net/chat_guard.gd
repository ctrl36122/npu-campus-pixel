extends RefCounted
## 聊天内容守卫：分级词库 + 等长打码 + 变形绕过检测 + 刷屏节流。
##
## 定位是「提供处置能力」，不是做一套完备的内容审查 —— 词库永远不全，
## 真正兜底靠管理员命令（见 Net.gd 的 /mute、/unmute、/muted）。
##
## 两条硬性约束（Net.gd 客户端本地过滤 + 服务端兜底过滤都依赖它们）：
##   1. 词表**绝不能收单字**（比如「操」）——「操场」「操作」会被误伤，
##      校园地图里这两个词到处都是，一旦误伤就是满屏星号。
##   2. 只做等长打码（把命中字符换成 *，一个字符换一颗星），不改句子长度，
##      这样客户端本地和服务端过滤两次的结果一致，不会出现「我看到的和别人看到的不一样」。
##
## 兼容接口（老代码一直在用，签名不能动）：filter / has_blocked / too_fast /
## MIN_INTERVAL_MS / REPEAT_LIMIT。新增 scan_full / check_spam 给处置链用。
##
## 相比参考实现改了两处会漏判的地方：
##   - 中文词组没有词边界：「你傻逼啊」里「傻逼」后面跟汉字，按英文那套边界
##     匹配会被判成「不是独立词」而放过。中文词直接子串匹配，英文/数字词才用边界。
##   - 打码基于归一化文本定位：全角「ＦＵＣＫ」和插了空格的「傻 逼」都能被
##     检测到，但用 findn 在原文里找连续词是找不到的，会出现「判违规却没打码」。
##     现在先算命中字符区间，再按相同下标把原文对应字符换成 *，长度严格不变。

# ============================================== 配置开关与阈值
## 匹配模式：false=英文/数字词按边界匹配（推荐，低误伤）/ true=全部子串匹配
const SUBSTRING_MODE := false
## 是否检测变形绕过（中间插空格、符号、下划线等）
const DETECT_OBFUSCATION := true
## 绕过检测允许的最大干扰字符数（词中间插入的非文字字符数）
const MAX_OBFUSCATE_GAP := 2

## 同一个人两条消息的最小间隔（毫秒）
const MIN_INTERVAL_MS := 1200
## 刷屏统计窗口（毫秒）
const RATE_WINDOW_MS := 60000
## 一个窗口内最多发多少条
const MAX_MSG_PER_WINDOW := 25
## 同一句话重复几次就拦
const REPEAT_LIMIT := 3
## 单条消息最大字符数。与 Net.post_message 的 left(160)、chat.gd 输入框
## max_length=160 对齐 —— 这是既有聊天协议上限，改成 300 会把 /petsset 的
## JSON 截成半截，也可能让旧服务端和新客户端对同一条消息长度判断不一致。
const MAX_TEXT_LENGTH := 160

## 违规等级：0 正常 / 1 轻度 / 2 中度 / 3 严重
enum Level { NORMAL = 0, MILD = 1, MODERATE = 2, SEVERE = 3 }
## 处置：0 放行 / 1 警告 / 2 打码 / 3 整条拦截
enum Action { PASS = 0, WARN = 1, MASK = 2, BLOCK = 3 }

# ============================================== 分级词库
## 用整数字面量当 key（枚举值放进 const 字典在部分 4.x 版本会编译失败）。
## Lv3 整条不转发；Lv2 整词打码后发送；Lv1 打码 + 给发送者警告。
const WORD_LIBRARY := {
	3: {
		"illegal": ["赌博", "博彩", "网赌", "毒品", "冰毒", "枪支", "裸聊", "援交"],
	},
	2: {
		"insult": ["傻逼", "沙比", "煞笔", "脑残", "智障", "草泥马", "你妈的",
			"他妈的", "干你娘", "狗日的", "去死吧", "尼玛的"],
		"sexual": ["约炮", "色情", "骚货", "婊子"],
	},
	1: {
		"spam": ["加微信", "加qq", "代练", "刷单", "兼职日结", "卖号", "收号", "低价出"],
		"en": ["fuck", "shit", "bitch"],
	},
}

## 白名单：只保护这些词覆盖的字符区间，**不再整条豁免**。
## 参考实现是「命中白名单就整条放行」，那样一句「操场 + 赌博」能把 Lv3
## 严重违规一起带过去，等于给绕过开后门。这里只在打码时跳过被白名单盖住的位置。
const WHITELIST := ["操场", "操作", "操心", "草莓"]

## 词条缓存：{word, level, cat}，按词长降序，长词优先命中
static var _entries: Array = []
static var _initialized := false


# ============================================== 对外兼容接口

## 违规内容替换成等长的 *。大小写不敏感、全角/变形命中也能打上。
static func filter(text: String) -> String:
	return String(scan_full(text)["filtered_text"])


## 是否含违规词（用来给发送者一句提示，至于打码交给 filter）
static func has_blocked(text: String) -> bool:
	return int(scan_full(text)["level"]) > Level.NORMAL


## 是否发得太快。last_ms 为 0 表示第一次发言。
static func too_fast(last_ms: int, now_ms: int) -> bool:
	if last_ms <= 0:
		return false
	return now_ms - last_ms < MIN_INTERVAL_MS


# ============================================== 对外高级接口

## 全量扫描，返回结构化结果：
## { passed, action, level, hit_words, hit_categories, filtered_text, reason }
static func scan_full(text: String) -> Dictionary:
	_init_if_needed()
	var result := {
		"passed": true,
		"action": Action.PASS,
		"level": Level.NORMAL,
		"hit_words": [],
		"hit_categories": [],
		"filtered_text": text,
		"reason": "",
	}

	# 0. 超长文本截断（长度变了，但输入输出仍然一一对应，客户端服务端一致）
	if text.length() > MAX_TEXT_LENGTH:
		result["filtered_text"] = text.substr(0, MAX_TEXT_LENGTH)
		result["passed"] = false
		result["action"] = Action.WARN
		result["reason"] = "消息超出长度限制，已自动截断"

	var src: String = result["filtered_text"]
	var norm := _normalize_text(src)
	# 打码标记：下标 i 为 1 就把原文第 i 个字符换成 *，保证等长
	var marks := PackedByteArray()
	marks.resize(src.length())

	var max_level := Level.NORMAL
	var all_hits: Array = []
	var hit_cats: Array = []
	for e in _entries:
		var entry: Dictionary = e
		var word: String = String(entry["word"]).to_lower()
		var spans: Array = _hit_spans(norm, word)
		if spans.is_empty():
			continue
		var raw_word: String = String(entry["word"])
		if not all_hits.has(raw_word):
			all_hits.append(raw_word)
		var cat: String = String(entry["cat"])
		if not hit_cats.has(cat):
			hit_cats.append(cat)
		var lv := int(entry["level"])
		if lv > max_level:
			max_level = lv
		for sp in spans:
			var span: Array = sp
			var st := int(span[0])
			var ln := int(span[1])
			if _in_whitelist(norm, st, ln):
				continue
			for k in range(st, mini(st + ln, marks.size())):
				marks[k] = 1

	if max_level > Level.NORMAL:
		var masked := ""
		for i in range(src.length()):
			masked += "*" if marks[i] == 1 else src[i]
		result["filtered_text"] = masked
		result["passed"] = false
		result["level"] = max_level
		result["hit_words"] = all_hits
		result["hit_categories"] = hit_cats
		match max_level:
			Level.SEVERE:
				result["action"] = Action.BLOCK
				result["reason"] = "消息包含严重违规内容，已被拦截"
			Level.MODERATE:
				result["action"] = Action.MASK
				result["reason"] = "消息包含违规内容，已打码处理"
			Level.MILD:
				result["action"] = Action.MASK
				result["reason"] = "消息包含疑似违规内容，请注意发言规范"
	return result


## 刷屏检测：间隔 + 窗口条数 + 重复内容，三者任一命中就拦。
## history 是最近消息时间戳（毫秒），repeat_history 是最近消息文本。
static func check_spam(now_ms: int, history: Array, text: String, repeat_history: Array) -> Dictionary:
	var result := {"spam": false, "reason": ""}
	if history.size() > 0:
		var last_ms := int(history[history.size() - 1])
		if too_fast(last_ms, now_ms):
			result["spam"] = true
			result["reason"] = "发送频率过高，请放慢语速"
			return result
	var window_start := now_ms - RATE_WINDOW_MS
	var count := 0
	for ts in history:
		if int(ts) >= window_start:
			count += 1
	if count >= MAX_MSG_PER_WINDOW:
		result["spam"] = true
		result["reason"] = "单位时间内发送消息过多，请稍后再试"
		return result
	var same_count := 0
	for msg in repeat_history:
		if String(msg) == text:
			same_count += 1
	if same_count >= REPEAT_LIMIT:
		result["spam"] = true
		result["reason"] = "请勿重复发送相同内容"
		return result
	return result


# ============================================== 内部逻辑

static func _init_if_needed() -> void:
	if _initialized:
		return
	_initialized = true
	for level in WORD_LIBRARY:
		var cats: Dictionary = WORD_LIBRARY[level]
		for cat in cats:
			var words: Array = cats[cat]
			for word in words:
				_entries.append({
					"word": String(word),
					"level": int(level),
					"cat": String(cat),
				})
	_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["word"]).length() > String(b["word"]).length())


## 归一化：全角转半角、统一小写。**只用于检测**，输出永远是原文等长替换。
static func _normalize_text(text: String) -> String:
	var lower := text.to_lower()
	var out := ""
	for i in range(lower.length()):
		var code := lower.unicode_at(i)
		if code >= 0xFF01 and code <= 0xFF5E:
			code -= 0xFEE0
		elif code == 0x3000:
			code = 0x20
		out += char(code)
	return out


## 找出某个词在归一化文本里的所有命中区间 [起点, 长度]，含变形绕过。
## 中文词直接子串匹配（中文没有词边界），英文/数字词按边界匹配防误伤。
static func _hit_spans(norm: String, word: String) -> Array:
	var spans: Array = []
	var wlen := word.length()
	if wlen <= 0 or norm.length() < wlen:
		return spans
	var strict := _has_latin(word) and not SUBSTRING_MODE

	# 1) 连续出现
	var pos := norm.find(word)
	while pos >= 0:
		if not strict or _boundary_ok(norm, pos, wlen):
			spans.append([pos, wlen])
		pos = norm.find(word, pos + 1)

	# 2) 中间插了少量非文字干扰符（「傻 逼」「f_u_c_k」）
	if DETECT_OBFUSCATION:
		for start in range(norm.length()):
			if norm.unicode_at(start) != word.unicode_at(0):
				continue
			var j := 1
			var i := start + 1
			var gap := 0
			while i < norm.length() and j < wlen:
				var code := norm.unicode_at(i)
				if code == word.unicode_at(j):
					j += 1
					gap = 0
				elif not _is_word_char(code):
					gap += 1
					if gap > MAX_OBFUSCATE_GAP:
						break
				else:
					break
				i += 1
			if j == wlen:
				var span_len := i - start
				if not strict or _boundary_ok(norm, start, span_len):
					if not spans.has([start, span_len]):
						spans.append([start, span_len])
	return spans


## 英文/数字词要求前后是非文字字符或首尾，避免误伤正常英文单词
static func _boundary_ok(norm: String, pos: int, length: int) -> bool:
	var left_ok := pos <= 0 or not _is_word_char(norm.unicode_at(pos - 1))
	var end := pos + length
	var right_ok := end >= norm.length() or not _is_word_char(norm.unicode_at(end))
	return left_ok and right_ok


static func _has_latin(word: String) -> bool:
	for i in range(word.length()):
		var c := word.unicode_at(i)
		if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
			return true
	return false


static func _is_word_char(code: int) -> bool:
	return (code >= 48 and code <= 57) \
		or (code >= 65 and code <= 90) \
		or (code >= 97 and code <= 122) \
		or (code >= 0x4e00 and code <= 0x9fff)


## 命中区间是否被白名单词完整盖住。只影响打码，不影响违规等级判定。
static func _in_whitelist(norm: String, pos: int, length: int) -> bool:
	for wl in WHITELIST:
		var w := String(wl)
		var p := norm.findn(w)
		while p >= 0:
			if p <= pos and p + w.length() >= pos + length:
				return true
			p = norm.findn(w, p + 1)
	return false
