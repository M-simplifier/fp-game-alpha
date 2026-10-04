#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/native
ghc -XGHC2021 -Wall -Werror -isrc -ivendor/game-transition/src -ivendor/game-arena/src -outputdir .build/native test/Main.hs -o .build/tests
.build/tests
