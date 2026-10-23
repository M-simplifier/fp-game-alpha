module Main (main) where

import Control.Monad (unless)
import Data.List (foldl', nub)
import Game.Arena (observe, play)
import Game.Transition (Divergence (..), Step (..), firstDivergence, replay)
import System.Exit (exitFailure)
import Tapline.Adapter
import Tapline.Clock qualified as Clock
import Tapline.Domain qualified as Game
import Tapline.Input qualified as Input
import Tapline.View qualified as View

check :: String -> Bool -> IO ()
check label ok = unless ok (putStrLn ("FAIL " ++ label) >> exitFailure)

frameAt :: Integer -> [Input.Command] -> Game.Frame
frameAt micros = Game.Frame (Clock.stamp micros) True

arenaReplay ::
  [Game.Frame] ->
  Game.Session ->
  Either ProtocolError (Game.Session, [Game.Effect])
arenaReplay inputs start = foldl' advance (Right (start, [])) inputs
  where
    advance previous input = do
      (session, priorEffects) <- previous
      let (context, actions) = splitTapline input
      (next, newEffects) <- play TaplineArena context actions session
      pure (next, priorEffects ++ newEffects)

main :: IO ()
main = do
  let start = Game.initial (Clock.stamp 0)
      frames =
        zipWith
          frameAt
          [0, 900000 .. 5400000]
          [ [Input.TogglePause, Input.Tap Input.J, Input.Tap Input.K],
            [Input.Tap Input.K, Input.Tap Input.J],
            [Input.Tap Input.J, Input.Tap Input.J, Input.Tap Input.K],
            [Input.Tap Input.K, Input.Tap Input.K, Input.Tap Input.J],
            [Input.Tap Input.J, Input.Tap Input.K, Input.Tap Input.K, Input.Tap Input.J],
            [Input.Tap Input.K, Input.Tap Input.J, Input.Tap Input.K, Input.Tap Input.J, Input.Tap Input.K],
            []
          ]
      (finished, effects) = Game.replay frames start
  check "six original rounds complete" $
    Game.phase finished == Game.Complete
      && map Game.outcome (Game.results finished) == replicate 6 Game.Success
  check "Step replays the authoritative rule" $
    replay tapline frames start == (finished, effects)
  check "Arena admits whole batches without changing the rule" $
    arenaReplay frames start == Right (finished, effects)
  check "observation is a pure projection" $
    observe TaplineArena LocalPlayer finished == View.project finished
      && View.successCount (View.project finished) == 6
  let dropRepeated = Step $ \input session ->
        Game.frame input {Game.commands = nub (Game.commands input)} session
  check "mutation detects lost duplicate key at frame two" $
    fmap boundaryIndex (firstDivergence tapline dropRepeated frames start) == Just 2
  check "character parser retains repeated taps" $
    Input.commandsFromChars "jj" == [Input.Tap Input.J, Input.Tap Input.J]
  let (expired, _) =
        Game.replay
          [frameAt 0 [Input.TogglePause], frameAt Game.roundBudget [Input.Tap Input.J, Input.Tap Input.K]]
          start
  check "exact deadline settles before same-frame taps" $
    map Game.outcome (Game.results expired) == [Game.Expired]
  check "deadline refusal leaves no matched-key or discarded-batch effect" $
    snd (Game.replay [frameAt 0 [Input.TogglePause], frameAt Game.roundBudget [Input.Tap Input.J, Input.Tap Input.K]] start)
      == [Game.BeganRound 1, Game.EndedRound (Game.Result 1 Game.Expired 7000000)]
  let (overshot, elapsedEffects) = Game.replay [frameAt 0 [Input.TogglePause], frameAt 100000000 []] start
      expiries = [Game.Result number Game.Expired (7000000 + toInteger (number - 1) * 7900000) | number <- [1 .. 6]]
  check "one long frame settles each old round at its scheduled deadline" $
    Game.phase overshot == Game.Complete
      && Game.activeMicros overshot == 47400000
      && Game.results overshot == expiries
      && elapsedEffects
        == Game.BeganRound 1 : concat [[Game.EndedRound result] ++ [Game.BeganRound (Game.resultRound result + 1) | Game.resultRound result < 6] | result <- expiries]
  check "reset consumes the rest of its batch without starting a round" $
    let (reset, emitted) = Game.frame (frameAt 0 [Input.Reset, Input.TogglePause, Input.Tap Input.J]) start
     in Game.phase reset == Game.Ready
          && Game.activeMicros reset == 0
          && null (Game.results reset)
          && emitted == [Game.Restarted 1, Game.BatchDiscarded 2]
  let (_, anchored) = Clock.observe False (Clock.stamp 200) (Clock.anchor (Clock.stamp 100))
      (regressed, unchangedClock) = Clock.observe True (Clock.stamp 150) anchored
      (later, _) = Clock.observe True (Clock.stamp 250) unchangedClock
  check "resting and regressed wall readings cannot become later active debt" $
    regressed == 0 && later == 50 && Clock.micros (Clock.stamp (-1)) == 0
  let wholeReset = [frameAt 0 [Input.Reset, Input.TogglePause, Input.Tap Input.J, Input.Tap Input.K]]
      splitReset = [frameAt 0 [Input.Reset], frameAt 0 [Input.TogglePause, Input.Tap Input.J, Input.Tap Input.K]]
  check "reset makes splitting inside a frame a non-law" $
    Game.replay wholeReset start /= Game.replay splitReset start
  check "command permutation is a non-law" $
    Game.replay [frameAt 0 [Input.TogglePause, Input.Tap Input.J, Input.Tap Input.K]] start
      /= Game.replay [frameAt 0 [Input.TogglePause, Input.Tap Input.K, Input.Tap Input.J]] start
  let (playing, _) = Game.frame (frameAt 0 [Input.TogglePause]) start
      (lostFocus, lostEffects) =
        Game.frame
          (Game.Frame (Clock.stamp 1000000) False [Input.Tap Input.J])
          playing
      (stillPaused, _) = Game.frame (frameAt 8000000 []) lostFocus
      (resumed, _) = Game.frame (frameAt 8000000 [Input.TogglePause]) stillPaused
      (cleared, _) = Game.frame (frameAt 8000000 [Input.Tap Input.J, Input.Tap Input.K]) resumed
  check "focus loss discards input and pauses active time" $
    Game.isPaused lostFocus
      && Game.activeMicros stillPaused == 0
      && lostEffects == [Game.FocusLost, Game.Paused, Game.BatchDiscarded 1]
      && map Game.outcome (Game.results cleared) == [Game.Success]
  putStrLn "tapline-laws: PASS (six rounds, Step/Arena, deadline, reset, order, focus, mutation)"
