# Station Dispatch: finite pure game core

The player dispatches six fixed orders using `Express`, `Local`, or `Defer`.
Each choice changes energy, tickets and delivered feeling, and the final
score selects one of three endings. Start with `initialGame`, read
`currentTurn`, and submit `step turn Local initialGame`: the first local
delivery leaves 7 energy, 3 tickets and 1 delivered feeling. Reusing that
same turn token is a `StaleTurn` error and does not advance state.

Read `Station.Domain` in this order: the opaque `TurnId` and `GameState`;
`Stats` and six `Order` values; `choiceCost`/`choices` as the visible decision
table; `step` as the only authoritative transition; then `ending` and the
read-only projections. `Stats` is an ordinary public record used for
presentation. Constructing or updating a `Stats` value cannot update a
`GameState`; no public game rule accepts arbitrary `Stats` as authority.
`TurnId`'s constructor is private, but a previously visible token can still
be replayed. `step` checks the current token and available resources at each
attempt. A private constructor alone is not a freshness proof.

`Station.Adapter` wraps the original rule in `Step` and `Machine`. A
`Dispatch` pairs a turn token and choice as one input. On a domain error,
`stationStep` preserves the old state and emits `Refused`; on success it
emits `Accepted` with resulting resources. `StationArena` requires one
`LocalClerk` submission and projects a disposable `StationView`. An empty
or malformed submission is a protocol rejection; a stale token or unaffordable
service is an admitted choice with an in-world refusal. Admission does not
duplicate the game's cost rules.

Run `python tools/fp_game.py test` from the foundation root and
`python tools/test_station_api.py` for outside-client compilation. The finite
test enumerates every reachable state/history under the six fixed orders and
three choices: 864 states, 969 attempted choices and 541 terminal states.
It checks the three ending counts, a separately calculated winning resource
trace, resource/history invariants, every displayed choice against `step`,
direct Step/Arena equivalence, stale replay, and a deleted-rule mutation.
GHC compiles a read-only client and rejects both an external `GameState`
record update and a forged `TurnId` constructor for the intended reasons.
These are results for this fixed finite game and GHC 9.6.7, not a theorem for
arbitrary game changes or a measured user-experience result.

This increment publishes only the complete clock-free domain rule core.
The original strict JSON save and asynchronous storage/UI modules are
**pending**: their `aeson` dependency is absent from the maintained offline
first-user profile, and those paths have not been rebuilt and reviewed in a
public clone. No browser interaction or storage race is claimed here. They
remain explicit next acceptance work in the [roadmap](../../docs/roadmap.md).

The domain source and per-title MIT notice were selected from the author's
technical snapshot `5335bb14f9ca644fbdc62a00be892f33ad590ba6` with
original digests in the publication manifest. This edition adds the
Step/Arena adapter, finite tests, API compiler fixtures and reading path. It
does not include private Git history, artwork, a host or the unfinished save
and UI files.
