---
name: haskell-excellence
description: Design, implement and review Haskell types, invariants, errors, effects, resource lifetimes, laziness and meaningful verification in new or existing code.
---

Use [technique choices](../../../docs/practice/haskell/technique-choices.md) for
types, errors, composition, effects and evaluation. For behavioral changes or
reviews, select relevant checks from [verification and review](../../../docs/practice/haskell/verification-review.md).
Use [readability guidance](../../../docs/haskell.md) for semantic names and
cognitive load without discarding useful advanced abstractions.

Follow the current project's requirements, compiler and dependency versions.
Choose techniques by the concrete mistake prevented or composition expressed.
Check the actual public API and callers, including decode/update/instances.
Small mechanical edits do not require reading every guide or adding a harness.
Distinguish compiler rejection, tests, runtime evidence and proved properties.

For meaningful rule or API changes, review one affected transition through names,
state ownership and decisions. Report concrete issues or tradeoffs when useful;
mechanical edits need no scoring or separate review report. Promote a lesson
only when it is reusable, with the conditions under which it helps.
