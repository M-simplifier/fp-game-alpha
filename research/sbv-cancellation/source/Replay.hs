{-# LANGUAGE GHC2021 #-}
-- Read-only bridge to frozen production source: no cancellation implementation is copied here.
module Main (main) where

import Colony.Content (Content, Recipe(..), contentRecipes, loadContent)
import Colony.Inventory
import qualified Colony.Jobs as Core
import Colony.Types
import Colony.Units
import Control.Monad (forM_, unless)
import Data.IORef
import qualified Data.Map.Strict as M
import System.Environment (getArgs)

type Counts = IORef (M.Map String Integer)

assert :: Counts -> String -> String -> Bool -> IO ()
assert counts category context condition = do
  unless condition (fail (category ++ ": " ++ context))
  modifyIORef' counts (M.insertWith (+) category 1)

right :: Show e => Either e a -> IO a
right = either (fail . show) pure

tx :: TxId
tx = TxId 1 1 (BoundarySeq 0) P1 0

-- This is a state-unit fixture using the real planner, starter and content loader.
-- Work credit is set explicitly; this does not simulate scheduler/time admission.
fixture :: Counts -> Content -> [Integer] -> [Integer] -> IO (Core.Job, Inventory)
fixture counts content metals parts = do
  (job, inventory) <- right $ runInventory (do
    colony <- freshId
    site <- freshId
    let input = Owner MachineInput site
        output = Owner MachineOutput site
    addStorage input (Storage 400000 Nothing colony)
    addStorage output (Storage 400000 Nothing colony)
    forM_ [(Metal,metals),(Parts,parts)] $ \(resource,quantities) ->
      forM_ (zip [0 :: Integer ..] quantities) $ \(ordinal,quantity) -> do
        _ <- mintLot tx InitialGrant Nothing resource quantity input (SimTick 0) Nothing
                     ("replay-" ++ show resource ++ "-" ++ show ordinal)
        pure ()
    planned <- Core.planJob content "tools" input output M.empty
    Core.startJob content (SimTick 0) planned) (emptyInventory content)
  assert counts "fixture_valid_running_job" (show (metals,parts))
    (Core.validateJobs (M.singleton (Core.jobId job) job) inventory == Right ())
  pure (job,inventory)

loss :: Resource -> Inventory -> Integer
loss resource inventory = M.findWithDefault 0 (resource,CancelledProcessLoss) (invLedger inventory)

physical :: Resource -> Inventory -> Integer
physical resource inventory = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots inventory), lotResource lot == resource]

returned :: Core.Job -> Resource -> Inventory -> Integer
returned job resource inventory = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots inventory), lotResource lot == resource, lotOwner lot == Core.jobOutput job]

compositions :: Integer -> [[Integer]]
compositions 0 = [[]]
compositions n = [k:rest | k <- [1..n], rest <- compositions (n-k)]

boundaries :: Integer -> [Integer]
boundaries required = [0,1,required `div` 8-1,required `div` 8,required `div` 8+1,
                       required `div` 4,required `div` 2-1,required `div` 2,
                       required `div` 2+1,required-1,required]

runCase :: Counts -> Bool -> String -> String -> [Integer] -> [Integer]
        -> Core.Job -> Inventory -> Integer -> (Integer,Integer) -> IO ()
runCase counts verbose label profile metals parts job inventory progress (metalExpected,partsExpected) = do
  let current = job {Core.jobProgress=progress}
      context = label ++ " " ++ show (metals,parts,progress,Core.jobRequired current)
  (ended,result) <- right (runInventory (Core.cancelJob profile tx current) inventory)
  forM_ [(Metal,10000,metalExpected),(Parts,8,partsExpected)] $ \(resource,quantity,expected) -> do
    assert counts "transaction_loss" context (loss resource result == expected)
    assert counts "transaction_refund_at_output" context (returned current resource result == quantity-expected)
    assert counts "transaction_conservation" context (physical resource result + loss resource result == quantity)
  assert counts "transaction_terminal_once" context
    (Core.jobPhase ended == Core.Cancelled && Core.jobTerminalCount ended == 1)
  assert counts "transaction_reservations_released" context
    (M.null (invQuantity result) && M.null (invCapacity result) && M.null (invNatural result))
  assert counts "transaction_wip_empty" context
    (all ((/= Core.wipOwner current) . lotOwner) (M.elems (invLots result)))
  assert counts "transaction_repeat_cancel_refused" context
    (runInventory (Core.cancelJob profile tx ended) result == Left AlreadyTerminal)
  assert counts "transaction_valid_terminal_job" context
    (Core.validateJobs (M.singleton (Core.jobId ended) ended) result == Right ())
  putStrLn $ "CASE " ++ context ++ " profile=" ++ profile
    ++ " actual(lossMetal,refundMetal,lossParts,refundParts)="
    ++ show (loss Metal result,returned current Metal result,loss Parts result,returned current Parts result)
  if verbose then do
    putStrLn ("FIXTURE_BEFORE_JOB " ++ show current)
    putStrLn ("FIXTURE_BEFORE_INVENTORY " ++ show inventory)
    putStrLn ("FIXTURE_AFTER_JOB " ++ show ended)
    putStrLn ("FIXTURE_AFTER_INVENTORY " ++ show result)
  else pure ()

