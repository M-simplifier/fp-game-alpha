# Primary reference catalog

These links were recorded in research inspected on 3–4 October 2026. They are sources for methods, tool behavior, and further learning; inclusion does not mean the method has been implemented here. This curation reused the recorded links rather than making a new availability claim. Versioned/commit-pinned links should be preferred when reproducing a specific result.

## Sources for the executed laboratories

- [GHC 9.6.3 release](https://www.haskell.org/ghc/download_ghc_9_6_3.html)
- [LiquidHaskell options](https://ucsd-progsys.github.io/liquidhaskell/options/)
- [Pinned LH 0.9.6.3.1 package](https://hackage-content.haskell.org/package/liquidhaskell-0.9.6.3.1/liquidhaskell.cabal)
- [LH 0.9.14.1.1 source package](https://hackage-content.haskell.org/package/liquidhaskell-0.9.14.1.1)
- [Pinned newer division assumptions](https://github.com/ucsd-progsys/liquidhaskell/blob/952f02cfa4eb94f194e5b72706e55ce4fc1bcbb6/src/GHC/Real_LHAssumptions.hs)
- [Related division issue discussion](https://github.com/ucsd-progsys/liquidhaskell/issues/2285#issuecomment-2122794785)
- [SBV 10.12 package](https://hackage-content.haskell.org/package/sbv-10.12/sbv.cabal)
- [Z3 source](https://github.com/Z3Prover/z3)
- [TLC v1.7.4 release](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.4)
- [TLC model configuration](https://nightly.tlapl.us/doc/model/overview-page.html)
- [Specifying Systems](https://lamport.azurewebsites.net/tla/book.html)
- [Bend v2.0.35 release](https://github.com/bendlang/bend/releases/tag/v2.0.35)
- [Pinned Bend 2 README](https://github.com/bendlang/bend/blob/79df8d9c40722ee9507a1e253f283b51025f9d6c/README.md)
- [Pinned BendTT documentation](https://github.com/bendlang/bend/blob/79df8d9c40722ee9507a1e253f283b51025f9d6c/bend2/docs/BendTT/main.typ)
- [Pinned BendRT documentation](https://github.com/bendlang/bend/blob/79df8d9c40722ee9507a1e253f283b51025f9d6c/bend2/docs/BendRT/main.typ)
- [Pinned Bend 1 typing limitations](https://github.com/HigherOrderCO/Bend1/blob/814453670d0e0d6777c1313c972764dba0491b7f/docs/type-checking.md)
- [Pinned Bend 1 duplication limitations](https://github.com/HigherOrderCO/Bend1/blob/814453670d0e0d6777c1313c972764dba0491b7f/docs/dups-and-sups.md)

## Replay, numerical behavior, platforms, and game engineering

- [Factorio FFF-270](https://www.factorio.com/blog/post/fff-270)
- [Microsoft Xbox Accessibility Guidelines](https://learn.microsoft.com/en-us/gaming/accessibility/guidelines)
- [Glenn Fiedler, Fix Your Timestep!](https://gafferongames.com/post/fix_your_timestep/)
- [GGPO official](https://www.ggpo.net/)
- [Glenn Fiedler, State Synchronization](https://gafferongames.com/post/state_synchronization/)
- [MDN Page Visibility](https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API)
- [Android Save UI states](https://developer.android.com/topic/libraries/architecture/saving-states)
- [MDN Storage quotas and eviction](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)
- [Factorio FFF-415](https://www.factorio.com/blog/post/fff-415)
- [Factorio FFF-315](https://www.factorio.com/blog/post/fff-315)
- [Glenn Fiedler, Deterministic Lockstep](https://gafferongames.com/post/deterministic_lockstep/)
- [Factorio FFF-242, 2018](https://www.factorio.com/blog/post/fff-242)
- [Factorio FFF-302, 2019](https://www.factorio.com/blog/post/fff-302)
- [GGPO source repository](https://github.com/pond3r/ggpo)

## Testing and persistence

- [QuickCheck API](https://hackage-content.haskell.org/package/QuickCheck-2.18.0.0/docs/Test-QuickCheck.html)
- [Hedgehog](https://github.com/hedgehogqa/haskell-hedgehog)
- [quickcheck-state-machine](https://github.com/stevana/quickcheck-state-machine)
- [Csmithの差分試験](https://users.cs.utah.edu/~regehr/papers/pldi11-preprint.pdf)
- [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html)
- [SQLite crash試験](https://www.sqlite.org/transactional.html)
- [Protocol Buffersのschema更新](https://protobuf.dev/programming-guides/proto3/)
- [CBOR deterministic encoding, RFC8949 §4.2](https://www.rfc-editor.org/rfc/rfc8949.html)
- [WASMのNaN rationale](https://github.com/WebAssembly/design/blob/main/Rationale.md)
- [LHのoverflow注意](https://ucsd-progsys.github.io/liquidhaskell/blogposts/2017-03-20-arithmetic-overflows.lhs/)

## Solvers, refinements, temporal models, and concurrency

- [SBV](https://github.com/LeventErkok/sbv)
- [LH仕様](https://ucsd-progsys.github.io/liquidhaskell/specifications/)
- [導入](https://ucsd-progsys.github.io/liquidhaskell/install/)
- [Lamport TLA+](https://lamport.azurewebsites.net/tla/tla.html)
- [fairness/refinement](https://lamport.azurewebsites.net/tla/advanced.html)
- [Validating Traces, 2024](https://arxiv.org/abs/2404.16075)
- [io-sim公式repository](https://github.com/intersectmbo/io-sim)
- [開発元のtimeliness解説](https://well-typed.com/blog/2025/10/an-introduction-to-io-sim/)
- [DejaFu](https://dejafu.docs.barrucadu.dev/)
- [DejaFuのthreadDelay実装](https://raw.githubusercontent.com/barrucadu/dejafu/master/dejafu/Test/DejaFu/Conc/Internal.hs)

## Generation, protocols, relational properties, and advanced methods

- [Foundational Property-Based Testing](https://lemonidas.github.io/pdf/Foundational.pdf)
- [Dungeon Variations](https://drops.dagstuhl.de/entities/document/10.4230/LIPIcs.CP.2021.27)
- [Proof-Carrying Codeの原理](https://www.cs.cmu.edu/~fox/pcc.html)
- [Clarkson/Schneider, Hyperproperties](https://www.cs.cornell.edu/fbs/publications/Hyperproperties.pdf)
- [Alloy 6のscopeとtime horizon](https://alloytools.org/alloy6.html)
- [typed-protocols](https://github.com/IntersectMBO/typed-protocols)
- [CRDT研究者による解説](https://arxiv.org/abs/1805.06358)
- [Invariant confluence原論文](https://arxiv.org/abs/1402.2237)
- [GHC LinearTypes](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/linear_types.html)
- [Cousot, Abstract Interpretation](https://www.di.ens.fr/~cousot/COUSOTpapers/POPL77.shtml)
- [Clarke等, CEGAR](https://www.cs.cmu.edu/~emc/papers/Conference%20Papers/Counterexample-guided%20Abstraction%20Refinement.pdf)
- [Adapton原著とartifact](https://www.cs.umd.edu/projects/PL/adapton/)
- [Alternating-Time Temporal Logic](https://www.cis.upenn.edu/~alur/Jacm02.pdf)
- [不完全情報game](https://arxiv.org/abs/0706.2619)
- [Resource Aware ML](https://www.raml.co/)
- [原著](https://www.cs.cmu.edu/~janh/papers/hah12cav.pdf)
- [UPPAAL features](https://uppaal.org/uppaal5/)
- [timed system semantics](https://docs.uppaal.org/language-reference/system-description/semantics/)
- [PRISM rewards](https://www.prismmodelchecker.org/manual/ThePRISMLanguage/CostsAndRewards)
- [reward property semantics](https://www.prismmodelchecker.org/manual/PropertySpecification/Reward-basedProperties)
- [QuickSpec](https://www.cse.chalmers.se/~jomoa/papers/quickspec-JFP.pdf)
- [IronFleet原論文](https://www.microsoft.com/en-us/research/wp-content/uploads/2015/10/ironfleet.pdf)

## Suggested reading order

1. QuickCheck and state-machine testing for executable properties and useful counterexamples
2. SBV and the quantity refinements for local arithmetic contracts and assumptions
3. Specifying Systems and the trace-validation paper for asynchronous lifecycle behavior
4. Platform/storage documentation for boundaries a pure transition cannot enforce
5. Advanced methods only when a concrete failure mode motivates their additional modeling and maintenance cost

## Developer tooling consolidation

[Haskell tooling assessment and bounded executable probe](../research/haskell-tooling/README.md)
compares the existing Python orchestration with an opt-in Haskell build/check slice.
It records bootstrap costs, platform boundaries and compatibility checks separately
from the maintained game core and current development entrypoints.

[Measured iteration and parity latency](research-iteration-latency.md) separates
one-shot CI/local observations from guarantees and records the reviewed test-only
terrain equality optimization without changing the frozen oracle.

[Editor CI dependency-cache experiment](research-ci-cache.md) records the exact
cold PR miss and main cache population, trust boundaries and key inputs. Warm
reuse and any overall workflow speedup remain unmeasured.

## Validated change → play research

[Live-tuning source, tests, and measured workflow comparison](../research/live-tuning/README.md)
compares data admission, persistent GHCi reload and native build/launch in an
independent tiny CLI. New sessions adopt staged rules; restart retains old rules.

- [GHC 9.6.7 changes and recompilation](https://downloads.haskell.org/ghc/9.6.7/docs/users_guide/ghci.html#making-changes-and-recompilation)
- [GHC 9.6.7 loading compiled code](https://downloads.haskell.org/ghc/9.6.7/docs/users_guide/ghci.html#loading-compiled-code)

The manuals support reload/bytecode behavior, not the local timing numbers or
state-preserving hot reload.
