# Station: separating player-input parsing from dispatch

When the player sends `act 1 local`, the headless process now names three
steps: decode the command, dispatch it at the visible turn, and format its
outcome. Previously these decisions were nested inside `respond`.
The first delivery still leaves 7 energy, 3 tickets and 1 delivered feeling,
and the same commands produce the same player packets.

This bounded pilot changes [the player transport](../../references/station/app/HeadlessMain.hs),
not the rules or public API. The comparison baseline is public commit
`2487f7b31f75af65fa430123efbc4b67ca883b93`. Readability conclusions below are
the refactor author's assessment; no independent beginner comprehension or
human play study was conducted. The generation suggestions are candidates
for later use and evaluation, not demonstrated learning transfer.

## Follow one player action

Read [the Station overview](../../references/station/README.md), then follow
this path for `act 1 local` from the initial state:

| Stage | What happens |
| --- | --- |
| `main` / `respond` | The IO loop reads a line; the pure responder receives it and the current `GameState`. |
| `parseCommand` | `words`, `readMaybe :: String -> Maybe Integer`, and `parseChoice` decode `Act 1 Local`. No game state is consulted. |
| `dispatchVisibleTurn` | The requested number is compared with `turnNumber` of the currently visible opaque token. Only that token is placed in `Dispatch`. |
| [Arena admission](../../references/station/src/Station/Adapter.hs) | `StationArena` accepts the singleton `LocalClerk` submission. It does not decide affordability. |
| [Domain transition](../../references/station/src/Station/Domain.hs) | `step` checks completion, token freshness, then `applyCost` checks energy before tickets. Local delivery costs 1 energy and adds the first order's local value, 1. A chronological `Delivery` is appended. |
| Adapter outcome | `stationStep` emits `Accepted (Stats 7 3 1)`. An in-world failure instead emits `Refused` and preserves the original state. |
| `respond` / `packet` / `main` | The new state supplies the second order and its options; the packet has `result = "accepted"` and `turn = 2`. The IO loop prints it and continues with that state. |

`choices` and `step` already share `choiceCost` and `applyCost`. A displayed
option therefore uses the authoritative resource calculation. `ending` is
available only after all six accepted choices; scores of at least 20 and 12
select `SunsetMaster` and `KindDay`, with `LettersTomorrow` otherwise.
Express uses the order's energy cost and one ticket for its express value;
Local costs one energy for the local value. Defer adds no score and recovers
one energy, capped at 8.

There are two distinct stale-input paths. A stale *number* in the player
protocol is refused before Arena execution. A previously obtained `TurnId`
sent directly through the adapter is admitted and refused by the domain.
The refactor preserves both paths.

## The concrete reader difficulty and change

The old `respond` asked the reader to keep input syntax, turn resolution,
participant admission, domain outcomes, and JSON construction in mind at once.
Here is its complete decision body before the refactor:

```haskell
respond command game = case words command of
  ["observe"] -> (game, packet "observed" "" "none" game)
  ["act", revision, action] -> case (readMaybe revision :: Maybe Integer, parseChoice action) of
    (Just requested, Just choice) -> case D.currentTurn game of
      Nothing -> refused "The episode has ended."
      Just turn
        | requested /= toInteger (D.turnNumber turn) -> refused "Stale turn; observe again."
        | otherwise -> case play StationArena () (singleton LocalClerk (Dispatch turn choice)) game of
            Left _ -> refused "Participant admission failed."
            Right (next, outcomes) -> case outcomes of
              [Refused problem] -> (game, packet "refused" (T.unpack (D.domainErrorText problem)) "domain" game)
              [Accepted _] -> (next, packet "accepted" "" "none" next)
              _ -> refused "Unexpected domain feedback."
    _ -> refused "Expected act <visible-turn> express|local|defer."
  _ -> refused "Expected observe or act <visible-turn> express|local|defer."
  where
    refused message = (game, packet "refused" message "protocol" game)
```

The same body now reads:

```haskell
respond command game = case parseCommand command of
  Left message -> refused message
  Right Observe -> (game, packet "observed" "" "none" game)
  Right (Act requested choice) -> case dispatchVisibleTurn requested choice game of
    Left message -> refused message
    Right (_, [Refused problem]) -> (game, packet "refused" (T.unpack (D.domainErrorText problem)) "domain" game)
    Right (next, [Accepted _]) -> (next, packet "accepted" "" "none" next)
    Right _ -> refused "Unexpected domain feedback."
  where
    refused message = (game, packet "refused" message "protocol" game)
```

Two helpers earn their names by separating decisions. `parseCommand` answers
whether the line describes `Observe` or `Act Integer D.Choice` and preserves
the two existing syntax-error messages. `dispatchVisibleTurn` answers whether
the requested turn can be submitted and calls the original Arena.
`respond` can then show, together, which failures keep `game` and which
success replaces it with `next`. Each helper remains a direct pattern match;
there is no new effect abstraction or chain of forwarding helpers.

