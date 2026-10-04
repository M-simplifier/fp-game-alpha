#!/usr/bin/env bash
# Optional historical comparison: requires the foundation clone's local history.
# No fetch, network, compiler installation, or baseline source modification.
set -euo pipefail
cd "$(dirname "$0")/.."
GHC=${GHC:-ghc}
baseline=2487f7b31f75af65fa430123efbc4b67ca883b93
source_path=references/paper-circuit/src/Paper/Game.hs
mkdir -p .build/compat
if ! git show "$baseline:$source_path" > .build/compat/baseline.hs; then
  echo 'Baseline is absent. Run this optional check in the foundation clone with its history.' >&2
  exit 1
fi
printf '%s  %s\n' '2954c13c3ebec8ae1dfd7d499c0a5e0ebab47ac5ffddec7544792ca7a15d4289' '.build/compat/baseline.hs' | sha256sum -c -
sed 's/module Paper.Game/module Original/' .build/compat/baseline.hs > .build/compat/Original.hs
"$GHC" -O1 -XGHC2021 -Wall -Werror -isrc -i.build/compat \
  -ivendor/game-transition/src -ivendor/game-arena/src \
  -outputdir .build/compat test/CompareBaseline.hs -o .build/compat/compare
.build/compat/compare
