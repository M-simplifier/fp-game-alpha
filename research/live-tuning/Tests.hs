module Main (main) where

import Control.Monad (unless)
import Data.List (isInfixOf)
import Game

assert :: String -> Bool -> IO ()
assert name ok = unless ok (error name)

load :: String -> Runtime -> Runtime
load input rt = either error id (admit input rt)

main :: IO ()
main = do
  let old = move Rightward initialRuntime
      staged = load "revision 1 moveBudget 6" old
      reset = newSession staged
      rejects s = case admit s staged of Left _ -> True; Right _ -> False
  assert "current world preserved" (activeWorld staged == activeWorld old)
  assert "staged changed" (stagedConfig staged /= stagedConfig old)
  assert "restart retains session config" (activeWorld (restart staged) == activeWorld initialRuntime)
  assert "new uses staged" ("moves=6 session=r1/6" `isInfixOf` render reset)
  assert "six moves win at zero" ("WON | moves=0" `isInfixOf` render (iterate (move Rightward) reset !! 6))
  let short = newSession (load "revision 2 moveBudget 5" staged)
      lost = iterate (move Rightward) short !! 5
  assert "five moves loses" ("OUT OF MOVES" `isInfixOf` render lost)
  assert "terminal input refused" (move Rightward lost == lost)
  assert "boundary does not consume move" (move Leftward reset == reset)
  assert "stale and duplicate revisions refused" (all rejects ["revision 1 moveBudget 9", "revision 0 moveBudget 8"])
  assert "bad input refused" (all rejects ["", "revision 2", "revision 2 moveBudget 0", "revision 2 moveBudget 31", "revision 2 moveBudget -1", "revision 2 moveBudget 6 extra", "revision 9999999999 moveBudget 6", "revision 2 moveBudget 6.0", replicate 130 '9'])
  let apply input rt = either (const rt) id (admit input rt)
  assert "rejection atomic" (apply "revision 2 moveBudget 99" staged == staged)
  let overflows = ["18446744073709551622", "-18446744073709551610", "4294967302", "-4294967290", replicate 80 '9']
  assert "unbounded budget rejected before narrowing" (all (\n -> rejects ("revision 2 moveBudget " ++ n)) overflows)
  assert "overflow failure preserves complete runtime" (all (\n -> apply ("revision 2 moveBudget " ++ n) staged == staged) overflows)
  putStrLn "PASS: 13 checks; atomic rejection, freshness, preserved current/restart, next-session adoption, win/loss and refused input"
