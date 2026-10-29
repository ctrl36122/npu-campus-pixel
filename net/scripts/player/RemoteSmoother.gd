class_name RemoteSmoother
extends RefCounted
## Draws other players 100 ms in the past, interpolating between the server
## positions on either side, so they glide instead of jumping between updates.
const SNAP_DISTANCE: float = 400.0
const DELAY_MS: int = 100
const CAPACITY: int = 32
var samples: Array[Dictionary] = []

func push(at: Vector2, stamp: int) -> void:
	if not samples.is_empty() and at.distance_to(samples.back()["position"]) > SNAP_DISTANCE:
		samples.clear()
	samples.append({"time": stamp, "position": at})
	while samples.size() > CAPACITY:
		samples.pop_front()

func sample(now: int, current: Vector2) -> Vector2:
	if samples.is_empty():
		return current
	var newest: Vector2 = samples.back()["position"]
	if current.distance_to(newest) > SNAP_DISTANCE:
		return newest
	var draw_time: int = now - DELAY_MS
	if draw_time >= int(samples.back()["time"]):
		return newest
	if draw_time <= int(samples.front()["time"]):
		return samples.front()["position"]
	for i in range(1, samples.size()):
		var right: Dictionary = samples[i]
		if int(right["time"]) >= draw_time:
			var left: Dictionary = samples[i - 1]
			var span: float = maxf(1.0, float(right["time"] - left["time"]))
			return Vector2(left["position"]).lerp(right["position"], clampf(float(draw_time - left["time"]) / span, 0.0, 1.0))
	return newest
