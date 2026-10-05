# Quantity types: source and executable checks

`fixture/Colony/Units.hs` is the frozen 0.6 module, selected byte for byte.
`annotated/Colony/Units.hs` adds LiquidHaskell comments without changing
Haskell types, roles, imports, instances or function bodies. The original and
annotated SHA-256 values are checked by `check.py`; their source identities are
also recorded in the publication manifest.

The representation is `newtype Qty r = Qty Int64` with a **nominal** role and
an unexported constructor. `mkQty` accepts only integers from 0 through
9,000,000,000,000. Addition and subtraction go through `Integer` before the
bounded conversion. `Qty WaterTag` and `Qty OreTag` cannot be mixed in ordinary
typed calls; the static examples deliberately try this and other invalid
coercions. A type alias would not create this distinction. `Resource` is a
runtime tag, so matching a dynamic `Resource` to `Qty StockUnit` still needs a
separate application-level check.

From the repository root, with Python 3.12+ and GHC 9.6.7 on PATH:

```sh
python research/quantity/check.py doctor
python research/quantity/check.py check
```

`check` requires eight named examples to fail for the expected type/constructor
reason, and two positive examples to compile. It then runs 631,024 fixed and
seeded inputs against an independent Python arbitrary-precision oracle, first
on the frozen module and then on the annotation-only module. All outputs must
match the oracle and each other byte for byte. The output and compiler logs go
under the ignored `.build/quantity/`; a compact result JSON is generated there.
An unavailable or different compiler, unrelated rejection, timeout, mismatch,
or changed frozen source makes the command fail.

This is finite compiler/runtime validation. It does **not** run LiquidHaskell
or prove a universal bound. The historical LiquidHaskell SAFE25 result applies
only to six selected binders under the pinned GHC 9.6.3/LiquidHaskell
0.9.6.3.1/Z3 4.15.1 assumptions. Its six mutants were historically UNSAFE;
they have not been rerun by this source-only command. See the canonical
guarantee scope in `docs/guarantees.md` and the reproduction plan in
`docs/research-reproduction.md`.

The separate opt-in [pinned LiquidHaskell checker](lh-checker/README.md)
provides the recovered six mutants, exact checker flags, trusted-source
snapshots, solver capture/replay, and nine independent SMT models.

The source and oracle are selected author-supplied technical work under the
repository MIT license. The 14 selected Haskell sources and oracle definitions
came from the inspected source transfer; the maintained `check.py` and this
explanation are public-alpha adaptations. This source-only target contains no third-party checker snapshots,
dependency archives, whole-game archive or raw historical logs are included.
