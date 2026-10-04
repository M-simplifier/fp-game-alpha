# Signal Courier

A new small side-view platformer: carry a lantern parcel east through Canal
Steps, Rooftop Post and Last Light. Each beacon receives its parcel, lights up,
and hands off the next one. Deliver all three to win. Optional rooftop stamps
reward detours. Falling into the canals restores the last delivered beacon.

Keyboard and touch controls, 60 fixed ticks/second, integer coordinates and
velocities. One-way platforms, immediate horizontal control, no combat, audio,
external assets, persistent save, procedural randomness or undo. Retry restores
the checkpoint and resets the shift timer; restart resets the entire route.
The three-minute simulation limit ends the shift without removing retry.

Acceptance: executable input traces deliver all parcels, including a second
route collecting all stamps, without falling; native and actual Wasm execution
must agree on the winning route. Browser input is implemented, but a browser
playthrough is a separate acceptance still pending in this environment.
