module Main (main) where
import Paper.Game
import Game.Arena
import qualified Data.Set as S
import Control.Monad (unless)

check :: String -> Bool -> IO ()
check name condition = unless condition (error name)
main :: IO ()
main = do
  check "initial" (phase initial == Playing && movesLeft initial == 18)
  check "cell range" (all ((==Nothing) . cell) [-1,16,18446744073709551616])
  let actions = [0,2,2,11,11,15]
      command n = maybe Restart Rotate (cell n)
      apply w a = fst (step (command a) w)
      winner = foldl apply initial actions
  check "constructive solution" (phase winner == Won && all (`S.member` wetCells winner) goals)
  check "won refuses rotate" (step (command 0) winner == (winner,[Refused]))
  check "reset" (fst (step Restart winner) == initial)
  let moved = fst (step (command 0) initial)
      rewound = fst (step Undo moved)
  check "undo restores visible board and budget" (tiles rewound == tiles initial && movesLeft rewound == movesLeft initial)
  check "undo once" (not (canUndo rewound) && snd (step Undo (fst (step (command 0) rewound))) == [Refused])
  check "restart replenishes undo" (canUndo (fst (step (command 0) (fst (step Restart rewound)))))
  let states = scanl apply initial (take 18 (repeat 4))
  check "finite budget" (all ((>=0) . movesLeft) states && phase (last states) == OutOfMoves)
  check "no postloss change" (fst (step (command 4) (last states)) == last states)
  mapM_ (\(w,n) -> check "Arena original boundary" (play Circuit () (singleton Gardener (command n)) w == Right (step (command n) w))) [(w,n) | w<-states,n<-[0..15]]
  putStrLn "Paper Circuit: constructive win, budget/reset and 304 Arena comparisons PASS"
