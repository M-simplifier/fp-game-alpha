# Readable Haskell for references and new games

The reference games teach by being worth reading. Keep advanced types where they express a real distinction, and give that distinction a name the reader can connect to the game.

## Semantic names without imaginary guarantees

- Use a `type` alias to name a recurring meaning or simplify a distracting signature. It is the same underlying type and adds no type safety or validation.
- Use a `newtype` when accidental interchange is a real risk. A `newtype Health = Health Int` separates a type; it does not establish a nonnegative bound.
- Use a private constructor and checked construction when an invariant must hold. Review all construction paths and exported operations, including parsers, derived instances, lenses, and coercion/role exposure where relevant.
- A hidden record constructor is insufficient if an exported selector still permits record update. Compile an outside-client rejection fixture for an API that promises read-only access; export ordinary projection functions when update fields must stay private.
- When decoding external numeric text into a bounded type, parse as unbounded `Integer`, validate the original value against the domain bounds, then narrow to `Int`. `readMaybe :: String -> Maybe Int` can wrap a huge literal before a later range check. Keep positive/negative overflow and state-preservation regressions; the foundation’s `research/live-tuning` experiment records the discovered bug and repair. Pure functions and private constructors alone did not prevent it.
- Validate bounds before overflow-sensitive arithmetic. For a checked width `size <= limit`, test `position <= limit - size` rather than trusting `position + size <= limit` on bounded `Int`. Test extreme machine values at external input boundaries.
- Use sum types for meaningful alternatives and GADTs, associated types, indexed states, or refinements when they prevent a concrete mistake or clarify a protocol. Explain the obligation they enforce and their limits.
- Keep units and authority visible: elapsed time versus a timestamp, requested movement versus resolved movement, player action versus external completion.

Each safety claim names its mechanism: representation, abstraction boundary, runtime validation, property test, proof tool, or environmental assumption. A semantic name alone is not evidence.
Use the relevant [prevention lessons](failure-prevention.md) when they fit a change; distinguish a one-case regression from a reusable boundary check.

## Reduce what must be held in mind

A function should have one explainable job at one level of abstraction. Name important intermediate facts, keep state evolution visible, and separate a rule decision from formatting or IO. Prefer a direct `case` or `do` sequence when a dense combinator expression hides the decision order.

Extract a helper when it gives a domain concept a useful name, isolates an invariant, or removes a repeated decision. Do not extract every expression into a one-use trampoline. Avoid both giant rule functions and a maze of tiny helpers that require constant jumping.

When a transition uses the closing state to calculate a night, round or turn,
then applies the next state's conditions, name the values at that boundary.
River's overnight revision keeps closing-day weather visible beside drying
and the report, then applies morning rain to the result. Local bindings suffice;
a simple one-update rule needs no
staged pipeline. The names describe dependencies, not imperative evaluation order.

When constructing a wide record with several same-typed fields, use its existing
field names so a reader can pair each value with its role without counting
constructor arguments. Keep private fields private; named construction adds no
validation. A small, clear pair does not need a new record or wrapper.

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

## Review the changed path

For a meaningful rule or API change, follow one affected input through its
public entrypoint, state decision, result and test. Check the names, units,
state ownership, branching, failure behavior and abstraction boundaries that
matter to that path. Keep advanced types when their benefit is concrete.

Report actionable findings with the relevant file or transition. There is no
point score, required number of strengths, or mandatory report for a mechanical
edit. Select behavior checks in proportion to what changed; formatting is not
behavioral evidence. False guarantees, duplicated authoritative rules, private
data and incompatible asset licenses still need correction before release.

## Reusable readability lessons

Concrete lessons from Paper Circuit's readability revision:

- Positional state fields and a Boolean carrying a domain alternative made the
  Undo rule hard to read. Named current/previous positions and Available/Spent
  expose the decision. Use this when names distinguish real roles; do not wrap
  every primitive or replace an already clear local pair mechanically.
- An Undo snapshot contains the board and move budget, while one-use availability
  lives outside it. Choose snapshot contents from the game's actual undo rules;
  copying the entire world could restore a permission this game should spend.
- The public dispatcher names restart, undo and rotation. Each helper keeps its
  guard, lookup, state update and reported outcome in an inspectable order.
  Preserve useful type classes and composition; avoid one-use helper mazes.
- Record which observations and boundary cases stayed equivalent, and which
  diagnostic representations changed. Formatting or a reviewer score alone is
  not behavioral evidence or proof that beginners understand the result.

When a refactor needs explanation, identify the reading difficulty, why the
change helps, its behavior checks and any tradeoff. Add guidance only for a
reusable lesson, with its conditions; an ordinary task need not update this guide.
Do not claim better generated-code quality from one example. Keep
human intent → AI reasoning → repeatable tools in that order: these criteria help
an AI choose an architecture, not force every game into the example's structure.

## Deeper implementation practice

For error ADTs, totality, effects/cancellation, abstraction choice and lazy-space
behavior, read [technique choices](practice/haskell/technique-choices.md).
For independent models, generators, shrinking and resource/codec checks, read
[verification and review](practice/haskell/verification-review.md).
