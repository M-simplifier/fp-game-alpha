{-# LANGUAGE DeriveGeneric, DeriveAnyClass, NoGeneralizedNewtypeDeriving #-}
module Colony.Types where

import Colony.Units
import Control.DeepSeq (NFData)
import Data.Map.Strict (Map)
import Data.Word (Word64)
import GHC.Generics (Generic)

newtype EntityId = EntityId Word64 deriving (Eq,Ord,Show,Read,Generic,NFData)
newtype SimTick = SimTick Word64 deriving (Eq,Ord,Show,Read,Generic,NFData)
newtype BoundarySeq = BoundarySeq Word64 deriving (Eq,Ord,Show,Read,Generic,NFData)
data Phase = P0 | P1 | P2 | P3 | P4 | P5 | P6 | P7 | P8 | P9 | P10
  deriving (Eq,Ord,Show,Read,Enum,Bounded,Generic,NFData)
data TxId = TxId Word64 Word64 BoundarySeq Phase Word64 deriving (Eq,Ord,Show,Read,Generic,NFData)
data EventId = EventId TxId Word64 deriving (Eq,Ord,Show,Read,Generic,NFData)
data Epoch = Epoch String Word64 deriving (Eq,Ord,Show,Read,Generic,NFData)
data CommandId = CommandId Word64 Word64 Epoch Word64 deriving (Eq,Ord,Show,Read,Generic,NFData)
data OwnerKind = Warehouse | MachineInput | MachineOutput | ConstructionEscrow | Vehicle | Tank | Pantry | GroundCache | RecoveryHold | NaturalDeposit | ExternalEscrow
  deriving (Eq,Ord,Show,Read,Enum,Bounded,Generic,NFData)
data Owner = Owner OwnerKind EntityId deriving (Eq,Ord,Show,Read,Generic,NFData)
data Storage = Storage
  { storageCapacity :: !Integer, storageResource :: !(Maybe Resource), storageColony :: !EntityId }
  deriving (Eq,Show,Read,Generic,NFData)
data Lot = Lot
  { lotId :: !EntityId, lotResource :: !Resource, lotQty :: !(Qty StockUnit)
  , lotOwner :: !Owner, lotBorn :: !SimTick, lotExpires :: !(Maybe SimTick), lotProvenance :: !String }
  deriving (Eq,Show,Read,Generic,NFData)
-- Quantity reservations refer to a physical lot, capacity reservations do not.
data QuantityReservation = QuantityReservation
  { quantityReservationId :: !EntityId, quantityJob :: !EntityId, quantityLot :: !EntityId, quantityAmount :: !(Qty StockUnit) }
  deriving (Eq,Show,Read,Generic,NFData)
data CapacityReservation = CapacityReservation
  { capacityReservationId :: !EntityId, capacityJob :: !EntityId, capacityOwner :: !Owner, capacityWeight :: !Integer }
  deriving (Eq,Show,Read,Generic,NFData)
data NaturalReservation = NaturalReservation
  { naturalReservationId :: !EntityId, naturalJob :: !EntityId, naturalSource :: !EntityId, naturalAmount :: !(Qty StockUnit) }
  deriving (Eq,Show,Read,Generic,NFData)
data Deposit = Deposit
  { depositId :: !EntityId, depositKind :: !String, depositResource :: !Resource, depositQty :: !(Qty StockUnit) }
  deriving (Eq,Show,Read,Generic,NFData)
data Reason = InitialGrant | Extraction | RecipeInput | RecipeOutput | ConstructionConsumed | DemolitionRecovered | LivingConsumed | FuelBurned | RescueFuelConsumed | ContractDelivered | TradeReceived | TradePaid | AidReceived | Immigration | Evacuation | SpoilageInput | SpoilageOutput | SpoilageDisposal | CancelledProcessLoss | ConstructionLoss | ResearchConsumed | ProjectDonated
  deriving (Eq,Ord,Show,Read,Enum,Bounded,Generic,NFData)
data LedgerSubreason = VehicleEdge | Maintenance | Repair deriving (Eq,Ord,Show,Read,Enum,Bounded,Generic,NFData)
data LedgerEntry = LedgerEntry
  { ledgerTx :: !TxId, ledgerResource :: !Resource, ledgerReason :: !Reason
  , ledgerQuantity :: !Integer, ledgerFrom :: !(Maybe Owner), ledgerTo :: !(Maybe Owner), ledgerJob :: !(Maybe EntityId), ledgerSubreason :: !(Maybe LedgerSubreason) }
  deriving (Eq,Show,Read,Generic,NFData)
data Inventory = Inventory
  { invNextId :: !Word64, invStorage :: !(Map Owner Storage), invLots :: !(Map EntityId Lot)
  , invQuantity :: !(Map EntityId QuantityReservation), invCapacity :: !(Map EntityId CapacityReservation)
  , invNatural :: !(Map EntityId NaturalReservation), invDeposits :: !(Map EntityId Deposit)
  , invLedger :: !(Map (Resource,Reason) Integer), invRecentLedger :: ![LedgerEntry]
  , invLoad :: !(Map Resource Integer), invShelf :: !(Map Resource (Maybe Word64)) }
  deriving (Eq,Show,Read,Generic,NFData)
data Failure = MissingStock | NoCapacity | MissingOwner | MissingLot | MissingReservation | ResourceMismatch | ExpiredInput | TargetGone | AlreadyTerminal | ReturnCapacityFull | InvalidQuantity | CounterOverflow | InvalidReference String | InvariantViolation String | CannotCancelRecovery | PathQueueFull | NoRecoveryNode | TransportRequestFull
  deriving (Eq,Show,Read,Generic,NFData)

sourceReason :: Reason -> Bool
sourceReason r = r `elem` [InitialGrant,Extraction,RecipeOutput,DemolitionRecovered,TradeReceived,AidReceived,Immigration,SpoilageOutput]
