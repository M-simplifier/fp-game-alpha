# Routes and boundaries

`docs/support/routes.json` is the machine-readable source of route status,
commands and evidence. A route needs actual implementation and verification
before its status becomes supported. Planned routes can contain experiments;
their presence alone does not establish support.

The initial priority is native Windows terminal development and optional
VSCode/Neovim integration using the same CLI and HLS project. Linux/macOS
kernel/CLI CI has passed. Generated-game continuation, editor runtime,
graphical/Web/server/mobile and performance are separate checks. macOS real
hardware play/editor checks remain unverified unless recorded explicitly.

Distinguish host OS, game target, rendering backend, build, actual runtime,
deployment and device performance. A successful native pure-core test is not
a browser build. A Web build is not a browser playthrough. A protocol client
is not a deployed multiplayer service. A command wrapper is not a connected
HLS session.

Template target/rendering choices are constrained by implemented routes.
The current native/terminal scaffold is self-contained and downloads no art,
audio, font or platform SDK. Graphical native, Haskell/WASM/Miso, server and
mobile routes must declare pinned tools, download hashes, dependencies,
runtime checks and known limits before entering the default new-game flow.

Toolchain installation follows the [setup guide](setup.md). Missing tools and
unverified routes are visible; commands do not silently install a global
toolchain or claim an empty operation succeeded.
