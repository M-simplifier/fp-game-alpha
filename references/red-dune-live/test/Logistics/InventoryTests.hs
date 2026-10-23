module Logistics.InventoryTests (inventoryTests) where

import Colony.Content (Content)
import Colony.Inventory
import Colony.Transport (tryInventory)
import Colony.Types
import Colony.Units (Resource (..))
import Control.Monad (forM_, unless, void)
import Control.Monad.State.Strict (get)

must :: (Show e) => Either e a -> IO a
must = either (fail . show) pure

inventoryTests :: Content -> IO ()
inventoryTests content = do
  let colony = EntityId 1
      source = Owner Warehouse (EntityId 2)
      destination = Owner Warehouse (EntityId 3)
      tx = TxId 1 1 (BoundarySeq 0) P7 0
  (_, before) <-
    must $
      runInventory
        ( do
            addStorage source (Storage 1000 Nothing colony)
            addStorage destination (Storage 1000 Nothing colony)
            void (mintLot tx InitialGrant Nothing Water 100 source (SimTick 0) Nothing "retry fixture")
        )
        (emptyInventory content)
  let failAfterEffects failure = do
        moveFree (SimTick 0) source destination Water 40
        consumeFree tx RecipeInput Nothing (SimTick 0) destination Water 10
        void freshId
        throwTx failure :: InventoryTx ()
  forM_ [MissingStock, NoCapacity, MissingReservation] $ \failure -> do
    ((outcome, observed), after) <-
      must $
        runInventory
          ( do
              outcome <- tryInventory (failAfterEffects failure)
              observed <- get
              pure (outcome, observed)
          )
          before
    unless (outcome == Left failure && observed == before && after == before) $
      fail ("recoverable attempt leaked stock, IDs, reservations or ledger: " ++ show failure)
  forM_ [CounterOverflow, InvariantViolation "deliberate invariant failure"] $ \failure ->
    unless (runInventory (tryInventory (failAfterEffects failure)) before == Left failure) $
      fail ("fatal inventory failure became a wait state: " ++ show failure)
  putStrLn "Inventory: late shortages roll back complete physical/ledger/allocator state; invariant and overflow failures escape"
