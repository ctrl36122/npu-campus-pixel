extends Node
## A fixed 30 Hz network clock. Movement commands and server simulation run on
## these ticks, not on the frame rate, so every machine steps the same amount.
signal network_tick(tick: int)
const RATE: int = 30
const DELTA: float = 1.0 / RATE
var tick: int = 0
var accumulator: float = 0.0

func _physics_process(delta: float) -> void:
	accumulator += delta
	var steps: int = 0
	while accumulator >= DELTA and steps < 5:
		accumulator -= DELTA
		steps += 1
		tick += 1
		network_tick.emit(tick)
	if steps == 5:
		accumulator = minf(accumulator, DELTA)
