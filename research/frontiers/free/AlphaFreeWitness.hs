{-# LANGUAGE DeriveFunctor #-}

module Main (main) where

import Control.Monad (ap, unless)
import Data.Ratio ((%))
import Game.Arena (Policy (..), Seen (..), choose, observationRespecting)

data Free f a = Pure a | Impure (f (Free f a))

instance Functor f => Functor (Free f) where
  fmap f (Pure a) = Pure (f a)
  fmap f (Impure operation) = Impure (fmap (fmap f) operation)

instance Functor f => Applicative (Free f) where
  pure = Pure
  (<*>) = ap

instance Functor f => Monad (Free f) where
  Pure a >>= next = next a
  Impure operation >>= next = Impure (fmap (>>= next) operation)

data PlayF next = ChooseBit (Bool -> next) | FairCoin (Bool -> next)
  deriving Functor

chooseBit, fairCoin :: Free PlayF Bool
chooseBit = Impure (ChooseBit Pure)
fairCoin = Impure (FairCoin Pure)

guessThenCoin, coinThenGuess :: Free PlayF Bool
guessThenCoin = do
  guess <- chooseBit
  coin <- fairCoin
  pure (guess == coin)
coinThenGuess = do
  coin <- fairCoin
  guess <- chooseBit
  pure (guess == coin)

reward :: Bool -> Rational
reward won = if won then 1 else 0

meanPair :: Rational -> Rational -> Rational
meanPair a b = (a + b) / 2

bestChance :: Free PlayF Bool -> Rational
bestChance (Pure won) = reward won
bestChance (Impure (ChooseBit next)) = max (bestChance (next False)) (bestChance (next True))
bestChance (Impure (FairCoin next)) = meanPair (bestChance (next False)) (bestChance (next True))

constantChoiceChance :: Bool -> Free PlayF Bool -> Rational
constantChoiceChance _ (Pure won) = reward won
constantChoiceChance guess (Impure (ChooseBit next)) = constantChoiceChance guess (next guess)
constantChoiceChance guess (Impure (FairCoin next)) =
  meanPair (constantChoiceChance guess (next False)) (constantChoiceChance guess (next True))

leafValues :: Free PlayF a -> [a]
leafValues (Pure a) = [a]
leafValues (Impure (ChooseBit next)) = leafValues (next False) ++ leafValues (next True)
leafValues (Impure (FairCoin next)) = leafValues (next False) ++ leafValues (next True)

onObservation :: Policy view Bool -> view -> Bool
onObservation policy observed = choose policy [Seen observed Nothing]

score :: (Bool -> Bool) -> Rational
score guess = meanPair (reward (not (guess False))) (reward (guess True))

hiddenBest, visibleBest :: Rational
hiddenBest = maximum [score (const (onObservation (Policy (const bit)) ())) | bit <- [False, True]]
visibleBest = maximum [score (onObservation (policy f t)) | f <- [False, True], t <- [False, True]]
  where
    policy f t = Policy $ \history -> case history of
      Seen observed _ : _ -> if observed then t else f
      [] -> False

data TxF next = Write Int next | Abort deriving Functor

failedWrite :: Free TxF ()
failedWrite = Impure (Write 1 (Impure Abort))

stateInsideFailure :: Free TxF a -> Int -> Either () (a, Int)
stateInsideFailure (Pure a) state = Right (a, state)
stateInsideFailure (Impure (Write state next)) _ = stateInsideFailure next state
stateInsideFailure (Impure Abort) _ = Left ()

failureInsideState :: Free TxF a -> Int -> (Either () a, Int)
failureInsideState (Pure a) state = (Right a, state)
failureInsideState (Impure (Write state next)) _ = failureInsideState next state
failureInsideState (Impure Abort) state = (Left (), state)

assert :: String -> Bool -> IO ()
assert label holds = unless holds (fail label)

main :: IO ()
main = do
  assert "same leaves cannot determine strategic value" (leafValues guessThenCoin == leafValues coinThenGuess)
  assert "max E" (bestChance guessThenCoin == 1 % 2)
  assert "E max" (bestChance coinThenGuess == 1)
  assert "a hidden coin does not become observable merely because it occurs first" $
    maximum [constantChoiceChance bit coinThenGuess | bit <- [False, True]] == 1 % 2
  assert "existing alpha Policy reproduces hidden bound" (hiddenBest == 1 % 2)
  assert "existing alpha Policy reproduces revealed bound" (visibleBest == 1)
  assert "existing alpha observation audit rejects the peeking strategy" $
    not (observationRespecting (const ()) id [False, True])
  assert "state inside failure discards tentative state" (stateInsideFailure failedWrite 0 == Left ())
  assert "failure inside state retains tentative state" (failureInsideState failedWrite 0 == (Left (), 1))
  putStrLn "same leaf values: [True,False,False,True]"
  putStrLn "Free max E = 1/2; Free E max = 1"
  putStrLn "Free coin first with a uniform hidden policy = 1/2"
  putStrLn "existing alpha Policy: hidden = 1/2; revealed = 1; peeking rejected"
  putStrLn "same Free transaction: rollback handler loses tentative state; retaining handler keeps 1"
  putStrLn "AlphaFreeWitness: PASS (9 finite checks; no game framework or universal proof)"