For example, `act nope local` still reports the action-syntax error even
after the episode ends. Moving completion validation ahead of decoding would
change that reply. The added negative test passes on the baseline as well as
the refactor and checks complete packets for malformed and stale input in
both the initial and terminal states.

## Choices deliberately retained

- The domain and adapter are already economical: named game concepts, one
  authoritative transition, shared option calculations, and explicit failure
  outputs. Splitting them further would add navigation without a demonstrated
  reader benefit.
- `GameState` and `TurnId` constructors remain private. `Stats` is a public
  projection, and updating it cannot update an authoritative game. The new
  `Command` is decoded transport data, not a freshness guarantee.
- The requested turn remains an unbounded `Integer`; converting it to `Int`
  could make oversized input wrap before comparison. `words` and `readMaybe`
  retain their existing grammar.
- The JSON encoder, field order, feedback text, fallback branches and
  `[Outcome]` protocol remain unchanged. Transport errors still use presentation
  strings; domain errors retain their ADT. No dependencies, formatter setup,
  gameplay constants, independent oracles, or public signatures changed.

## Refinements to generation guidance

These specialize [the existing helper and boundary guidance](../../docs/haskell.md)
rather than introduce universal function-size limits.

| Candidate | Activation condition and concrete action | Exception or limit |
| --- | --- | --- |
| Name the decoding stage before state-dependent decisions. | A responder nests wire syntax together with game execution. Decode a small command sum, then keep success/refusal state handling together. | A short single-stage match may already be clear. Do not create a helper for every expression or an ADT for every intermediate value. |
| Keep a requested revision separate from an authoritative token. | A client sends a number while the domain owns an opaque token. Compare the number without bounded conversion and acquire the token only through the existing projection. | Games without this protocol need no revision machinery. The domain must still reject stale tokens; naming decoded input does not confer authority. |
| Verify the ordering where branches are moved. | A readability edit separates validation stages. Test overlapping failures, such as malformed input after completion, and compare the actual consumer's replies with the baseline. | Finite coverage is scoped to the current game. Packet equality does not establish beginner comprehension, human enjoyment, or compatibility of source-pinned journals. |

## Verification and limits

Commands were run with GHC 9.6.7, Cabal 3.12.1.0 and Python 3.14.2.
The baseline passed all eight root Cabal suites, Station's public API fixtures,
all eight existing headless tests, publication checks and documentation lint.
The new validation-order regression was also run against the unchanged source
before refactoring. There were no baseline test failures; Cabal's warning about
no remote package servers is expected for the offline profile.

After the source change, these checks passed:

| Command | Observed result |
| --- | --- |
| `python tools/fp_game.py build` | All root targets build with the package warning policy. |
| `python tools/fp_game.py test` | All eight suites pass, including Station's 864 states, 969 attempts, 541 terminals, ending counts and hand-calculated resource trace. |
| `python tools/test_station_api.py` | Read-only client compiles; external state update and turn-token forgery are rejected for the intended reasons. |
| `python tools/test_play.py` | All nine tests pass, including the new failure-order test. Existing replay, retry, oversized-number, locking and journal-budget checks remain unchanged. |
| `python research/readability/compare_station.py BASELINE_BINARY CURRENT_BINARY` | 1,510 cases and 34,752 byte-identical packets over all 864 histories, 969 current-turn choices and 541 terminal histories. |
| `python tools/docs_lint.py` | All 436 foundation and 57 rendered-game documents pass the link, skill and support checks. |
| `python tools/publication.py snapshot` then `python tools/publication.py check` | The derived manifest is refreshed and all 454 selected files pass. All existing origins, licenses, maturity and review dispositions are preserved; only four current hashes and two new research entries change. |

The [packet comparator](compare_station.py) takes binaries compiled from the
baseline and current source. It grows the reachable history tree only from
baseline-accepted actions, exercises every current-turn choice, and interleaves
observation, malformed syntax, stale/oversized numbers, immediate retries and
terminal attempts. It compares raw stdout bytes, including JSON field order
and feedback, rather than updating a golden file from the new implementation.
Both binaries use the existing `tools/play.py` GHC build route.

```sh
python research/readability/compare_station.py BASELINE_BINARY CURRENT_BINARY
```

`tools/play.py` intentionally pins journals to the source fingerprint. This
source edit therefore requires a new journal under that existing guard; no
old fingerprint was rewritten. Station's unpublished JSON save/asynchronous
UI paths, browser operation, independent beginner comprehension and learning
transfer remain unverified. This pilot does not claim a universal game generator
or restrict supported briefs to Station's finite structure.
