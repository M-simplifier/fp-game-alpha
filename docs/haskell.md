# Readable Haskell and reference-game review

The reference games teach by being worth reading. Keep advanced types where they express a real distinction, and give that distinction a name the reader can connect to the game.

## Semantic names without imaginary guarantees

- Use a `type` alias to name a recurring meaning or simplify a distracting signature. It is the same underlying type and adds no type safety or validation.
- Use a `newtype` when accidental interchange is a real risk. A `newtype Health = Health Int` separates a type; it does not establish a nonnegative bound.
- Use a private constructor and checked construction when an invariant must hold. Review all construction paths and exported operations, including parsers, derived instances, lenses, and coercion/role exposure where relevant.
- A hidden record constructor is insufficient if an exported selector still permits record update. Compile an outside-client rejection fixture for an API that promises read-only access; export ordinary projection functions when update fields must stay private.
- Validate bounds before overflow-sensitive arithmetic. For a checked width `size <= limit`, test `position <= limit - size` rather than trusting `position + size <= limit` on bounded `Int`. Test extreme machine values at external input boundaries.
- Use sum types for meaningful alternatives and GADTs, associated types, indexed states, or refinements when they prevent a concrete mistake or clarify a protocol. Explain the obligation they enforce and their limits.
- Keep units and authority visible: elapsed time versus a timestamp, requested movement versus resolved movement, player action versus external completion.

Each safety claim names its mechanism: representation, abstraction boundary, runtime validation, property test, proof tool, or environmental assumption. A semantic name alone is not evidence.
Apply the [finding and prevention ledger](failure-prevention.md) when a review or playtest discovers a bug; distinguish one-case regression from a reusable boundary check.

## Reduce what must be held in mind

A function should have one explainable job at one level of abstraction. Name important intermediate facts, keep state evolution visible, and separate a rule decision from formatting or IO. Prefer a direct `case` or `do` sequence when a dense combinator expression hides the decision order.

Extract a helper when it gives a domain concept a useful name, isolates an invariant, or removes a repeated decision. Do not extract every expression into a one-use trampoline. Avoid both giant rule functions and a maze of tiny helpers that require constant jumping.

Length and nesting are review signals, not universal line limits. A well-shaped pattern match may be clearer than a shorter point-free expression. Keep public signatures explicit and names consistent across code, UI, tests, and documentation.

## Reading path for every reference game

Its README identifies, in order:

1. The player goal, controls, and an observable first interaction
2. Domain vocabulary and the smallest state/input/output boundary
3. Rule entrypoint and one complete transition explained in game terms
4. Admission/observation boundaries, if used
5. Shell, renderer, clock, and persistence responsibilities
6. How to run, test, and change one small rule

A source-code reader should not need the editor extension, an LLM, or private background context.

## Review rubric

Score each dimension 0 (obscured or missing), 1 (usable with explanation), or 2 (clear in the artifact):

| Dimension | Evidence for 2 |
| --- | --- |
| Domain vocabulary | Names track the game's concepts; units and authority are unambiguous |
| Type meaning | Every advanced type and wrapper has an explained benefit; guarantees are accurately scoped |
| Local reasoning | The main rule path is readable without reconstructing an unrelated subsystem |
| Function shape | Helpers express useful concepts; nesting and abstraction levels do not hide control flow |
| Boundary clarity | Pure rules, admission, observation, clock, renderer, and IO have identifiable owners |
| Failure visibility | Rejection, legal failure, partiality, and terminal behavior are discoverable |
| Example quality | A checked reading path, meaningful tests, and a change exercise agree with the code |

For an alpha reference-game designation, use 11/14 as a review trigger, not an automated quality proof; no dimension may be 0. Any false guarantee, hidden rules duplication, unchecked advertised route, private data, or incompatible asset license blocks release regardless of score.

A reviewer records two useful strengths, the three highest-impact improvements at most, and the exact files and transitions supporting the result. Preserve behavior with tests when changing readability.
