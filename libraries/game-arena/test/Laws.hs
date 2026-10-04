{-# LANGUAGE TypeFamilies #-}

module Main where

import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty (..))
import Game.Arena
import Game.Arena.Finite
import Game.Transition

assert :: String -> Bool -> IO ()
assert label ok = unless ok (error label)

expectRight :: (Show e) => Either e a -> a
expectRight = either (error . show) id

powerset :: [a] -> [[a]]
powerset [] = [[]]
powerset (x : xs) = let rest = powerset xs in rest ++ map (x :) rest

data Player = Alice | Bob deriving (Eq, Show)

data Hidden = Hidden

instance Machine Hidden where
  type State Hidden = Bool
  type Input Hidden = Bool
  type Output Hidden = Bool
  machine _ = Step (\guess secret -> (secret, guess == secret))

instance Arena Hidden where
  type Agent Hidden = Player
  type Action Hidden = Bool
  type Context Hidden = ()
  type View Hidden = ()
  type Rejection Hidden = String
  observe _ _ _ = ()
  admit _ () choices _ = case submissions choices of
    [(Alice, choice)] -> Right choice
    _ -> Left "Exactly Alice chooses a guess"

-- Joint actions are compiled atomically; neither player's Policy gets the
-- other player's current choice. This tests representation, not equilibrium.
data Matching = Matching

instance Machine Matching where
  type State Matching = Int
  type Input Matching = (Bool, Bool)
  type Output Matching = Bool
  machine _ = Step (\(a, b) count -> (count + 1, a == b))

instance Arena Matching where
  type Agent Matching = Player
  type Action Matching = Bool
  type Context Matching = ()
  type View Matching = Int
  type Rejection Matching = String
  observe _ _ = id
  admit _ () choices _ = case (lookup Alice (submissions choices), lookup Bob (submissions choices)) of
    (Just a, Just b) -> Right (a, b)
    _ -> Left "Both players must submit"

main :: IO ()
main = do
  assert "joint rejects duplicate player" $
    joint [(Alice, True), (Alice, False)] == Left (DuplicateParticipant Alice)
  assert "empty joint represents environment-only boundary" (null (submissions (nobody :: Joint Player Bool)))
  assert "missing participant is not a move" (not (admitted Hidden () nobody False))
  assert "wrong guess is admitted and produces failure, not illegal input" $
    play Hidden () (singleton Alice True) False == Right (False, False)
  assert "rejection preserves state" $
    attempt Hidden () nobody True == Rejected "Exactly Alice chooses a guess" True
  let policies = [const False, const True] :: [() -> Bool]
      hiddenWinners = [p | p <- policies, all (\s -> p (observe Hidden Alice s) == s) [False, True]]
      revealedPolicies = [(\s -> if s then t else f) | f <- [False, True], t <- [False, True]]
  assert "hidden observation has no uniform sure winner" (null hiddenWinners)
  assert "revealing state admits one winner" (length [p | p <- revealedPolicies, all (\s -> p s == s) [False, True]] == 1)
  assert "state-peeking mutation caught" (not (observationRespecting (observe Hidden Alice) id [False, True]))
  assert "honest constant policy respects observations" (observationRespecting (observe Hidden Alice) (const False) [False, True])
  let policy = Policy (\seen -> maybe False id (previousOwnChoice (last seen)))
  assert "policy remembers own choice" (choose policy [Seen () (Just True)])
  let both = joint [(Alice, True), (Bob, False)]
  assert "joint matching preserves simultaneous choice" $
    case both of Right j -> play Matching () j 0 == Right (1, False); Left _ -> False
  assert "incomplete joint cannot be resolved early" (not (admitted Matching () (singleton Alice True) 0))
  let graph controller =
        finiteArena [(0, Choice controller (('L', 1) :| [('R', 2)])), (1, Halted), (2, Halted)] ::
          Either (ArenaError Int) (FiniteArena Int Player Char)
      playerGraph = expectRight (graph (Participant Alice))
      environmentGraph = expectRight (graph External)
  assert "player can force target" (0 `elem` forceReach [Alice] [1] playerGraph)
  assert "environment can foil same labelled graph" (0 `notElem` forceReach [Alice] [1] environmentGraph)
  assert "halted failure does not win vacuously" (2 `notElem` forceReach [Alice] [1] environmentGraph)
  assert "halted target still satisfies reach" (1 `elem` forceReach [Alice] [1] environmentGraph)
  assert "halted states cannot continue forever" (null (continueWithin [Alice] [0, 1, 2] playerGraph))
  let looping =
        expectRight
          ( finiteArena [(0, Choice (Participant Alice) (('W', 0) :| []))] ::
              Either (ArenaError Int) (FiniteArena Int Player Char)
          )
  assert "neutral no-reward activity can continue" (continueWithin [] [0] looping == [0])
  assert "unknown successors rejected" $
    finiteArena [(0, Choice External (('x', 99) :| []))]
      == (Left (UnknownSuccessor 99) :: Either (ArenaError Int) (FiniteArena Int Player Char))
  assert "duplicate states rejected" $
    finiteArena [(0, Halted), (0, Halted)]
      == (Left (DuplicateState 0) :: Either (ArenaError Int) (FiniteArena Int Player Char))
  let subsets = powerset [0, 1, 2]
      subset a b = all (`elem` b) a
      monotone arena =
        and
          [ not (subset a b)
              || subset
                (controllablePredecessor [Alice] a arena)
                (controllablePredecessor [Alice] b arena)
          | a <- subsets,
            b <- subsets
          ]
  assert "CPre monotone over all subset pairs, both ownership cases" (monotone playerGraph && monotone environmentGraph)
  putStrLn "arena-laws: PASS (admission, duplicate/joint control, observations, hidden-state mutation, finite CPre, deadlock, 128 subset pairs)"
