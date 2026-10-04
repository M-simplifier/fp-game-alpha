#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
cat > .build/Opaque.hs <<'HS'
module Opaque where
import Signal.Game
bad = Session 0 0 0 True 0 0 0 [] Delivering
HS
if ghc -XGHC2021 -fno-code -isrc -ivendor/game-transition/src -ivendor/game-arena/src .build/Opaque.hs >.build/opaque-result.txt 2>&1; then
  echo 'FAIL: Session constructor escaped'; exit 1
fi
grep -Eq 'Illegal term-level use|Data constructor not in scope' .build/opaque-result.txt
echo 'PASS: opaque Session constructor rejected by compiler'
