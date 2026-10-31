extends RefCounted
## 聊天内容守卫：违规词打码 + 刷屏节流。
##
## 定位是「提供处置能力」，不是做一套完备的内容审查 —— 词库永远不全，
## 真正兜底靠管理员命令（见 Net.gd 的 /mute、/clear）。
##
## 两条硬性约束：
##   1. 词表**绝不能收单字**（比如「操」）——「操场」「操作」会被误伤，
##      校园地图里这两个词到处都是，一旦误伤就是满屏星号。
##   2. 只做等长打码（把命中词换成同样长度的 *），不改句子长度，
##      这样客户端本地和服务端过滤两次的结果一致，不会出现「我看到的和别人看到的不一样」。

## 命中就整词打码。全部按「完整词」匹配。
const BLOCKED := [
	# 辱骂
	"傻逼", "沙比", "煞笔", "脑残", "智障", "草泥马", "尼玛的",
	"你妈的", "他妈的", "干你娘", "狗日的", "去死吧",
	# 引流 / 交易（校园群里最常见的一类）
	"加微信", "加qq", "代练", "刷单", "兼职日结", "卖号", "收号", "低价出",
	# 违法内容
	"赌博", "博彩", "网赌", "毒品", "冰毒", "枪支", "色情", "裸聊", "约炮", "援交",
	# 英文（少量常见脏话）
	"fuck", "shit", "bitch",
]

## 同一个人两条消息的最小间隔（毫秒）。太短就是刷屏。
const MIN_INTERVAL_MS := 1200
## 同一句话连续重复几次就拦。
const REPEAT_LIMIT := 3


## 把命中词替换成等长的 *。大小写不敏感（英文词也能命中）。
static func filter(text: String) -> String:
	var out := text
	for word in BLOCKED:
		var w := str(word)
		if w.is_empty():
			continue
		out = _mask(out, w)
	return out


## 是否含违规词（用来给发送者一句提示，至于打码交给 filter）
static func has_blocked(text: String) -> bool:
	for word in BLOCKED:
		var w := str(word)
		if not w.is_empty() and text.findn(w) >= 0:
			return true
	return false


## 是否发得太快。last_ms 为 0 表示第一次发言。
static func too_fast(last_ms: int, now_ms: int) -> bool:
	if last_ms <= 0:
		return false
	return now_ms - last_ms < MIN_INTERVAL_MS


static func _mask(text: String, word: String) -> String:
	var wlen := word.length()
	if wlen <= 0:
		return text
	var out := text
	var from := 0
	while true:
		var i := out.findn(word, from)
		if i < 0:
			break
		out = out.substr(0, i) + "*".repeat(wlen) + out.substr(i + wlen)
		from = i + wlen
	return out
