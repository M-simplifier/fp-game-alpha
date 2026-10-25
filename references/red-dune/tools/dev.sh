#!/usr/bin/env bash
# Minimal bootstrap; all supervision, hashing, HTTP and reload logic is Haskell.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
cabal_bin=${CABAL:-cabal}
project="$root/cabal.project.red-dune-dev"
build="$root/.build/red-dune-dev"
dist=
config=()
args=("$@")
# The launcher and supervisor must use the same Cabal/offline configuration.
while (($#)); do
  case "$1" in
    --cabal=*) cabal_bin=${1#*=}; shift ;;
    --cabal) cabal_bin=$2; shift 2 ;;
    --cabal-config=*) config=("--config-file=${1#*=}"); shift ;;
    --cabal-config) config=("--config-file=$2"); shift 2 ;;
    --project-file=*) project=${1#*=}; shift ;;
    --project-file) project=$2; shift 2 ;;
    --build-dir=*) build=${1#*=}; shift ;;
    --build-dir) build=$2; shift 2 ;;
    --dist-dir=*) dist=${1#*=}; shift ;;
    --dist-dir) dist=$2; shift 2 ;;
    *) shift ;;
  esac
done
common=("--project-file=$project" "--builddir=${dist:-$build/dist}")
"$cabal_bin" "${config[@]}" build "${common[@]}" exe:red-dune-devloop
binary=$("$cabal_bin" "${config[@]}" list-bin "${common[@]}" exe:red-dune-devloop)
export RED_DUNE_DEV_ROOT="$root"
exec "$binary" --cabal "$cabal_bin" "${args[@]}"
