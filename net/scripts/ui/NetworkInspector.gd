extends CanvasLayer
## F3: who is connected, messages sent and received, ENet round-trip time and
## how often prediction needed correcting. F4: the lag dial.
@onready var panel: PanelContainer = $Panel
@onready var header: Label = $Panel/Rows/Header

func _ready() -> void:
	panel.hide()
	$Dial.hide()
	$Dial/Rows/Enabled.toggled.connect(func(value: bool): NetDebug.enabled = value)
	$Dial/Rows/Latency.value_changed.connect(func(value: float): NetDebug.latency_ms = value)
	$Dial/Rows/Jitter.value_changed.connect(func(value: float): NetDebug.jitter_ms = value)
	$Dial/Rows/Loss.value_changed.connect(func(value: float): NetDebug.loss_chance = value / 100.0)

func _process(_delta: float) -> void:
	var lines: PackedStringArray = ["OFFLINE" if not Net.has_session() else "ID %d | %s" % [Net.my_id(), "SERVER" if Net.is_server() else "CLIENT"]]
	for id in Net.peers:
		lines.append("%s: %s" % [id, Net.peers[id]["name"]])
	lines.append("Application calls sent/received: %d / %d" % [NetDebug.sent_messages, NetDebug.received_messages])
	lines.append("Estimated outgoing payload: %.0f B/s" % NetDebug.payload_bytes_per_second)
	lines.append("ENet RTT to host: %d ms (-1 = unavailable)" % NetDebug.rtt_ms(1))
	lines.append("Corrections: %d | last %.2f px" % [NetDebug.reconciliations, NetDebug.last_correction])
	header.text = "\n".join(lines)
	$Dial/Rows/Enabled.set_pressed_no_signal(NetDebug.enabled)
	$Dial/Rows/Latency.set_value_no_signal(NetDebug.latency_ms)
	$Dial/Rows/Jitter.set_value_no_signal(NetDebug.jitter_ms)
	$Dial/Rows/Loss.set_value_no_signal(NetDebug.loss_chance * 100.0)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_inspector"):
		panel.visible = not panel.visible
		get_viewport().set_input_as_handled()
	if event.is_action_pressed("toggle_lag_dial"):
		$Dial.visible = not $Dial.visible
		get_viewport().set_input_as_handled()
