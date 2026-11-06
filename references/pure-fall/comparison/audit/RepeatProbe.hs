module Main (main) where

import PureFall.Core
import PureFall.Session
import PureFall.Time

main :: IO ()
main = do
  let heldLeft=Held Leftward False
      neutral=Held Neutral False
      initial=start (fresh Practice 15)
      (first,_) = advanceFrame (frameMicros 16667) [MoveLeft] heldLeft True initial
      (almostDue,_) = advanceFrame (frameMicros 133333) [] heldLeft True first
      (released,_) = advanceFrame (frameMicros 5000) [] neutral True almostDue
      (repressed,cues) = advanceFrame (frameMicros 11667) [MoveLeft] heldLeft True released
      expected=active (sessionGame almostDue) >>= shifted (gameBoard (sessionGame almostDue)) (-1) 0
  print ("before fresh press",active (sessionGame almostDue),"expected",expected)
  print ("actual",active (sessionGame repressed),"cues",cues,"ticks",tickCount (ticks (sessionGame repressed)))
