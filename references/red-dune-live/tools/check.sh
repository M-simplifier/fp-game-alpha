#!/usr/bin/env bash
# Linux-only optional reference; never included in the foundation Cabal project.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$root"
project=cabal.project.red-dune-live
case "${1:-help}" in
  smoke)
    # These explicit targets deliberately exclude live-campaign and the benchmark.
    cabal build --project-file="$project" exe:red-dune-live test:live-boundary test:live-construction test:live-host-lifecycle test:live-tile-order test:live-legacy
    cabal test --project-file="$project" live-boundary live-construction live-host-lifecycle live-tile-order live-legacy --test-show-details=direct
    binary=$(cabal list-bin --project-file="$project" exe:red-dune-live)
    cd references/red-dune-live
    node tools/test_browser_protocol.cjs
    node tools/test_http.cjs "$binary"
    ;;
  campaign)
    # Both complete authored scenarios are explicit, longer acceptance gates.
    cabal test --project-file="$project" live-campaign --test-show-details=direct --test-options=settlement
    cabal test --project-file="$project" live-campaign --test-show-details=direct --test-options=recovery
    ;;
  play)
    cabal build --project-file="$project" exe:red-dune-live
    binary=$(cabal list-bin --project-file="$project" exe:red-dune-live)
    cd references/red-dune-live
    shift
    exec "$binary" "$@"
    ;;
  help|--help|-h)
    printf '%s\n' 'Usage: bash references/red-dune-live/tools/check.sh {smoke|campaign|play [--port NUMBER]}'
    printf '%s\n' 'Requires Linux, GHC 9.6.x, Cabal; smoke also needs Node 20+. Run cabal update once before the first build.'
    ;;
  *)
    printf '%s\n' 'Unknown action; choose smoke, campaign or play.' >&2
    exit 2
    ;;
esac
