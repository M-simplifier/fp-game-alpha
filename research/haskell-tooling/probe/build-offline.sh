#!/bin/sh
# Opt-in local bootstrap. The supplied config must point at already cached pinned dependencies.
set -eu
: "${CABAL_CONFIG:?Set CABAL_CONFIG to an existing Cabal config with cached dependencies}"
cd "$(dirname "$0")"
cabal --config-file="$CABAL_CONFIG" build --offline exe:fp-game-probe
exe=$(cabal --config-file="$CABAL_CONFIG" list-bin exe:fp-game-probe)
mkdir -p bin
cp "$exe" bin/fp-game-probe
printf '%s\n' "Built bin/fp-game-probe (not installed, game tools unchanged)"
