module Main (main) where

import Control.Monad (unless)
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty (..))
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
  checkRules
  checkSaves
  checkAdmission
  putStrLn "game-tests: PASS (playthrough, invariants, save validation, admission)"

checkRules :: IO ()
checkRules = do
  let final = walk smokeCommands
      states =
        scanl
          (\world command -> fst (advance command world))
          initial
          [Move North, Move West, UseExit, Move East, Move East, Move South, UseExit]
  assert "observable exit playthrough" (isWon final && "Escaped!" `isInfixOf` render final)
  assert "rules preserve invariants" (all (null . invariantErrors) states)
  let (blocked, events) = advance (Move West) initial
  assert "wall retains position and consumes exactly one turn" $
    position blocked == position initial && turnCount blocked == 1 && events == [HitWall]
  let (unavailable, refusal) = advance UseExit initial
  assert "unavailable exit consumes one turn without finishing" $
    position unavailable == position initial && turnCount unavailable == 1 && not (isWon unavailable) && refusal == [ExitUnavailable]
  assert "finished worlds retain the whole state and report completion" $
    all (\command -> advance command final == (final, [AlreadyFinished])) [Move North, UseExit]
  assert "save roundtrip at every boundary" (all (\world -> decodeWorld (encodeWorld world) == Right world) states)

checkSaves :: IO ()
checkSaves = do
  assert "reject invalid coordinates" (isLeft (decodeWorld "FP-GAME-SAVE 1 99 0 0 False"))
  assert "reject negative turns" (isLeft (decodeWorld "FP-GAME-SAVE 1 0 0 -1 False"))
  assert "reject unsupported version" (decodeWorld (replaceField 1 "99") == Left UnsupportedFormat)
  assert "reject malformed save" (decodeWorld "broken" == Left UnsupportedFormat)
  assert "reject trailing fields" (decodeWorld (encodeWorld initial ++ " extra") == Left UnsupportedFormat)
  mapM_
    (\(index, field) -> assert ("report malformed " ++ show field) (decodeWorld (replaceField index "?") == Left (MalformedValue field)))
    [(2, SavedColumn), (3, SavedRow), (4, SavedTurn)]
  let saved = words (encodeWorld initial)
      badProgress = unwords (init saved ++ ["?"])
  assert "report malformed progress" (decodeWorld badProgress == Left (MalformedValue SavedProgress))
  assert "malformed fields precede invariant validation" $
    decodeWorld (unwords (take 2 saved ++ ["99", "?"] ++ drop 4 saved)) == Left (MalformedValue SavedRow)
  assert "malformed column precedes malformed row" $
    decodeWorld (unwords (take 2 saved ++ ["?", "?"] ++ drop 4 saved)) == Left (MalformedValue SavedColumn)
  assert "coordinate error retains its offending value" $
    decodeWorld (replaceField 2 "99") == Left (InvalidWorld (PositionOutsideBoard (99, 0) :| []))
  assert "negative turns retain their offending value" $
    decodeWorld (replaceField 4 "-1") == Left (InvalidWorld (NegativeTurn (-1) :| []))
  assert "multiple invariant failures retain their order" $
    decodeWorld (unwords (take 2 saved ++ ["99", "0", "-1"] ++ drop 5 saved))
      == Left (InvalidWorld (PositionOutsideBoard (99, 0) :| [NegativeTurn (-1)]))
  let padded = encodeWorld initial ++ replicate (4096 - length (encodeWorld initial)) ' '
  assert "size limit is inclusive" (decodeWorld padded == Right initial)
  assert "size refusal precedes parsing" (decodeWorld (replicate 4097 '?') == Left SaveTooLarge)
  assert "oversized input inspects only the bounded prefix" $
    decodeWorld (replicate 4097 '?' ++ error "read beyond save limit") == Left SaveTooLarge
  where
    replaceField index value =
      let saved = words (encodeWorld initial)
       in unwords (take index saved ++ [value] ++ drop (index + 1) saved)

checkAdmission :: IO ()
checkAdmission = do
  assert "admission preserves original step" $
    Arena.play Adventure () (Arena.singleton LocalPlayer (Move South)) initial == Right (advance (Move South) initial)
  assert "empty submission rejected without state transition" $
    Arena.attempt Adventure () Arena.nobody initial == Arena.Rejected "One local-player action is required." initial
  assert "duplicate participants are refused before admission" $
    Arena.joint [(LocalPlayer, Move South), (LocalPlayer, UseExit)] == Left (Arena.DuplicateParticipant LocalPlayer)
