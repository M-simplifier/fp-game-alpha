# Live source readability review

## Scope and changes

Reviewed the new game's public transition path and its host boundary after pinned
Ormolu 0.9.0.0 normalization. All 62 live Haskell files under `src/`, `app/` and
`test/` are selected, including the inherited Colony modules. The preserved
`../red-dune` archive is the only Red Dune formatter exclusion.

The inherited code and early live modules compressed imports, data fields, guards
and command comprehensions onto long lines. Normalization makes those structures
inspectable and keeps a stable editing baseline. It deliberately changes layout
only, with Ormolu AST safety and idempotence checks retained; it is not a semantic
refactor or an assertion that every large module is beginner-friendly.

Dense pre-format `[value|...]` comprehensions were initially ambiguous to Ormolu's
auto-enabled quasiquote parser. The first normalization pass disabled QuasiQuotes,
matching the actual GHC2021 package language. Subsequent checks use the unmodified
project helper flags. No parser exemption, unsafe format or source exclusion is
needed for the resulting live source.

## One complete transition

1. A production intent is decoded by `RedDune.Protocol.decodeUICommand`. Its exact
   fields and canonical decimal identity are checked before narrowing an integer
   to `Word64`; malformed, future or overflowing identifiers are rejected
2. `RedDune.Game.previewGame` predicts through ordinary `issue` and returns an
   identity-bearing command envelope. Preview is not committed production
3. The commit branch of `applyAction` decodes that envelope, then calls the same
   `boundary` / `Colony.Scheduler.pureStep` transition. The receipt distinguishes
   accepted work from rejection. Only `finish` publishes the validated next game
4. `advanceGame` names `prepared`, `before`, `stepped`, campaign progress and the
   ending world. Policies use normal commands; the real clock step performs work
   and physical movement. `advanceCampaign` observes that committed change, so a
   UI click or initial stock does not become fresh-food campaign evidence
5. `observeGame` projects the state. `RedDune.Host` alone handles ownership, HTTP,
   the clock and durable checkpoint IO; `GameSave` validates the complete pure
   payload. Save/load completion is adopted through the host's serialized state

A reader needs the distinction between transport request identity, game command
identity and world state. The [HTTP contract](HOST-API.md), [API](API.md) and
[save format](SAVE-FORMAT.md) name those roles separately. They are not proofs of
correctness and do not make arbitrary direct record construction safe.

## Rubric and remaining work

Applied the foundation's [seven-dimension rubric](../../../docs/haskell.md):

| Dimension | Score / 2 | Evidence and qualification |
| --- | --- | --- |
| Domain vocabulary | 2 | Physical stock, incoming deliveries, campaign witnesses and shift policies are named in rules and observation |
| Type meaning | 1 | IDs/units and command alternatives express useful distinctions, but broad module exports permit direct record construction; validation remains a runtime obligation |
| Local reasoning | 2 | The named before/stepped/progress boundary in `advanceGame` makes campaign dependency order visible |
| Function shape | 1 | Main stages are named; `applyAction`, protocol case arms and inherited rule modules remain large or locally dense |
| Boundary clarity | 2 | Pure game transitions, protocol admission, observation and serialized host/file effects have distinct owners |
| Failure visibility | 2 | `Either` rejection, receipts, terminal campaign state and host cancellation paths are explicit and covered by dedicated tests |
| Example quality | 2 | README reading order, real production path, small pack-tuning exercise and separate bounded/long/manual gates agree with the implementation |

Scoped result: **12/14**, no zero dimension. This is a human code-review judgment,
not a quality proof, beginner study or waiver of the browser acceptance gap.

Two strengths: the physical campaign-witness boundary is visible in the actual
rule entrypoint; and canonical identity parsing preserves overflow/retry meaning
across Haskell and JavaScript rather than depending on JavaScript number rounding.

Highest-impact next improvements, with behavior-preserving checks required:

- Narrow exposed constructors/selectors and document trusted internal creation
  versus validated external admission before claiming opaque game state
- Split large operation dispatchers around stable domain responsibilities where
  it reduces the concepts held at once; avoid introducing one-use helper chains
- Replace cross-layer `Either String` failures with a small domain-specific error
  vocabulary where it makes rejection, legal blocked work and IO failure distinct

Formatting is checked by the root helper. Post-format native smoke and long-run
behavior evidence are reported separately; earlier results and a formatting pass
alone must not be presented as a new full playthrough. Actual browser and human
readability/play acceptance remain unrun.
