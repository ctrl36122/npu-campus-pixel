extends Node
## Optional UPnP: asks the router to forward the UDP port so friends can join
## over the internet. Runs on a worker thread because discovery can take seconds.
signal mapping_finished(ok: bool, message: String)
var worker: Thread
var gateway: UPNP
var mapped_port: int = 0
var requested_port: int = 0
var epoch: int = 0

func request_mapping(port: int) -> void:
	release()
	requested_port = port
	var request_epoch: int = epoch
	worker = Thread.new()
	var result: Error = worker.start(_map.bind(port, request_epoch))
	if result != OK:
		worker = null
		_finish(request_epoch, false, "Could not start UPnP worker (code %d)." % result)

func _map(port: int, request_epoch: int) -> void:
	gateway = UPNP.new()
	var result: int = gateway.discover(2000, 2, "InternetGatewayDevice")
	if result != UPNP.UPNP_RESULT_SUCCESS or gateway.get_gateway() == null or not gateway.get_gateway().is_valid_gateway():
		_finish.call_deferred(request_epoch, false, "No usable UPnP gateway. LAN can still work; use manual UDP forwarding or a dedicated server.")
		return
	result = gateway.add_port_mapping(port, port, "Godot Multiplayer Starter", "UDP")
	if result != UPNP.UPNP_RESULT_SUCCESS:
		_finish.call_deferred(request_epoch, false, "The router refused UDP mapping (code %d)." % result)
		return
	mapped_port = port
	var address: String = gateway.query_external_address()
	if not address.is_valid_ip_address() or is_private_or_shared(address):
		_finish.call_deferred(request_epoch, false, "Mapping exists, but the router has a private/shared upstream address. Check upstream NAT or use a reachable server.")
	else:
		_finish.call_deferred(request_epoch, true, "UDP mapping created at %s:%d. Verify a join from another network." % [address, port])

func _finish(request_epoch: int, ok: bool, message: String) -> void:
	if request_epoch != epoch:
		return
	print("[upnp] ", message)
	mapping_finished.emit(ok, message)

static func is_private_or_shared(address: String) -> bool:
	var parts: PackedStringArray = address.split(".")
	if parts.size() != 4:
		return true
	var a: int = int(parts[0])
	var b: int = int(parts[1])
	return a == 10 or a == 127 or a == 0 or (a == 172 and b >= 16 and b <= 31) or (a == 192 and b == 168) or (a == 100 and b >= 64 and b <= 127) or (a == 169 and b == 254)

func release() -> void:
	epoch += 1
	if worker != null and worker.is_started():
		worker.wait_to_finish()
	worker = null
	if gateway != null and mapped_port != 0:
		gateway.delete_port_mapping(mapped_port, "UDP")
	mapped_port = 0
	gateway = null

func _exit_tree() -> void:
	release()
