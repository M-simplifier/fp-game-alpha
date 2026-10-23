module Logistics.TransportTests (transportTests) where

import Colony.Content (Content)
import Colony.Inventory
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units (Resource (..), qtyValue)
import Control.Monad (unless, void)
import Data.Map.Strict qualified as M

must :: (Show e) => Either e a -> IO a
must = either (fail . show) pure

transportTests :: Content -> IO ()
transportTests content = do
  start <- must (roadNode 10 10)
  middle <- must (roadNode 11 10)
  end <- must (roadNode 12 10)
  topology <- must (setRoad (BoundarySeq 0) start middle 10 True emptyTopology >>= setRoad (BoundarySeq 0) middle end 10 True)
  let colony = EntityId 1
      source = Owner Warehouse (EntityId 2)
      destination = Owner Warehouse (EntityId 3)
      tick = SimTick 1
      tx = TxId 1 1 (BoundarySeq 0) P7 0
  ((first, second, request, planned), inventory) <-
    must $
      runInventory
        ( do
            addStorage source (Storage 2000000 Nothing colony)
            addStorage destination (Storage 2000000 Nothing colony)
            void (mintLot tx InitialGrant Nothing Water 1000 source (SimTick 0) Nothing "cargo")
            void (mintLot tx InitialGrant Nothing Fuel 20000 source (SimTick 0) Nothing "engine")
            ports <- addTransportPort source start (emptyTransport {transportTopology = topology}) >>= addTransportPort destination end
            (first, one) <- addTransportVehicle Truck colony source source start (SimTick 0) ports
            (second, two) <- addTransportVehicle Truck colony source source start (SimTick 0) one
            (request, planned) <- planDelivery (SimTick 0) source destination Water 1000 2 two
            claim <- freshId
            -- Fuel fits, but cargo will not. Failure occurs after refuelling, fresh IDs
            -- and claim transfers, so retry must undo more than the first admission.
            reserveCapacity claim (Owner Vehicle first) Water 299000
            pure (first, second, request, planned)
        )
        (emptyInventory content)
  ready <- must (phaseTransportPaths tick planned)
  (retried, committed) <- must (runInventory (phaseTransportAssign tick ready) inventory)
  let skipFirst = ready {transportVehicles = M.adjust (\vehicle -> vehicle {vehicleHasDriver = False}) first (transportVehicles ready)}
  (direct, expected) <- must (runInventory (phaseTransportAssign tick skipFirst) inventory)
  let restoreDriver state = state {transportVehicles = M.adjust (\vehicle -> vehicle {vehicleHasDriver = True}) first (transportVehicles state)}
      countedAsDirect = retried {transportLastMatches = transportLastMatches direct}
      stock owner resource = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots committed), lotOwner lot == owner, lotResource lot == resource]
  unless (committed == expected && countedAsDirect == restoreDriver direct) $
    fail "failed first truck changed committed IDs, fuel, claims or shipment layout"
  unless (transportLastMatches retried == 2 && transportLastAssignments retried == 1 && M.null (transportMatchCursors retried)) $
    fail "inventory rollback also rolled back matching cost/cursor, or successful match retained cursor"
  unless (stock (Owner Vehicle first) Fuel == 0 && stock (Owner Vehicle second) Fuel == 480 && stock (Owner Vehicle second) Water == 1000) $
    fail "retry fabricated remote fuel or retained failed truck payload"
  must (validateTransport retried committed)
  (_, full) <-
    must $
      runInventory
        ( do
            claim <- freshId
            reserveCapacity claim (Owner Vehicle second) Water 299000
        )
        inventory
  (blocked, unchanged) <- must (runInventory (phaseTransportAssign tick ready) full)
  unless (unchanged == full && transportLastMatches blocked == 2 && M.lookup request (transportMatchCursors blocked) == Just second) $
    fail "all-failed matching must retain cost and fairness cursor while preserving inventory"
  unless (maybe False (\parent -> null (requestChildren parent) && requestBlock parent == Just WaitingVehicle) (M.lookup request (transportRequests blocked))) $
    fail "failed dispatch published a child or wrong wait reason"
  putStrLn "Transport: late failed load restores exact IDs/fuel/claims; matching cost and fairness survive rollback"
