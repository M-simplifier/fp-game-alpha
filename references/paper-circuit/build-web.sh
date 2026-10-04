#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
command -v wasm32-wasi-ghc >/dev/null || { echo 'Activate GHC-Wasm before building.' >&2; exit 1; }
mkdir -p .build/wasm
wasm32-wasi-ghc -O2 -XGHC2021 -Wall -Werror -no-hs-main -optl-mexec-model=reactor \
  -isrc -ivendor/game-transition/src -ivendor/game-arena/src -outputdir .build/wasm \
  -optl-Wl,--export=hs_init,--export=newSession,--export=action,--export=renderSession,--export=readMoves,--export=readPhase,--export=freeText,--export=freeSession,--export=newCatalog,--export=freeCatalog,--export=newSessionFrom,--export=allocateText,--export=stageCatalog \
  app/Browser.hs -o web/game.wasm
