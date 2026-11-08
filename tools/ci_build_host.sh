#!/usr/bin/env bash
# Scope compiled dependencies to the native tools and ABI they were built with.
set -euo pipefail

case "$RUNNER_OS" in
  Linux)
    libc=$(getconf GNU_LIBC_VERSION)
    compiler=$(cc --version)
    linker=$(ld --version)
    abi=$(printf '%s\n' "$libc" "$compiler" "$linker")
    ;;
  macOS)
    os=$(sw_vers -productVersion)
    sdk=$(xcrun --sdk macosx --show-sdk-path)
    sdk_build=$(xcrun --sdk macosx --show-sdk-build-version)
    compiler=$(xcrun --find clang)
    linker=$(xcrun --find ld)
    tools=$(shasum -a 256 "$compiler" "$linker")
    abi=$(printf '%s\n' "$os" "$sdk" "$sdk_build" "$tools" "${GHCUP_INSTALL_BASE_PREFIX:-$HOME}")
    ;;
  Windows)
    # The Windows job uses the image's GHCup/MSYS2 and bundled compiler tools.
    abi=$ImageVersion
    ;;
  *)
    echo "Unsupported CI build host: $RUNNER_OS" >&2
    exit 1
    ;;
esac

printf '%s\n' "$ImageOS" "$RUNNER_ARCH" "$abi" | git hash-object --stdin
