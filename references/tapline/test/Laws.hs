module Main (main) where

import Control.Monad (unless)
import Data.List (foldl', nub)
import Game.Arena (observe, play)
import Game.Transition (Step (..), Divergence (..), firstDivergence, replay)
import System.Exit (exitFailure)
import Tapline.Adapter
import qualified Tapline.Clock as Clock
import qualified Tapline.Domain as Game
import qualified Tapline.Input as Input
import qualified Tapline.View as View

check :: String -> Bool -> IO ()
check label ok = unless ok (putStrLn ("FAIL " ++ label) >> exitFailure)

frameAt :: Integer -> [Input.Command] -> Game.Frame
frameAt micros = Game.Frame (Clock.stamp micros) True

arenaReplay :: [Game.Frame] -> Game.Session
            -> Either ProtocolError (Game.Session, [Game.Effect])
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
      frames = zipWith frameAt [0,900000..5400000]
        [[Input.TogglePause,Input.Tap Input.J,Input.Tap Input.K],
         [Input.Tap Input.K,Input.Tap Input.J],
         [Input.Tap Input.J,Input.Tap Input.J,Input.Tap Input.K],
         [Input.Tap Input.K,Input.Tap Input.K,Input.Tap Input.J],
         [Input.Tap Input.J,Input.Tap Input.K,Input.Tap Input.K,Input.Tap Input.J],
         [Input.Tap Input.K,Input.Tap Input.J,Input.Tap Input.K,Input.Tap Input.J,Input.Tap Input.K],
         []]
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
  let (expired, _) = Game.replay
        [frameAt 0 [Input.TogglePause], frameAt Game.roundBudget [Input.Tap Input.J,Input.Tap Input.K]] start
  check "exact deadline settles before same-frame taps" $
    map Game.outcome (Game.results expired) == [Game.Expired]
  let wholeReset = [frameAt 0 [Input.Reset,Input.TogglePause,Input.Tap Input.J,Input.Tap Input.K]]
      splitReset = [frameAt 0 [Input.Reset],frameAt 0 [Input.TogglePause,Input.Tap Input.J,Input.Tap Input.K]]
  check "reset makes splitting inside a frame a non-law" $
    Game.replay wholeReset start /= Game.replay splitReset start
  check "command permutation is a non-law" $
    Game.replay [frameAt 0 [Input.TogglePause,Input.Tap Input.J,Input.Tap Input.K]] start /=
      Game.replay [frameAt 0 [Input.TogglePause,Input.Tap Input.K,Input.Tap Input.J]] start
  let (playing, _) = Game.frame (frameAt 0 [Input.TogglePause]) start
      (lostFocus, lostEffects) = Game.frame
        (Game.Frame (Clock.stamp 1000000) False [Input.Tap Input.J]) playing
      (stillPaused, _) = Game.frame (frameAt 8000000 []) lostFocus
      (resumed, _) = Game.frame (frameAt 8000000 [Input.TogglePause]) stillPaused
      (cleared, _) = Game.frame (frameAt 8000000 [Input.Tap Input.J,Input.Tap Input.K]) resumed
  check "focus loss discards input and pauses active time" $
    Game.isPaused lostFocus && Game.activeMicros stillPaused == 0
      && lostEffects == [Game.FocusLost,Game.Paused,Game.BatchDiscarded 1]
      && map Game.outcome (Game.results cleared) == [Game.Success]
  putStrLn "tapline-laws: PASS (six rounds, Step/Arena, deadline, reset, order, focus, mutation)"
