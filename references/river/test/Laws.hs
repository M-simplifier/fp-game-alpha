{-# LANGUAGE OverloadedStrings #-}
module Main (main) where

import Control.Monad (unless)
import Data.List (foldl')
import qualified Data.Text as Text
import Game.Arena (Attempt (..), attempt, nobody, observe, play, singleton)
import Game.Transition (Step (..), Divergence (..), firstDivergence, replay)
import qualified Life.Clock as Clock
import Life.Adapter
import qualified Life.Domain as Domain
import System.Exit (exitFailure)

check :: String -> Bool -> IO ()
check label ok = unless ok (putStrLn ("FAIL " ++ label) >> exitFailure)

arenaReplay :: [Domain.Command] -> Domain.Game
            -> Either ProtocolError (Domain.Game, [Domain.Effect])
arenaReplay commands start = foldl' apply (Right (start, [])) commands
  where
    apply previous command = do
      (game, effects) <- previous
      let (boundary, actions) = splitCommand command
      (next, emitted) <- play RiverArena boundary actions game
      pure (next, effects ++ emitted)

main :: IO ()
main = do
  let start = Domain.initialGame
      dayOne = Domain.scenarioGame Domain.DayOne
      dayTwo = Domain.scenarioGame Domain.DayTwo
      dayThree = Domain.scenarioGame Domain.DayThree
      complete = Domain.scenarioGame Domain.AfterDinner
      scenes = [start, dayOne, dayTwo, dayThree, complete]
  check "authored journey reaches each valid day and dinner" $
    map Domain.dayNumber scenes == [1,1,2,3,3]
      && Domain.weather dayTwo == Domain.Rainy
      && Domain.dinnerStatus complete == Domain.DinnerShared
      && all (null . Domain.invariantErrors) scenes
  check "roof changes an overnight crop without changing its neighbor" $
    Domain.cropStageAt (Domain.Cell 8 5) dayThree == Just Domain.Sprouting
      && Domain.cropStageAt (Domain.Cell 9 5) dayThree == Just Domain.Ripe
      && Domain.woodDrynessAt (Domain.Cell 7 9) dayThree == Just 100
      && Domain.woodDrynessAt (Domain.Cell 8 9) dayThree == Just 62
  check "overnight report persists after later roof edits" $
    let edited = fst (Domain.advance (Domain.RemoveAt (Domain.Cell 7 9))
                   (Domain.walkToCell (Domain.Cell 7 9) dayThree))
    in Domain.lastNightReport edited == Domain.lastNightReport dayThree
       && fmap Domain.lastNightReport (Domain.decodeGame (Domain.encodeGame edited))
          == Right (Domain.lastNightReport dayThree)
  check "save restores every scenario and its immediate observation" $
    all (\game -> Domain.decodeGame (Domain.encodeGame game) == Right game
      && fmap (observe RiverArena Villager) (Domain.decodeGame (Domain.encodeGame game))
           == Right (observe RiverArena Villager game)) scenes
  check "save rejects malformed, oversized and wrong-version input" $
    Domain.decodeGame "nonsense" == Left Domain.SaveMalformed
      && Domain.decodeGame (Text.replicate 65537 "x") == Left Domain.SaveTooLarge
      && Domain.decodeGame (Text.replace "rVersion = 1" "rVersion = 9"
           (Domain.encodeGame start)) == Left (Domain.SaveVersionUnsupported 9)
  check "save rejects invalid numeric and cross-field states" $
    let encoded = Domain.encodeGame start
        altered old new = Domain.decodeGame (Text.replace old new encoded)
    in all isRejected
         [ altered "rX = 450" "rX = -1"
         , altered "rDay = 1" "rDay = 0"
         , altered "rDay = 1" "rDay = 18446744073709551617"
         , altered "rTicks = 0" "rTicks = 10801"
         , altered "rRoofs = []" "rRoofs = [(7,9),(7,9)]"
         , altered "rBeds = [(8,5,0,False)" "rBeds = [(8,5,0,True)"
         ]
  check "save continuation preserves state and effects" $
    all (\game -> all (\command ->
       fmap (Domain.advance command) (Domain.decodeGame (Domain.encodeGame game))
         == Right (Domain.advance command game))
      [Domain.Tick 0 0, Domain.Interact, Domain.BuildAt (Domain.Cell 2000 2000)]) scenes
  let commands = [Domain.Tick 0 0, Domain.ChooseBuild Domain.Roof,
                  Domain.BuildAt (Domain.Cell 8 5), Domain.Interact,
                  Domain.Tick 1 0, Domain.RemoveAt (Domain.Cell 8 5)]
      direct = replay riverStep commands start
  check "Step uses the original game transition and chronological effects" $
    fst direct == Domain.runCommands commands start
      && arenaReplay commands start == Right direct
  check "interaction and tick boundaries cannot be confused" $
    attempt RiverArena InteractionBoundary (singleton Villager (Domain.Tick 0 0)) start
      == Rejected WrongBoundary start
      && attempt RiverArena MovementTick (singleton Villager Domain.Interact) start
      == Rejected WrongParticipants start
      && play RiverArena MovementTick nobody start
         == Right (Domain.advance (Domain.Tick 0 0) start)
  check "view is disposable and derived from authoritative state" $
    viewPosition (observe RiverArena Villager start) == Domain.playerPosition start
      && viewBuildSelection (observe RiverArena Villager (fst (Domain.advance (Domain.ChooseBuild Domain.Seat) start)))
         == Domain.Seat
  check "bad construction is an admitted in-world no-op" $
    fst (Domain.advance (Domain.BuildAt (Domain.Cell 2000 2000)) start) == start
      && play RiverArena InteractionBoundary
         (singleton Villager (Domain.BuildAt (Domain.Cell 2000 2000))) start
         == Right (Domain.advance (Domain.BuildAt (Domain.Cell 2000 2000)) start)
  check "tick controls saturate before arithmetic" $
    Domain.advance (Domain.Tick maxBound minBound) start
      == Domain.advance (Domain.Tick 1 (-1)) start
  check "repeated logical ticks are not deduplicated" $
    Domain.dayTicks (Domain.runCommands [Domain.Tick 0 0, Domain.Tick 0 0] start)
      == Domain.dayTicks (fst (Domain.advance (Domain.Tick 0 0) start)) + 1
  check "finite command prefixes preserve the state invariant" $
    let path = concatMap (replicate 80)
          [Domain.Tick 0 (-1), Domain.Tick (-1) 0,
           Domain.Tick 0 1, Domain.Tick 1 0]
    in all (null . Domain.invariantErrors)
         (scanl (\game command -> fst (Domain.advance command game)) start path)
  let dropChoice = Step $ \command game -> case command of
        Domain.ChooseBuild _ -> (game, [])
        _ -> Domain.advance command game
  check "deleting a build-selection rule is detected at its boundary" $
    fmap boundaryIndex (firstDivergence riverStep dropChoice
      [Domain.ChooseBuild Domain.Seat] start) == Just 0
  let (firstTicks, debt) = Clock.schedule (12 * 33333) Clock.initialClock
      (laterTicks, cleared) = Clock.schedule 0 debt
  check "fixed scheduler caps eight ticks and retains exact debt" $
    firstTicks == 8 && laterTicks == 4 && Clock.debtMicros cleared == 0
      && Clock.schedule (-1) Clock.initialClock == (0, Clock.initialClock)
      && Clock.clearClock debt == Clock.initialClock
  putStrLn "river-laws: PASS (journey, save, Step/Arena, boundaries, tick/clock, mutation)"

isRejected :: Either Domain.SaveError Domain.Game -> Bool
isRejected (Left _) = True
isRejected (Right _) = False
