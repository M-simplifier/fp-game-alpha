# Direction

Help a person and an AI create and grow their own Haskell game: small shared
transition/admission libraries, current implementations worth reading, and
practical build/play/change guidance. Real games should improve the common
engine design without forcing every game into one template.

Continue from the current game and its actual player-visible boundary. Keep
APIs, save/protocol invariants and deterministic tests strong. A new abstraction
should pay for itself in more than one concrete use. Add formal tools only for
a current, precise property whose value exceeds the extra environment.

Other-host, browser/device, actual editor and human play coverage must earn
their own verification; source availability is not a passed run.
