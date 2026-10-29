extends SceneTree
## 验证聊天框的点击链路（必须带窗口跑，不能 --headless）：
##   点标题栏 → 展开；点 ✕ → 收起；桌面鼠标点标题栏 → 展开。
## 触摸与鼠标各测一遍，因为真机上同一次点按会同时产生两种事件，
## 之前「点了没反应」就是两套逻辑互相抵消。
##
## 跑法：
##   XGD_TOUCH=1 XGD_OFFLINE=1 godot --path . --script tools/_test_chat_ui.gd --resolution 720x1280

var boot: Node
var chat: Node
var step := 0
var fails: Array[String] = []


func _initialize() -> void:
	boot = load("res://scenes/online_boot.tscn").instantiate()
	root.add_child(boot)


func _process(_d: float) -> bool:
	step += 1

	if step == 90:
		chat = boot.get_node_or_null("Chat")
		if chat == null:
			print("FAIL：聊天层没创建")
			quit(1)
			return true
		print("[init] 视口 =", root.get_visible_rect().size)
		print("[init] 面板 rect =", chat._panel.get_global_rect())
		print("[init] 标题栏 rect =", chat._title_btn.get_global_rect())
		print("[init] expanded =", chat._expanded, "（应 false）")
		if chat._expanded:
			fails.append("初始状态就展开了")
		_tap(chat._title_btn.get_global_rect().get_center(), true)
		return false

	if step == 120:
		print("[点标题栏 / 触摸] expanded =", chat._expanded, "（应 true）")
		if not chat._expanded:
			fails.append("触摸点标题栏没有展开")
		print("[点标题栏 / 触摸] ✕ 可见 =", chat._close_btn.visible, " 输入行可见 =", chat._composer.visible)
		_tap(chat._close_btn.get_global_rect().get_center(), true)
		return false

	if step == 150:
		print("[点 ✕ / 触摸] expanded =", chat._expanded, "（应 false）")
		if chat._expanded:
			fails.append("触摸点 ✕ 没有收起")
		_tap(chat._title_btn.get_global_rect().get_center(), false)
		return false

	if step == 180:
		print("[点标题栏 / 鼠标] expanded =", chat._expanded, "（应 true）")
		if not chat._expanded:
			fails.append("鼠标点标题栏没有展开")
		_tap(chat._close_btn.get_global_rect().get_center(), false)
		return false

	if step == 210:
		print("[点 ✕ / 鼠标] expanded =", chat._expanded, "（应 false）")
		if chat._expanded:
			fails.append("鼠标点 ✕ 没有收起")
		# 灌 30 条消息，测滚动
		for i in 30:
			chat._on_message("同学%d" % i, "第 %d 条测试消息，随便写点长的内容看看换行和滚动是否正常" % i)
		return false

	if step == 240:
		var bar: VScrollBar = chat._scroll.get_v_scroll_bar()
		var bottom := int(bar.max_value - bar.page)
		print("[滚动] 内容高度 =", int(bar.max_value), " 可滚动到 =", bottom, " 当前位置 =", chat._scroll.scroll_vertical)
		if bottom < 20:
			fails.append("30 条消息后没有产生滚动空间（内容没撑开）")
		# 往上翻
		chat._scroll.scroll_vertical = 0
		return false

	if step == 250:
		chat._on_message("新来的", "翻着历史的时候来了新消息")
		return false

	if step == 270:
		print("[滚动] 翻到顶后来了新消息，当前滚动位置 =", chat._scroll.scroll_vertical, "（应仍为 0，不被拽回底部）")
		if chat._scroll.scroll_vertical > 4:
			fails.append("新消息把正在翻历史的用户拽回了底部")
		# 回到贴底状态再收一条，应自动跟随
		var bar: VScrollBar = chat._scroll.get_v_scroll_bar()
		chat._scroll.scroll_vertical = int(bar.max_value - bar.page)
		return false

	if step == 290:
		chat._on_message("刚进来", "贴着底的时候来新消息，应该自动跟到底")
		return false

	if step == 310:
		var bar: VScrollBar = chat._scroll.get_v_scroll_bar()
		var bottom := int(bar.max_value - bar.page)
		print("[滚动] 贴底收消息后 位置 =", chat._scroll.scroll_vertical, " 底部 =", bottom, "（应相等）")
		if absi(chat._scroll.scroll_vertical - bottom) > 4:
			fails.append("贴底时新消息没有自动跟随到底部")
		if fails.is_empty():
			print("结果 PASS：点击链路与滚动都正常")
			quit(0)
		else:
			for f in fails:
				print("结果 FAIL：", f)
			quit(1)
		return true

	return false


## 注入一次点按。touch=true 用触摸事件（真机路径），false 用鼠标左键（桌面路径）
func _tap(pos: Vector2, touch: bool) -> void:
	if touch:
		var down := InputEventScreenTouch.new()
		down.index = 0
		down.position = pos
		down.pressed = true
		root.push_input(down, true)
		var up := InputEventScreenTouch.new()
		up.index = 0
		up.position = pos
		up.pressed = false
		root.push_input(up, true)
	else:
		var md := InputEventMouseButton.new()
		md.button_index = MOUSE_BUTTON_LEFT
		md.position = pos
		md.global_position = pos
		md.pressed = true
		root.push_input(md, true)
		var mu := InputEventMouseButton.new()
		mu.button_index = MOUSE_BUTTON_LEFT
		mu.position = pos
		mu.global_position = pos
		mu.pressed = false
		root.push_input(mu, true)
