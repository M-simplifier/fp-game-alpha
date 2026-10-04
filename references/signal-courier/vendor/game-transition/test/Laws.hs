module Main (main) where

import Control.Monad (forM_, unless)
import Game.Transition

assert :: String -> Bool -> IO ()
assert label ok = unless ok (error label)

counter :: Step Integer Integer [Integer]
counter = Step $ \increment state -> (state + increment, [increment])

samples :: [[Integer]]
samples = concat [sequence (replicate size [-1, 0, 1, 2]) | size <- [0 .. 4]]

checkTrace :: [Integer] -> IO ()
checkTrace inputs = do
  let initial = 7
      result = replay counter inputs initial
      observations = trace counter inputs initial
      tracedState = foldl (\_ seen -> after seen) initial observations
      transition = foldMap (forInput counter) inputs
      run = runTransition
  assert "trace/replay agreement" (result == (tracedState, foldMap emitted observations))
  assert "chronological output" (snd result == inputs)
  assert "left identity" (run (mempty <> transition) initial == result)
  assert "right identity" (run (transition <> mempty) initial == result)
  forM_ [0 .. length inputs] $ \cut -> do
    let (prefix, suffix) = splitAt cut inputs
        (middle, firstOutput) = replay counter prefix initial
        (final, secondOutput) = replay counter suffix middle
    assert "whole-boundary concatenation" (result == (final, firstOutput <> secondOutput))
  let transitions = map (forInput counter) [1, -2, 3]
  case transitions of
    [a, b, c] -> assert "associativity" (run ((a <> b) <> c) initial == run (a <> (b <> c)) initial)
    _ -> error "test fixture"

main :: IO ()
main = do
  mapM_ checkTrace samples
  let bad = Step $ \increment state -> (state + increment, [increment + 1])
  assert "mutated output is detected at boundary zero" $
    fmap boundaryIndex (firstDivergence counter bad [1, 2] 0) == Just 0
  assert "same step does not diverge" (firstDivergence counter counter [1, 2] 0 == Nothing)
  assert "empty replay" (replay counter [] 7 == (7, []))
  putStrLn "transition-laws: PASS (341 traces, chronological output, identities, partitions, mutation)"
