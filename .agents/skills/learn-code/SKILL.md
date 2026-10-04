---
name: learn-code
description: Explain the user's actual Haskell game code and types to a beginner, tracing a chosen player action through rules, state, outputs and checks. Use for understanding or learning from an existing game, including games authored independently from a brief.
---

Use [the code-learning guide](../../../docs/learn-code.md). Work in the user's
actual game and current revision, including their edits; do not substitute a
reference game or regenerate the workspace. If no game was specified, identify
the current project first and ask only when the target is genuinely ambiguous.

Start with the behavior they want to understand. Read its real declarations,
implementation, callers and relevant checks before explaining. Give source
paths and symbols; quote actual types and small coherent code excerpts. A type
outline or cached explanation alone is not evidence of current behavior.
Use an existing code reader if helpful; ordinary source reading is sufficient.
Do not make installing an editor or compiling the whole game a prerequisite.

Explain one useful part immediately, assuming no Haskell experience unless the
reader says otherwise. Connect syntax to this game's values and decisions.
Separate what a type expresses, what an export boundary prevents, what runtime
branches reject, and what tests or real-host observations establish. Follow the
caller after an error instead of assuming it retains the original state.

Adapt depth to the reader's questions. Offer a small prediction, explanation in
their own words, or optional change that uses the concept. Do not turn the lesson
into a compulsory quiz, or infer understanding from silence. Teaching alone does
not authorize code edits, dependency installation or gameplay changes. If asked
to make a change, preserve unrelated edits and verify the changed behavior.

The [Station lesson](../../../docs/learn-code-station.ja.md) demonstrates this
method on pinned real code. It is a worked example, not a required game layout
or a script to recite for every project. Later sessions should resume from the
learner's actual question and changed source, not a presumed permanent level.
