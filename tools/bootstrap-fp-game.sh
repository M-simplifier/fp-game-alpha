#!/bin/sh
# One explicit build, then use .build/tools/fp-game directly. No Python required.
set -eu
mode=offline
case "${1:-}" in
  '') ;;
  --download) mode=download; shift ;;
  --check) mode=check; shift ;;
  --help|-h)
    printf '%s\n' 'Usage: sh tools/bootstrap-fp-game.sh [--check|--download]' \
      'Default: build using the existing pinned dependency cache, without downloads.' \
      '--check: inspect GHC/Cabal before compilation; make no files or downloads.' \
      '--download: explicitly update the package index and acquire pinned dependencies.'
    exit 0 ;;
  *) printf '%s\n' 'Unknown option. Use --help.' >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { printf '%s\n' 'Unexpected arguments. Use --help.' >&2; exit 2; }
missing=0
for tool in ghc cabal; do
  if command -v "$tool" >/dev/null 2>&1; then
    if version=$("$tool" --numeric-version); then
      printf '%s: %s\n' "$tool" "$version" >&2
    else
      printf '%s\n' "$tool was found but its version check failed." >&2
      missing=1
    fi
  else
    printf '%s\n' "$tool is missing from PATH." >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  printf '%s\n' 'Install the chosen GHC/Cabal explicitly: https://www.haskell.org/ghcup/install/' >&2
  exit 1
fi
[ "$mode" != check ] || exit 0
root=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd)
for path in "$root/.build" "$root/.build/tools" "$root/.build/native-tool"; do
  [ ! -L "$path" ] || { printf '%s\n' 'Refusing a linked bootstrap output directory.' >&2; exit 1; }
done
[ -f "$root/tools/haskell/cabal.project" ] || { printf '%s\n' 'Missing tools/haskell/cabal.project. Restore the complete tooling source.' >&2; exit 1; }
destination="$root/.build/tools/fp-game"
check_destination() {
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
    printf '%s\n' 'Refusing a linked or non-file bootstrap executable destination.' >&2
    exit 1
  fi
}
check_destination
mkdir -p "$root/.build/tools"
cd "$root/tools/haskell"
if [ "$mode" = download ]; then
  cabal update
  cabal build exe:fp-game --builddir="$root/.build/native-tool"
else
  cabal build exe:fp-game --offline --builddir="$root/.build/native-tool"
fi
source=$(cabal list-bin exe:fp-game --offline --builddir="$root/.build/native-tool")
[ -f "$source" ] || { printf '%s\n' 'Cabal did not identify the built executable.' >&2; exit 1; }
temporary=$(mktemp "$root/.build/tools/.fp-game.XXXXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
cp "$source" "$temporary"
chmod 755 "$temporary"
check_destination
mv -f "$temporary" "$destination"
printf '%s\n' "Ready: $root/.build/tools/fp-game" >&2
