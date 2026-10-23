module River.Protocol (checks) where

import Data.List (foldl')
import Game.Arena (Attempt (..), attempt, nobody, observe, play, singleton)
import Game.Transition (Divergence (..), Step (..), firstDivergence, replay)
import Life.Adapter
import Life.Clock qualified as Clock
import Life.Domain qualified as Domain

checks :: [(String, Bool)]
checks =
  [ ( "Step uses the original game transition and chronological effects",
      fst direct == Domain.runCommands commands start && arenaReplay commands start == Right direct
    ),
    ( "interaction and tick boundaries cannot be confused",
      attempt RiverArena InteractionBoundary (singleton Villager (Domain.Tick 0 0)) start == Rejected WrongBoundary start
        && attempt RiverArena MovementTick (singleton Villager Domain.Interact) start == Rejected WrongParticipants start
        && play RiverArena MovementTick nobody start == Right (Domain.advance (Domain.Tick 0 0) start)
    ),
    ( "view is disposable and derived from authoritative state",
      viewPosition (observe RiverArena Villager start) == Domain.playerPosition start
        && viewBuildSelection (observe RiverArena Villager (fst (Domain.advance (Domain.ChooseBuild Domain.Seat) start))) == Domain.Seat
    ),
    ( "bad construction is an admitted in-world no-op",
      fst (Domain.advance (Domain.BuildAt (Domain.Cell 2000 2000)) start) == start
        && play RiverArena InteractionBoundary (singleton Villager (Domain.BuildAt (Domain.Cell 2000 2000))) start
          == Right (Domain.advance (Domain.BuildAt (Domain.Cell 2000 2000)) start)
    ),
    ( "deleting a build-selection rule is detected at its boundary",
      let dropChoice = Step $ \command game -> case command of
            Domain.ChooseBuild _ -> (game, [])
            _ -> Domain.advance command game
       in fmap boundaryIndex (firstDivergence riverStep dropChoice [Domain.ChooseBuild Domain.Seat] start) == Just 0
    ),
    ( "fixed scheduler caps eight ticks and retains exact debt",
      let (firstTicks, debt) = Clock.schedule (12 * 33333) Clock.initialClock
          (laterTicks, cleared) = Clock.schedule 0 debt
       in firstTicks == 8
            && laterTicks == 4
            && Clock.debtMicros cleared == 0
            && Clock.schedule (-1) Clock.initialClock == (0, Clock.initialClock)
            && Clock.clearClock debt == Clock.initialClock
    )
  ]
  where
    start = Domain.initialGame
    commands = [Domain.Tick 0 0, Domain.ChooseBuild Domain.Roof, Domain.BuildAt (Domain.Cell 8 5), Domain.Interact, Domain.Tick 1 0, Domain.RemoveAt (Domain.Cell 8 5)]
    direct = replay riverStep commands start

arenaReplay :: [Domain.Command] -> Domain.Game -> Either ProtocolError (Domain.Game, [Domain.Effect])
arenaReplay commands start = foldl' apply (Right (start, [])) commands
  where
    apply previous command = do
      (game, effects) <- previous
      let (boundary, actions) = splitCommand command
      (next, emitted) <- play RiverArena boundary actions game
      pure (next, effects ++ emitted)
