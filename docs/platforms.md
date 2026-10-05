# Routes and boundaries

`docs/support/routes.json` is the machine-readable source of route status,
commands and evidence. A route needs actual implementation and verification
before its status becomes supported. Planned routes can contain experiments;
their presence alone does not establish support.

The current evidence includes a maintained terminal starter, several pure-core
references and complete Afterlight host source. These are available examples
and verification records, not a restriction on the games an AI may build.
Choose the requested platform from the brief; research and implement missing
technical steps instead of replacing it with the terminal template.

Distinguish host OS, game target, rendering backend, build, actual runtime,
deployment and device performance. A successful native pure-core test is not
a browser build. A Web build is not a browser playthrough. A protocol client
is not a deployed multiplayer service. A command wrapper is not a connected
HLS session.

Template target/rendering choices are constrained by implemented routes.
The current native/terminal scaffold is self-contained and downloads no art,
audio, font or platform SDK. For graphical native, Haskell/WASM/Miso, server and mobile work, identify the
actual tools, dependencies, assets, runtime checks and known limits as part of
implementation. Record repeatable recipes as routes are established. A missing
pre-built template does not prohibit new implementation.

Toolchain installation follows the [setup guide](setup.md). Missing tools and
unverified routes are visible; commands do not silently install a global
toolchain or claim an empty operation succeeded.

## Red Dune local browser command room

[Red Dune live](red-dune-live.md) has a Linux GHC 9.6 native HTTP host and a thin
HTML/CSS/SVG/JavaScript view. It is **not** a Wasm build or a deployed web service.
The native process owns the clock, all game transitions and durable files; the
browser displays projections and sends commands. Native HTTP/protocol/lifecycle
checks and a repeatable bounded smoke route exist. Real-browser rendering,
pointer/keyboard, interruption and responsive-device acceptance remain unverified.
The host is loopback-only; another machine's browser cannot reach it. No tunnel
or public deployment is part of this route. Windows/macOS host support is unclaimed.

## Native developer tooling migration

The [Haskell CLI](native-tooling.md) has a source bootstrap and an executable
Linux/Windows/macOS integration matrix. Its first published revision passed native
Linux and macOS CI. Windows now passes bootstrap and formatting, but a path
validation test exposed normalization hiding a linked parent; its fix needs a
follow-up Windows run. The guide links exact jobs and source revision.
Existing Python/core route records retain their original evidence. Optional
terminal creation does not establish another host or limit the AI from implementing one.
