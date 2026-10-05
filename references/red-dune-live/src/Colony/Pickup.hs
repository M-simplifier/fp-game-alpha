{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- Saved empty-vehicle dispatch claims, distinct from a cargo Shipment. The parent
-- delivery request retains its existing quantity/capacity reservations until load.
module Colony.Pickup where

import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units (Resource (Fuel), qtyValue)
import Control.DeepSeq (NFData)
import Control.Monad (unless)
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as M
import GHC.Generics (Generic)

data PickupClaim = PickupClaim
  { pickupRequestId :: !EntityId,
    pickupSourceOwner :: !Owner,
    pickupStartedTick :: !SimTick,
    pickupFuelReady :: !Bool,
    pickupFuelRouteEdges :: !Integer,
    pickupReturnToHomeEdges :: !Integer,
    pickupReturnPath :: ![RoadNode]
  }
  deriving (Eq, Show, Read, Generic, NFData)

type Pickups = M.Map EntityId PickupClaim

pickupRequestMap :: Pickups -> M.Map EntityId EntityId
pickupRequestMap = M.map pickupRequestId

pickupTargets :: TransportState -> Pickups -> M.Map EntityId RoadNode
pickupTargets transport = M.mapMaybe (\claim -> M.lookup (pickupSourceOwner claim) (transportPorts transport))

-- Cancellation, expiry or removed source cancels only the pickup obligation.
-- Empty vehicles finish their current paid edge, then route home normally.
reconcilePickups :: Inventory -> TransportState -> Pickups -> (TransportState, Pickups)
reconcilePickups inventory transport pickups = (next, kept)
  where
    valid ident claim = case (M.lookup ident (transportVehicles transport), M.lookup (pickupRequestId claim) (transportRequests transport)) of
      (Just vehicle, Just request) ->
        vehicleJob vehicle == Nothing
          && requestStatus request == RequestOpen
          && requestRemaining request > 0
          && requestSource request == pickupSourceOwner claim
          && M.member (pickupSourceOwner claim) (invStorage inventory)
          && M.member (pickupSourceOwner claim) (transportPorts transport)
      _ -> False
    kept = M.filterWithKey valid pickups
    retired = [ident | ident <- M.keys (M.difference pickups kept), maybe True ((== Nothing) . vehicleJob) (M.lookup ident (transportVehicles transport))]
    next =
      transport
        { transportVehicles = foldr (M.adjust (\vehicle -> vehicle {vehicleRoute = [], vehicleBlock = case vehiclePosition vehicle of AtRoadNode _ -> Nothing; _ -> vehicleBlock vehicle})) (transportVehicles transport) retired,
          transportPaths = foldr dropPath (transportPaths transport) retired
        }

validatePickups :: Inventory -> TransportState -> SimTick -> Pickups -> Either Failure ()
validatePickups inventory transport tick pickups = do
  let (_, valid) = reconcilePickups inventory transport pickups
      check b = unless b . Left . InvariantViolation
  check (valid == pickups) "stale pickup claim"
  mapM_
    ( \(ident, claim) -> do
        vehicle <- maybe (Left TargetGone) Right (M.lookup ident (transportVehicles transport))
        request <- maybe (Left TargetGone) Right (M.lookup (pickupRequestId claim) (transportRequests transport))
        storage <- maybe (Left MissingOwner) Right (M.lookup (pickupSourceOwner claim) (invStorage inventory))
        check (storageColony storage == vehicleColony vehicle && pickupStartedTick claim <= tick && pickupStartedTick claim >= requestReadySince request) "pickup colony/time mismatch"
        check (vehicleRouteRevision vehicle == topologyRevision (transportTopology transport)) "pickup route certificate is stale"
        check (pickupFuelRouteEdges claim >= 0 && pickupFuelRouteEdges claim <= 1048572 && even (pickupFuelRouteEdges claim) && pickupReturnToHomeEdges claim >= 0 && pickupReturnToHomeEdges claim <= 262143 && 2 * pickupReturnToHomeEdges claim <= pickupFuelRouteEdges claim) "pickup fuel route bounds"
        case vehicleKind vehicle of
          CarrierCart -> check (pickupFuelReady claim && pickupFuelRouteEdges claim == 0 && pickupReturnToHomeEdges claim == 0 && null (pickupReturnPath claim)) "cart pickup fuel certificate"
          Truck ->
            if not (pickupFuelReady claim)
              then check (pickupFuelRouteEdges claim == 0 && pickupReturnToHomeEdges claim == 0 && null (pickupReturnPath claim) && vehiclePosition vehicle == maybe (vehiclePosition vehicle) AtRoadNode (M.lookup (vehicleFuelSource vehicle) (transportPorts transport))) "unfuelled pickup left garage"
              else do
                source <- maybe (Left TargetGone) Right (M.lookup (pickupSourceOwner claim) (transportPorts transport))
                home <- maybe (Left TargetGone) Right (M.lookup (vehicleHome vehicle) (transportPorts transport))
                delivery <- case requestPathResult request of PathFound route _ -> Right route; _ -> Left (InvariantViolation "fuel-ready pickup lacks delivery route")
                let witness = pickupReturnPath claim
                    cargoEdges = toInteger (length delivery) - 1
                    remaining = toInteger (length (vehicleRoute vehicle))
                    returnEdges = toInteger (length witness) - 1
                    anchor = case vehiclePosition vehicle of AtRoadNode node -> node; Traversing _ to _ _ -> to
                    unpaidSuffix = anchor : vehicleRoute vehicle
                    originalOutward = reverse witness
                    paidEdges = returnEdges - remaining
                    fuel = sum [qtyValue (lotQty lot) | lot <- M.elems (invLots inventory), lotOwner lot == vehicleOwner vehicle, lotResource lot == Fuel]
                check (not (null witness) && length witness <= 262144 && head witness == source && last witness == home) "pickup return witness endpoints/length"
                check (all (\(a, b) -> openEdge (transportTopology transport) a b /= Nothing) (zip witness (drop 1 witness))) "pickup return witness has no current-generation road edge"
                check (returnEdges == pickupReturnToHomeEdges claim && pickupFuelRouteEdges claim == 2 * (returnEdges + cargoEdges)) "pickup numerical certificate differs from actual road witnesses"
                check (unpaidSuffix `isSuffixOf` originalOutward && paidEdges >= 0) "pickup remaining route differs from certified outward path"
                -- A topology generation change invalidates the whole pickup before
                -- commit (M1Commands.reconcileM1Infrastructure). Closed-edge waiting
                -- states then have no current certificate and remain saveable.
                check (fuel >= 120 * pickupFuelRouteEdges claim - 100 * paidEdges) "pickup fuel no longer covers certified travel plus reserve"
    )
    (M.toAscList pickups)
