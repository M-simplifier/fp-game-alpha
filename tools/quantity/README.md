# Current quantity checks

`python tools/quantity/check.py check` compiles the current
`references/red-dune/core/Colony/Units.hs`, requires eight named invalid
programs to fail for their intended type/constructor reason, then compares
631,024 finite inputs with an independent Python integer oracle.

The hidden constructor, nominal resource tag role and checked arithmetic are
current API contracts. The checker never compiles a historical implementation
or annotation-only mirror. This is finite GHC/runtime validation, not a
LiquidHaskell or universal arithmetic proof. Outputs stay in `.build/quantity/`.
