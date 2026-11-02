extends SceneTree
## 专用服务器（headless）：自动托管在 7654，等客户端连入，跑 30s 后退出。
## 配合 _test_seat_online_cli.gd 复现「联机起床抽搐」。

func _initialize() -> void:
	OS.set_environment("XGD_NOHOME", "1")
	root.add_child(load("res://scenes/online_boot.tscn").instantiate())
	# 等世界建好
	await create_timer(3.0).timeout
	var net := root.get_node_or_null("Net")
	print("[srv] 启动 %s" % ("OK" if (net != null and net.has_session()) else "FAIL"))
	create_timer(90.0).timeout.connect(func(): print("[srv] 退出"); quit(0))
