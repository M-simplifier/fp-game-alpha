# Readable Haskell for references and new games

The reference games teach by being worth reading. Keep advanced types where they express a real distinction, and give that distinction a name the reader can connect to the game.

Make source the first explanation: names identify the domain, types distinguish
roles, and a transition shows admission, decisions and committed results. Do
not restate declarations or control flow in comments and parallel documents.
Keep comments for a reason, an external assumption or a non-obvious invariant.
Author a tutorial only for a specific human learning purpose, using the current
code and a concrete example; check quoted source against the implementation.

## Semantic names without imaginary guarantees

- Use a `type` alias to name a recurring meaning or simplify a distracting signature. It is the same underlying type and adds no type safety or validation.
- Use a `newtype` when accidental interchange is a real risk. A `newtype Health = Health Int` separates a type; it does not establish a nonnegative bound.
- Use a private constructor and checked construction when an invariant must hold. Review all construction paths and exported operations, including parsers, derived instances, lenses, and coercion/role exposure where relevant.
- A hidden record constructor is insufficient if an exported selector still permits record update. Compile an outside-client rejection fixture for an API that promises read-only access; export ordinary projection functions when update fields must stay private.
- When decoding external numeric text into a bounded type, parse as unbounded `Integer`, validate the original value against the domain bounds, then narrow to `Int`. `readMaybe :: String -> Maybe Int` can wrap a huge literal before a later range check. Keep positive/negative overflow and state-preservation regressions; current numeric-boundary tests must reject these inputs without changing state. Pure functions and private constructors alone did not prevent it.
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

## Write readable rules from the first slice

While implementing one real player interaction, make its decision visible in
the source before extending the game around it. Ask where a reader would change
one rule independently, and which state each calculation actually uses.

- Name independently tunable meanings separately even when their numeric values
  happen to match. Jump gravity, dash speed and flight speed do not become one
  setting because each is currently `17`. Include the unit or time basis where
  it would otherwise be ambiguous; a name is not a unit-safety guarantee.
- Distinguish requested and resolved values, and name the previous, moved or
  committed state when the choice matters. For a failed attempt, make clear what
  rolls back and what remains spent. Do not blindly copy a whole state when only
  a checkpoint or inventory transaction should be restored.
- Put competing decisions in an inspectable order. If several failures or
  effects can occur, a reader should see which wins and why. A helper should
  expose a domain decision, meaningful result or boundary, not merely move the
  same expression out of sight.
- Pair wide construction with existing field names. Keep useful ADTs, pure
  boundaries and hidden representations; readability does not require a new
  framework, a record for every pair, or less capable types.

Before continuing past that interaction, use its actual input and state to
check that the source answers: what is admitted, what is decided, what changes,
and what is observed? Then locate one plausible isolated adjustment without
changing unrelated rules. Revise only the places that require reconstruction.
This is part of implementation, not a mandatory separate report or model call.
Existing simple rules may already satisfy it without another helper or comment.

For a refactor, preserve the established ordering, arithmetic, public boundaries
and independent comparisons. Choose checks that can expose a changed priority,
rollback scope or output; formatting alone cannot. If using a model
as a reader, retain equal source context and factual questions; a subjective
verdict or fluent explanation is not the acceptance test.

## Help a reader enter the game

A README should let someone run the game and find the source for one observable
action. Keep setup constraints, controls, compatibility and useful design
rationale there; let the code describe its declarations. A reader should not
need an editor extension, an LLM or private background context.

For a guided first reading, [learn-code](learn-code.md) connects one player action
to its types, rule decision and caller. Its Station lesson is a deliberate
beginner example, not a required chapter layout for every game.

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

Paper Circuit's Undo snapshot contains the board and move budget, while one-use
availability lives outside it. Copying the whole world could restore a permission
the game should spend. Choose snapshot contents from the actual rollback rule;
names for current/previous positions and Available/Spent help expose that choice.
This is a reason to name distinct roles, not to wrap every primitive.

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
