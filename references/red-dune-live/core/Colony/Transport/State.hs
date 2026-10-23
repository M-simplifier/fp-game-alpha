{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

module Colony.Transport.State where

import Colony.Inventory
import Colony.Topology
import Colony.Types
import Colony.Units
import Control.DeepSeq (NFData)
import Control.Monad.State.Strict (gets)
import Data.Map.Strict qualified as M
import Data.Set qualified as S
import Data.Word (Word64)
import GHC.Generics (Generic)

data VehicleKind = CarrierCart | Truck deriving (Eq, Ord, Show, Read, Generic, NFData)

data VehiclePosition = AtRoadNode !RoadNode | Traversing !RoadNode !RoadNode !Integer !Word64
  deriving (Eq, Show, Read, Generic, NFData)

data TransportBlock
  = Searching
  | NoRoute
  | Congested
  | WaitingFuel
  | NoReturnCapacity
  | RemovedEdge
  | StaleRoute
  | WaitingVehicle
  | ExpiredCargo
  | DestinationCapacityLost
  | NoDriver
  | WaitingSourcePort
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data TransportVehicle = TransportVehicle
  { vehicleId :: !EntityId,
    vehicleKind :: !VehicleKind,
    vehicleColony :: !EntityId,
    vehicleHome :: !Owner,
    vehicleFuelSource :: !Owner,
    vehiclePosition :: !VehiclePosition,
    vehicleRoute :: ![RoadNode],
    vehicleRouteRevision :: !Word64,
    vehicleJob :: !(Maybe EntityId),
    vehiclePriority :: !Integer,
    vehicleWaitingSince :: !SimTick,
    vehicleBlock :: !(Maybe TransportBlock),
    vehicleHasDriver :: !Bool
  }
  deriving (Eq, Show, Read, Generic, NFData)

data RequestStatus = RequestOpen | RequestCompleted | RequestCancelled | RequestFailed
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data DeliveryRequest = DeliveryRequest
  { requestId :: !EntityId,
    requestSource :: !Owner,
    requestDestination :: !Owner,
    requestResource :: !Resource,
    requestQuantity :: !Integer,
    requestRemaining :: !Integer,
    requestChildren :: ![EntityId],
    requestStatus :: !RequestStatus,
    requestPriority :: !Integer,
    requestReadySince :: !SimTick,
    requestBlock :: !(Maybe TransportBlock),
    requestPathResult :: !PathResult,
    requestRouteRevision :: !Word64
  }
  deriving (Eq, Show, Read, Generic, NFData)

data ShipmentKind = DeliveryChild !EntityId | ReturnShipment !EntityId
  deriving (Eq, Show, Read, Generic, NFData)

data ShipmentStatus
  = ShipmentReserved
  | ShipmentCarrying
  | ShipmentDelivered
  | ShipmentCancelled
  | ShipmentReturned
  | ShipmentTransferred !EntityId
  | ShipmentFailed
  deriving (Eq, Show, Read, Generic, NFData)

data Shipment = Shipment
  { shipmentId :: !EntityId,
    shipmentKind :: !ShipmentKind,
    shipmentSource :: !Owner,
    shipmentDestination :: !(Maybe Owner),
    shipmentResource :: !Resource,
    shipmentQuantity :: !Integer,
    shipmentVehicle :: !EntityId,
    shipmentStatus :: !ShipmentStatus,
    shipmentLots :: ![EntityId],
    shipmentBlock :: !(Maybe TransportBlock)
  }
  deriving (Eq, Show, Read, Generic, NFData)

data RecoveryStatus = RecoveryWorking | RecoveryCompleted | RecoveryCancelled
  deriving (Eq, Ord, Show, Read, Generic, NFData)

data VehicleRecovery = VehicleRecovery
  { recoveryId :: !EntityId,
    recoveryVehicle :: !EntityId,
    recoveryTarget :: !RoadNode,
    recoveryEscrow :: !Owner,
    recoveryFuelSource :: !Owner,
    recoveryProgress :: !Integer,
    recoveryStatus :: !RecoveryStatus,
    recoveryHasCrew :: !Bool
  }
  deriving (Eq, Show, Read, Generic, NFData)

data TransportState = TransportState
  { transportTopology :: !RoadTopology,
    transportPaths :: !PathQueue,
    transportPorts :: !(M.Map Owner RoadNode),
    transportGroundCaches :: !(M.Map RoadNode Owner),
    transportRemovedPorts :: !(M.Map Owner BoundarySeq),
    transportRecoveries :: !(M.Map EntityId VehicleRecovery),
    transportVehicles :: !(M.Map EntityId TransportVehicle),
    transportRequests :: !(M.Map EntityId DeliveryRequest),
    transportShipments :: !(M.Map EntityId Shipment),
    transportAssignCursor :: !(Maybe EntityId),
    transportLastAssignments :: !Word64,
    transportMatchCursors :: !(M.Map EntityId EntityId),
    transportLastMatches :: !Word64
  }
  deriving (Eq, Show, Read, Generic, NFData)

emptyTransport :: TransportState
emptyTransport = TransportState emptyTopology emptyPathQueue M.empty M.empty M.empty M.empty M.empty M.empty M.empty Nothing 0 M.empty 0

vehicleCapacity :: VehicleKind -> Integer
vehicleCapacity CarrierCart = 50000
vehicleCapacity Truck = 300000

vehicleOwner :: TransportVehicle -> Owner
vehicleOwner = Owner Vehicle . vehicleId

shipmentTerminal :: Shipment -> Bool
shipmentTerminal shipment = case shipmentStatus shipment of ShipmentReserved -> False; ShipmentCarrying -> False; _ -> True

addTransportPort :: Owner -> RoadNode -> TransportState -> InventoryTx TransportState
addTransportPort owner node state = do
  exists <- gets (M.member owner . invStorage)
  require exists MissingOwner
  require (S.member node (roadNodes (transportTopology state))) (InvalidReference "Port is not on a road node")
  pure state {transportPorts = M.insert owner node (transportPorts state)}

-- Vehicle construction costs/work are handled by construction. This constructor
-- registers an already granted or actually completed vehicle and its storage.
addTransportVehicle :: VehicleKind -> EntityId -> Owner -> Owner -> RoadNode -> SimTick -> TransportState -> InventoryTx (EntityId, TransportState)
addTransportVehicle kind colony home fuelSource node tick state = do
  require (M.lookup home (transportPorts state) == Just node) (InvalidReference "Vehicle home port mismatch")
  require (M.lookup fuelSource (transportPorts state) == Just node) (InvalidReference "Fuel must be at vehicle's physical home node")
  ident <- freshId
  addStorage (Owner Vehicle ident) (Storage (vehicleCapacity kind) Nothing colony)
  let vehicle = TransportVehicle ident kind colony home fuelSource (AtRoadNode node) [] (topologyRevision (transportTopology state)) Nothing 2 tick Nothing True
  pure (ident, state {transportVehicles = M.insert ident vehicle (transportVehicles state)})

-- Shared lookup for runtime admission and committed snapshot validation. In a
-- valid M1 World this map is reconstructed from physical public endpoints; WIP
-- storage alone never grants a delivery capability.
lookupPublicPort :: Owner -> TransportState -> Maybe RoadNode
lookupPublicPort owner state = M.lookup owner (transportPorts state)

port :: Owner -> TransportState -> InventoryTx RoadNode
port owner state = maybe (throwTx (InvalidReference "MissingRoadPort")) pure (lookupPublicPort owner state)

lookupVehicle :: EntityId -> TransportState -> InventoryTx TransportVehicle
lookupVehicle ident state = maybe (throwTx TargetGone) pure (M.lookup ident (transportVehicles state))

lookupShipment :: EntityId -> TransportState -> InventoryTx Shipment
lookupShipment ident state = maybe (throwTx TargetGone) pure (M.lookup ident (transportShipments state))

quantityFor :: EntityId -> Inventory -> Integer
quantityFor ident inventory = sum [qtyValue (quantityAmount reservation) | reservation <- M.elems (invQuantity inventory), quantityJob reservation == ident]

capacityFor :: EntityId -> Owner -> Inventory -> Integer
capacityFor ident owner inventory = sum [capacityWeight reservation | reservation <- M.elems (invCapacity inventory), capacityJob reservation == ident, capacityOwner reservation == owner]
