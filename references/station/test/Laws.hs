module Main (main) where

import Control.Monad (unless)
import Data.List (nub)
import Game.Arena (Attempt (..), attempt, nobody, observe, play, singleton)
import Game.Transition (Step (..), Divergence (..), firstDivergence)
import qualified Station.Domain as Domain
import Station.Adapter
import System.Exit (exitFailure)

check :: String -> Bool -> IO ()
check label ok = unless ok (putStrLn ("FAIL " ++ label) >> exitFailure)

allChoices :: [Domain.Choice]
allChoices = [minBound .. maxBound]

-- | Enumerate the actual reachable tree, including each distinct history.
reachable :: Domain.GameState -> [Domain.GameState]
reachable game = game : case Domain.currentTurn game of
  Nothing -> []
  Just turn -> concatMap
    (\choice -> either (const []) reachable (Domain.step turn choice game)) allChoices

playTrace :: [Domain.Choice] -> Domain.GameState
          -> Either Domain.DomainError [Domain.GameState]
playTrace [] game = Right [game]
playTrace (choice : rest) game = case Domain.currentTurn game of
  Nothing -> Left Domain.GameFinished
  Just turn -> do
    next <- Domain.step turn choice game
    (game :) <$> playTrace rest next

matchesProjection :: Domain.GameState -> Domain.TurnId -> Domain.ChoiceOption -> Bool
matchesProjection game turn option =
  case Domain.optionResult option of
    Left problem -> Domain.step turn (Domain.optionChoice option) game == Left problem
    Right resources -> fmap Domain.stats (Domain.step turn (Domain.optionChoice option) game)
      == Right resources

main :: IO ()
main = do
  let start = Domain.initialGame
      states = reachable start
      attempts = [(game, turn, choice, Domain.step turn choice game)
                 | game <- states, Just turn <- [Domain.currentTurn game], choice <- allChoices]
      terminals = filter ((== Nothing) . Domain.currentTurn) states
  check "six fixed orders and initial resources" $
    Domain.totalTurns == 6 && length Domain.allOrders == 6
      && Domain.stats start == Domain.Stats 8 3 0
  check "independent finite state/attempt/terminal counts" $
    (length states, length attempts, length terminals) == (864, 969, 541)
      && length states == length (nub states)
  check "all three ending counts" $
    [length (filter ((== Just result) . Domain.ending) terminals)
      | result <- [Domain.SunsetMaster, Domain.KindDay, Domain.LettersTomorrow]]
      == [17, 287, 237]
  check "reachable resources, bounded chronology and terminal scope" $
    all (\game -> let resources = Domain.stats game
                      count = Domain.completedTurns game
                      records = Domain.history game
      in Domain.energy resources >= 0 && Domain.energy resources <= 8
         && Domain.expressTickets resources >= 0 && Domain.expressTickets resources <= 3
         && Domain.deliveredFeelings resources >= 0
         && length records == count && count <= 6
         && map (Domain.turnNumber . Domain.deliveryTurn) records == [1 .. count]
         && (Domain.currentTurn game == Nothing) == (count == 6)
         && (Domain.ending game /= Nothing) == (count == 6)) states
  check "screen options agree with the authoritative rule at every reachable turn" $
    all (\game -> case Domain.currentTurn game of
      Nothing -> null (Domain.choices game)
      Just turn -> all (matchesProjection game turn) (Domain.choices game)) states
  let goldenChoices = [Domain.Local, Domain.Local, Domain.Express,
                       Domain.Defer, Domain.Express, Domain.Express]
      goldenStats = [Domain.Stats 8 3 0, Domain.Stats 7 3 1,
                     Domain.Stats 6 3 3, Domain.Stats 4 2 8,
                     Domain.Stats 5 2 8, Domain.Stats 3 1 14,
                     Domain.Stats 0 0 21]
  case playTrace goldenChoices start of
    Left _ -> check "hand-calculated winning trace exists" False
    Right path -> check "hand-calculated resources and ending" $
      map Domain.stats path == goldenStats
        && case reverse path of
          final : _ -> Domain.ending final == Just Domain.SunsetMaster
          _ -> False
  check "Step and Arena retain every direct success or in-world error" $
    all (\(game, turn, choice, direct) ->
      let command = Dispatch turn choice
          expected = case direct of
            Left problem -> (game, [Refused problem])
            Right next -> (next, [Accepted (Domain.stats next)])
      in runStep stationStep command game == expected
         && play StationArena () (singleton LocalClerk command) game == Right expected)
      attempts
  check "protocol rejection leaves the state untouched" $
    attempt StationArena () nobody start == Rejected WrongParticipants start
  check "a replayed turn token is refused after success" $
    case Domain.currentTurn start of
      Nothing -> False
      Just firstTurn -> case Domain.step firstTurn Domain.Local start of
        Left _ -> False
        Right next -> case runStep stationStep (Dispatch firstTurn Domain.Local) next of
          (same, [Refused (Domain.StaleTurn _ received)]) ->
            same == next && received == firstTurn
          _ -> False
  check "the view contains only projections, including available choices" $
    let view = observe StationArena LocalClerk start
    in viewTurn view == Domain.currentTurn start
       && viewResources view == Domain.stats start
       && viewOptions view == Domain.choices start
  let ignoreDispatch = Step $ \_ game -> (game, [] :: [Outcome])
  check "deleting a dispatch rule diverges on the first accepted turn" $
    case Domain.currentTurn start of
      Nothing -> False
      Just turn -> fmap boundaryIndex
        (firstDivergence stationStep ignoreDispatch [Dispatch turn Domain.Local] start) == Just 0
  putStrLn "station-laws: PASS (864 states, 969 attempts, 541 terminals, three endings, Step/Arena, stale token, mutation)"
