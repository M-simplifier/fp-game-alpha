#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/wasm
wasm32-wasi-ghc -O2 -XGHC2021 -Wall -Werror -no-hs-main -optl-mexec-model=reactor \
 -isrc -ivendor/game-transition/src -ivendor/game-arena/src -outputdir .build/wasm \
 -optl-Wl,--export=hs_init,--export=newSession,--export=action,--export=renderSession,--export=readTicks,--export=readPhase,--export=freeText,--export=freeSession \
 app/Browser.hs -o web/game.wasm
