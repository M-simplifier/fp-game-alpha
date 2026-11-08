# SplitMix Windows seed adaptation

The Windows Afterlight build uses Yampa 0.15, random 1.2.1.3, and splitmix
0.1.3.2. The preparation script verifies the [SplitMix source archive](https://hackage-content.haskell.org/package/splitmix-0.1.3.2/splitmix-0.1.3.2.tar.gz)
against SHA-256 `a61d4e8b30f5a16526d7d31171b674ae7924d2207f378060d13363bd8794de8c`.
It retains the two original generator modules and the original BSD-3-Clause
license byte for byte. This directory supplies the Windows x64 library manifest
and the replacement for `System.Random.SplitMix.Init`.

Upstream Windows initialization reads 64 bits from RtlGenRandom through a C
file and uses a fixed value on failure. This adaptation reads the same number
of bytes from the Windows system-preferred provider via a Haskell FFI import
and raises an IO error on failure. Explicit seeds and the generator's sequence
remain those of the original package. [BCryptGenRandom API](https://learn.microsoft.com/en-us/windows/win32/api/bcrypt/nf-bcrypt-bcryptgenrandom)
