extends SceneTree
## 验证聊天：发一条消息 → 记录行出现 + 说话者头顶弹气泡 → 气泡几秒后消失

var step := 0
var boot
var net
var chat
var t_sent := 0


func _initialize() -> void:
	boot = load("res://scenes/online_boot.tscn").instantiate()
	root.add_child(boot)
	net = root.get_node_or_null("Net")


func _process(_d: float) -> bool:
	step += 1
	if step == 330:
		chat = boot.get_node_or_null("Chat")
		if chat == null:
			print("结果 FAIL：聊天层没创建")
			quit(1)
			return true
		print("聊天层 OK，历史行数=%d" % chat._lines.size())
		# 直接走 Net 的 RPC（call_local，自己立刻收到）
		net.call("post_message", "有人在吗？我在图书馆门口")
	elif step == 350:
		t_sent = Time.get_ticks_msec()
		print("发送后 历史行数=%d" % chat._lines.size())
		var av = _local_avatar()
		if av != null:
			print("本机气泡 visible=%s 文本=%s" % [av.get_node("Bubble").visible, av.get_node("Bubble").text])
		else:
			print("结果 FAIL：没找到本地角色")
	# headless 不限帧，帧数不等于时间，用真实毫秒判断
	if t_sent > 0 and Time.get_ticks_msec() - t_sent > 4200:
		var av = _local_avatar()
		if av != null:
			print("4.2 秒后气泡 visible=%s（应为 false）" % av.get_node("Bubble").visible)
		print("结果 DONE")
		quit(0)
		return true
	return false


func _local_avatar():
	for n in root.find_children("*", "CharacterBody2D", true, false):
		if n.is_local_player:
			return n
	return null
