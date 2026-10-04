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
