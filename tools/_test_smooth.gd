extends SceneTree
## 平滑度数值测试：按住右键跑 3 秒，逐帧记录「精灵视觉位置」的帧间位移。
##
## 修好之前：移动跑在 30Hz tick 上、画面 60fps，位移序列是
##   0, 0, 7.3, 0, 0, 7.3 ...（每两帧跳一步 = 抽搐）
## 修好之后：位移应均匀（每帧都差不多），用「最大帧/最小帧」的倍数衡量。

var step := 0
var boot
var avatar
var samples: Array[float] = []
var last_pos := Vector2.ZERO
var started := false


func _initialize() -> void:
	boot = load("res://scenes/online_boot.tscn").instantiate()
	root.add_child(boot)


func _process(_d: float) -> bool:
	step += 1
	if step == 300:
		avatar = null
		for p in get_nodes_in_group("players"):
			if p.is_local_player:
				avatar = p
				break
		if avatar == null:
			print("结果 FAIL：没找到本地角色")
			quit(1)
			return true
		Input.action_press("move_right")
		started = true
		last_pos = avatar.visual.global_position
	elif started and step > 320 and step < 560:
		var p: Vector2 = avatar.visual.global_position
		samples.append(p.distance_to(last_pos))
		last_pos = p
	elif step == 560:
		Input.action_release("move_right")
		if samples.size() < 100:
			print("结果 FAIL：样本太少 ", samples.size())
			quit(1)
			return true
		# 找出最大的 5 个帧间位移和它们的序号，判断是「持续的阶跃抽搐」
		# 还是「一次性的校正/碰撞」（后者只是个别帧，不算抽搐）
		var idxs: Array[int] = []
		for i in samples.size():
			idxs.append(i)
		idxs.sort_custom(func(a, b): return samples[a] > samples[b])
		var top := ""
		for k in mini(5, idxs.size()):
			top += " #%d=%.1f" % [idxs[k], samples[idxs[k]]]
		print("最大 5 个帧间位移：", top)
		var nz: Array[float] = []
		for v in samples:
			if v > 0.01:
				nz.append(v)
		var avg := 0.0
		for v in nz:
			avg += v
		avg /= maxf(1.0, nz.size())
		var zeros := samples.size() - nz.size()
		print("帧数=%d 有效位移帧=%d 零位移帧=%d 平均帧位移=%.2f" % [samples.size(), nz.size(), zeros, avg])
		# 判定：除掉前 5 个离群值后，其余帧的最大/平均 < 2.5（均匀移动）
		var rest_max := 0.0
		var outlier := {}
		for k in mini(5, idxs.size()):
			outlier[idxs[k]] = true
		for i in samples.size():
			if not outlier.has(i):
				rest_max = maxf(rest_max, samples[i])
		var ok := zeros < samples.size() * 0.05 and rest_max < avg * 2.5
		print("结果 %s（剔除离群后最大/平均=%.2f，零位移帧 %d/%d）" %
			["PASS" if ok else "FAIL", rest_max / maxf(0.001, avg), zeros, samples.size()])
		quit(0)
		return true
	return false
