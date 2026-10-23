{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Colony.Codec.Instances () where

import Colony.Codec.CBOR
import Colony.Codec.Value
import Colony.Construction qualified as Construction
import Colony.ContentCodec ()
import Colony.Jobs
import Colony.LegacyV3
import Colony.M1State
import Colony.Maintenance
import Colony.Needs
import Colony.Pickup (PickupClaim)
import Colony.Power
import Colony.RNG
import Colony.Ruleset (isM1Ruleset)
import Colony.Space qualified as Space
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.Workforce qualified as Workforce
import Colony.World
import Control.Monad (unless, when)
import Data.Map.Strict qualified as M

instance ValueCodec Facility

instance ValueCodec FacilityStatus

instance ValueCodec MaintenanceKind

instance ValueCodec MaintenancePhase

instance ValueCodec MaintenanceJob

instance ValueCodec MaintenanceState

instance ValueCodec RoadNode

instance ValueCodec RoadEdge

instance ValueCodec RoadTopology

instance ValueCodec PathResult

instance ValueCodec PathSearch

instance ValueCodec PathQueue

instance ValueCodec VehicleKind

instance ValueCodec VehiclePosition

instance ValueCodec TransportBlock

instance ValueCodec TransportVehicle

instance ValueCodec RequestStatus

instance ValueCodec DeliveryRequest

instance ValueCodec ShipmentKind

instance ValueCodec ShipmentStatus

instance ValueCodec Shipment

instance ValueCodec RecoveryStatus

instance ValueCodec VehicleRecovery

instance ValueCodec TransportState

instance ValueCodec ResidentStatus

instance ValueCodec Fraction

instance ValueCodec Resident

instance ValueCodec MealRecord

-- Empty dining extensions retain the historical two-field canonical encoding,
-- including archived checkpoint state hashes. Only the known old/new shapes
-- are accepted; neither absent old fields nor future fields are guessed.
instance ValueCodec NeedsState where
  toCBOR state = do
    residents <- toCBOR (needsResidents state)
    pantries <- toCBOR (needsPantries state)
    if M.null (needsDiningPreferences state) && M.null (needsLastMeals state)
      then pure (CMap [(0, CInteger 0), (1, CMap [(0, residents), (1, pantries)])])
      else do
        preferences <- toCBOR (needsDiningPreferences state)
        meals <- toCBOR (needsLastMeals state)
        pure (CMap [(0, CInteger 0), (1, CMap [(0, residents), (1, pantries), (2, preferences), (3, meals)])])
  fromCBOR (CMap [(0, CInteger 0), (1, CMap [(0, residents), (1, pantries)])]) =
    NeedsState <$> fromCBOR residents <*> fromCBOR pantries
  fromCBOR (CMap [(0, CInteger 0), (1, CMap [(0, residents), (1, pantries), (2, preferences), (3, meals)])]) =
    NeedsStateWithDining <$> fromCBOR residents <*> fromCBOR pantries <*> fromCBOR preferences <*> fromCBOR meals
  fromCBOR _ = problem "Invalid needs record: expected exactly two legacy or four dining fields"

instance ValueCodec NeedResult

instance ValueCodec Weather

instance ValueCodec Solar

instance ValueCodec Generator

instance ValueCodec Battery

instance ValueCodec EnergyReason

instance ValueCodec PowerGrid

instance ValueCodec PowerDemand

instance ValueCodec PowerResult

instance ValueCodec EntityId

instance ValueCodec SimTick

instance ValueCodec BoundarySeq

instance ValueCodec Phase

instance ValueCodec TxId

instance ValueCodec EventId

instance ValueCodec Epoch

instance ValueCodec CommandId

instance ValueCodec OwnerKind

instance ValueCodec Owner

instance ValueCodec Storage

instance ValueCodec Lot

instance ValueCodec QuantityReservation

instance ValueCodec CapacityReservation

instance ValueCodec NaturalReservation

instance ValueCodec Deposit

instance ValueCodec Reason

instance ValueCodec LedgerSubreason

instance ValueCodec LedgerEntry

instance ValueCodec Inventory

instance ValueCodec Failure

instance ValueCodec JobPhase

instance ValueCodec Job

instance ValueCodec CoreMode

instance ValueCodec Role

instance ValueCodec Participant

instance ValueCodec Site

instance ValueCodec Command

instance ValueCodec OrderedCommand

instance ValueCodec ManagementEvent

instance ValueCodec BoundaryHeader

instance ValueCodec NativeInput

instance ValueCodec Outcome

instance ValueCodec CommandReceipt

instance ValueCodec DomainEvent

instance ValueCodec Diagnostic

instance ValueCodec ColonyOutput

-- Schema3 uses an explicit frozen product, not the evolving in-memory World.
instance ValueCodec WorldV3

instance ValueCodec Space.Tile

instance ValueCodec Space.Rect

instance ValueCodec Space.Rotation

instance ValueCodec Space.Terrain

instance ValueCodec Space.MapSpec

instance ValueCodec Space.SourceRegion

instance ValueCodec Space.PlacementShape

instance ValueCodec Space.PlacementStage

instance ValueCodec Space.Placement

instance ValueCodec Space.OwnerLocation

instance ValueCodec Space.CacheReason

instance ValueCodec Space.CacheContext

instance ValueCodec Space.CacheRecord

instance ValueCodec Space.SpatialState

instance ValueCodec Workforce.WorkTarget

instance ValueCodec Workforce.Skill

instance ValueCodec Workforce.WorkRole

instance ValueCodec Workforce.SkillProgress

instance ValueCodec Workforce.WorkerAdjunct

instance ValueCodec Workforce.WorkforceState

instance ValueCodec Construction.ConstructionKind

instance ValueCodec Construction.ConstructionSnapshot

instance ValueCodec Construction.ConstructionPhase

instance ValueCodec Construction.ConstructionJob

instance ValueCodec Construction.ConstructionState

instance ValueCodec BedAssignment

instance ValueCodec PickupClaim

instance ValueCodec M1State

instance ValueCodec World where
  toCBOR world = case worldM1 world of
    Nothing -> do
      when (isM1Ruleset (worldRuleset world)) (problem "M1 profile lacks schema4 state")
      toCBOR (projectWorldV3 world)
    Just state -> do
      unless (isM1Ruleset (worldRuleset world)) (problem "Legacy profile cannot contain schema4 state")
      common <- toCBOR (projectWorldV3 world)
      extra <- toCBOR state
      pure (CMap [(0, CInteger 4), (1, CMap [(0, common), (1, extra)])])
  fromCBOR (CMap [(0, CInteger 4), (1, CMap [(0, common), (1, extra)])]) = do
    world <- embedWorldV3 <$> fromCBOR common
    unless (isM1Ruleset (worldRuleset world)) (problem "Schema4 requires M1 profile")
    state <- fromCBOR extra
    pure world {worldM1 = Just state}
  fromCBOR term = do
    world <- embedWorldV3 <$> fromCBOR term
    when (isM1Ruleset (worldRuleset world)) (problem "M1 profile cannot decode schema3 payload")
    pure world

instance ValueCodec Rng

instance ValueCodec RngStreams

instance ValueCodec RngStream

instance ValueCodec DrawResult

instance (ValueCodec a) => ValueCodec (PendingRandomDraw a)

-- Intentionally uses the smart constructor; Qty's hidden constructor, Read,
-- Binary and unchecked coercions are never involved in the checkpoint codec.
instance ValueCodec (Qty r) where
  toCBOR = toCBOR . qtyValue
  fromCBOR term = do
    n <- fromCBOR term
    either (Left . CodecError) Right (mkQty n)

problem :: String -> Either CodecError a
problem = Left . CodecError
