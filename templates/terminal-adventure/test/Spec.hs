module Main (main) where

import Control.Monad (unless)
import Game.Adapter (Adventure (..), Player (..))
import Game.Arena qualified as Arena
import Game.Model
import Game.Rules
import Game.Save
import Game.View (render)

assert :: String -> Bool -> IO ()
assert label ok = unless ok (error label)

walk :: [Command] -> World
walk = foldl (\world command -> fst (advance command world)) initial

main :: IO ()
main = do
  let final = walk smokeCommands
      states =
        scanl
          (\world command -> fst (advance command world))
          initial
          [Move North, Move West, UseExit, Move East, Move East, Move South, UseExit]
  assert "observable exit playthrough" (isWon final && "Escaped!" `contains` render final)
  assert "rules preserve invariants" (all (null . invariantErrors) states)
  assert "wall still consumes one turn" (turnCount (fst (advance (Move West) initial)) == 1)
  assert "finished worlds are stable" (fst (advance (Move West) final) == final)
  assert "save roundtrip at every boundary" (all (\world -> decodeWorld (encodeWorld world) == Right world) states)
  assert "reject invalid coordinates" (isLeft (decodeWorld "FP-GAME-SAVE 1 99 0 0 False"))
  assert "reject negative turns" (isLeft (decodeWorld "FP-GAME-SAVE 1 0 0 -1 False"))
  assert "reject unsupported version" (isLeft (decodeWorld "FP-GAME-SAVE 99 0 0 0 False"))
  assert "reject malformed save" (isLeft (decodeWorld "broken"))
  assert "admission preserves original step" $
    Arena.play Adventure () (Arena.singleton LocalPlayer (Move South)) initial == Right (advance (Move South) initial)
  assert "empty submission rejected without state transition" $
    Arena.attempt Adventure () Arena.nobody initial == Arena.Rejected "One local-player action is required." initial
  putStrLn "game-tests: PASS (playthrough, invariants, save validation, admission)"
  where
    isLeft (Left _) = True
    isLeft _ = False
    contains needle haystack = any (prefix needle) (tails haystack)
    prefix [] _ = True
    prefix _ [] = False
    prefix (x : xs) (y : ys) = x == y && prefix xs ys
    tails [] = [[]]
    tails xs@(_ : rest) = xs : tails rest
