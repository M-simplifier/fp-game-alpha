#!/usr/bin/env bash
# Expected compiler failures are successful checks of the public boundary.
set -euo pipefail
cd "$(dirname "$0")/.."
GHC=${GHC:-ghc}
mkdir -p .build/api
# First ensure dependency failures cannot masquerade as API protection.
"$GHC" -XGHC2021 -Wall -Werror -fno-code -isrc \
  -ivendor/game-transition/src -ivendor/game-arena/src \
  -outputdir .build/api src/Paper/Game.hs
for name in ForgeCell ForgeWorld UpdateWorld; do
  if "$GHC" -XGHC2021 -fno-code -isrc \
      -ivendor/game-transition/src -ivendor/game-arena/src \
      -outputdir .build/api "test/api-rejections/$name.hs" >".build/api/$name.log" 2>&1; then
    echo "FAIL: $name unexpectedly compiled" >&2
    exit 1
  fi
  case "$name" in
    ForgeCell) expected='(Data constructor not in scope: Cell|Illegal term-level use.*Cell)' ;;
    ForgeWorld) expected='(Data constructor not in scope: World|Illegal term-level use.*World)' ;;
    UpdateWorld) expected='Not in scope:.*previousPosition' ;;
  esac
  grep -Eq "$expected" ".build/api/$name.log" || { cat ".build/api/$name.log"; exit 1; }
done
echo 'PASS: Cell/World constructors and World update selector remain private'