main :: IO ()
main = do
  args <- getArgs
  contentPath <- case args of
    [path] -> pure path
    _ -> fail "usage: replay /absolute/frozen/content-v1.json"
  counts <- newIORef M.empty
  content <- loadContent contentPath >>= right
  recipe <- maybe (fail "tools recipe absent") pure (M.lookup "tools" (contentRecipes content))
  assert counts "recipe_metal10000_parts8" contentPath
    (recipeInputs recipe == M.fromList [(Metal,10000),(Parts,8)])
  assert counts "recipe_work_ticks1200" contentPath (recipeWorkTicks recipe == 1200)
  putStrLn "IMPORT_BRIDGE Colony.Jobs.cancelLoss and Colony.Jobs.cancelJob from frozen red-dune-implementation-0.4/src"
  putStrLn ("CONTENT " ++ contentPath ++ " TOOLS_RECIPE " ++ show recipe)

  -- 65 * sum_{r=1..32}(r+1) = 36,400 distinct bounded inputs.
  -- Independent floor inequalities additionally check the result without div.
  forM_ [0..64] $ \quantity -> forM_ [1..32] $ \required -> forM_ [0..required] $ \progress -> do
    let actual = Core.cancelLoss progress required quantity
        context = show (quantity,required,progress)
    assert counts "bounded_cancelLoss_formula" context (actual == quantity*progress `div` required)
    assert counts "bounded_cancelLoss_floor_bracket" context
      (actual*required <= quantity*progress && quantity*progress < (actual+1)*required)
    assert counts "bounded_cancelLoss_bounds" context (actual >= 0 && actual <= quantity)
  -- Required=0 is a separate helper branch, not a valid running Job.
  forM_ [0..64] $ \quantity -> forM_ [0..32] $ \progress ->
    assert counts "zero_required_cancelLoss" (show (quantity,progress))
      (Core.cancelLoss progress 0 quantity == 0)
  putStrLn "ARITHMETIC_PASS positive-required inputs=36400 assertions=109200; zero-required inputs=2145 assertions=2145"

  (one,oneInventory) <- fixture counts content [10000] [8]
  (eight,eightInventory) <- fixture counts content [1,9999] (replicate 8 1)
  let half = Core.jobRequired one `div` 2
  runCase counts True "legacy-one" "red-dune-reference-0" [10000] [8] one oneInventory half (5000,4)
  runCase counts True "legacy-eight" "red-dune-reference-0" [1,9999] (replicate 8 1) eight eightInventory half (4999,0)
  runCase counts True "aggregate-one" "red-dune-reference-2" [10000] [8] one oneInventory half (5000,4)
  runCase counts True "aggregate-eight" "red-dune-reference-2" [1,9999] (replicate 8 1) eight eightInventory half (5000,4)
  putStrLn "COUNTEREXAMPLE_PASS legacy Parts loss/refund 4/4 versus 0/8; profile2 Parts loss/refund 4/4 for both"

  let partitions = compositions 8
  assert counts "composition_count128" "Parts8" (length partitions == 128)
  assert counts "boundary_count11_distinct" "tools recipe" (M.size (M.fromList [(p,()) | p <- boundaries (Core.jobRequired one)]) == 11)
  forM_ (zip [0 :: Integer ..] partitions) $ \(ordinal,parts) -> do
    let metals = case ordinal `mod` 3 of
          0 -> [10000]
          1 -> [1,9999]
          _ -> [7,13,9980]
    (job,inventory) <- fixture counts content metals parts
    forM_ (boundaries (Core.jobRequired job)) $ \progress -> do
      let metalExpected = 10000*progress `div` Core.jobRequired job
          partsExpected = 8*progress `div` Core.jobRequired job
      runCase counts False ("composition-" ++ show ordinal) "red-dune-reference-2"
        metals parts job inventory progress (metalExpected,partsExpected)
  putStrLn "TRANSACTION_PASS 128 Parts8 positive ordered compositions x11 progress points=1408 aggregate transactions; plus4 baseline transactions=1412"
  totals <- readIORef counts
  forM_ (M.toAscList totals) $ \(category,count) ->
    putStrLn ("ASSERTIONS " ++ category ++ " " ++ show count)
  putStrLn ("ASSERTIONS_TOTAL " ++ show (sum (M.elems totals)))
  putStrLn "SCOPE This is a finite direct-source bridge/replay, not a universal proof of the Haskell program. No scheduler/time/capacity/FEFO total guarantees are established. The fixture manually credits progress and provides ample return capacity. The separate SBV arithmetic experiment must state its own assumptions and scope."
  putStrLn "REPLAY_PASS"
