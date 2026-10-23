module Main (main) where

import Control.Monad (unless)
import Paper.Game
import Paper.Tuning

check :: String -> Bool -> IO ()
check name condition = unless condition (error name)

required :: Either a b -> b
required (Right x) = x
required (Left _) = error "expected valid fixture"

turn :: Integer -> World -> World
turn n w = case cell n of
  Just c -> fst (step (Rotate c) w)
  Nothing -> error "invalid fixture cell"

main :: IO ()
main = do
  check "default parity" (start initialCatalog == initial && initialWith defaultLevel == initial)
  mapM_
    (\(budget, spin) -> check "bounds before Int" (case level budget spin of Left _ -> True; Right _ -> False))
    [(-1, 1), (0, 1), (101, 1), (2 ^ (100 :: Int), 1), (18, -1), (18, 4), (18, 2 ^ (100 :: Int))]
  mapM_
    ( \spin -> do
        let cost = (2 - spin) `mod` 4 + 4
            config = required (level cost spin)
            world = initialWith config
            won = foldl (flip turn) world (replicate (fromInteger (cost - 4)) 0 ++ [2, 2, 11, 11])
        check "witness budget exact" (phase won == Won && movesLeft won == 0)
        check "insufficient budget rejected" (level (cost - 1) spin == Left WitnessFailed)
        check "configured restart" (fst (step Restart won) == world)
        let moved = turn 4 world
            undone = fst (step Undo moved)
        check "configured undo snapshot" (tiles undone == tiles world && movesLeft undone == movesLeft world)
        check "configured undo remains spent" (snd (step Undo (turn 4 undone)) == [Refused])
    )
    [0 .. 3]
  let oldWorld = turn 4 (start initialCatalog)
      updated = required (stage "revision 2 moveBudget 7 inletRotation 3" initialCatalog)
  check "new session adopts" (movesLeft (start updated) == 7 && tiles (start updated) /= tiles initial)
  check "live world pinned" (movesLeft oldWorld == 17 && fst (step Restart oldWorld) == initial)
  let invalid =
        [ ("", InvalidRecord),
          ("revision 0 moveBudget 7 inletRotation 3", InvalidRevision),
          ("revision 2 moveBudget 18 inletRotation 1", StaleRevision),
          ("revision 1 moveBudget 18 inletRotation 1", StaleRevision),
          ("revision 3 moveBudget 2 inletRotation 3", InvalidLevel WitnessFailed),
          ("revision 3 moveBudget 18446744073709551634 inletRotation 1", InvalidLevel BudgetRange),
          ("revision 3 moveBudget 18 inletRotation 4294967297", InvalidLevel RotationRange),
          ("revision 1000000001 moveBudget 18 inletRotation 1", InvalidRevision),
          ("revision 3 moveBudget 18.0 inletRotation 1", InvalidRecord),
          ("revision 3 moveBudget 18 inletRotation 1 trailing", InvalidRecord),
          (replicate 129 ' ', TooLong),
          ("revision 0 moveBudget 0 inletRotation 9", InvalidRevision),
          ("revision 2 moveBudget 0 inletRotation 9", StaleRevision),
          ("revision 2 moveBudget no inletRotation 1", InvalidRecord),
          ("revision 3 moveBudget 0 inletRotation 9", InvalidLevel BudgetRange),
          ("revision +3 moveBudget 18 inletRotation 1", InvalidRecord),
          ("moveBudget 18 revision 3 inletRotation 1", InvalidRecord),
          ("revision 3 moveBudget 18 inletRotation 1\NUL", InvalidRecord)
        ]
  mapM_ (\(raw, expected) -> check ("exact staging refusal: " ++ show raw) (stage raw updated == Left expected)) invalid
  let record = "revision 3 moveBudget 18 inletRotation 1"
      atLimit = replicate (128 - length record) ' ' ++ record
  check "record limit is inclusive" (fmap revision (stage atLimit updated) == Right 3 && stage (atLimit ++ " ") updated == Left TooLong)
  check "decimal leading zeroes retain their existing grammar" $
    fmap revision (stage "revision 0003 moveBudget 018 inletRotation 01" updated) == Right 3
  putStrLn "PASS: native level bounds, witnesses, pinned reset/undo, staging and default parity"
