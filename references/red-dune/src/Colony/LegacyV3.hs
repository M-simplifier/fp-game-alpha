{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}
-- Frozen schema3 World product. The28 fields and all old nested products retain
-- their order. Codec decides whether projection is authorized for a legacy
-- profile; this structural projection alone never upgrades a schema/profile.
module Colony.LegacyV3(WorldV3(..),projectWorldV3,embedWorldV3) where
import qualified Colony.World as Current
import Colony.World(CoreMode,Site,Participant,CommandReceipt,DomainEvent)
import Colony.Content(Content)
import Colony.Types
import Colony.Jobs(Job)
import Colony.Power(PowerGrid,Weather)
import Colony.Needs(NeedsState)
import Colony.Transport(TransportState)
import Colony.Maintenance(MaintenanceState)
import Colony.RNG(RngStreams)
import Control.DeepSeq(NFData)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word(Word64)
import GHC.Generics(Generic)

data WorldV3 = WorldV3
  {v3WorldId :: !Word64,v3BranchId :: !Word64,v3WorldAuthority :: !String,v3WorldRuleset :: !String
  ,v3SimTick :: !SimTick,v3BoundarySeq :: !BoundarySeq,v3WorldRevision :: !Word64,v3WorldMode :: !CoreMode
  ,v3WorldContent :: !Content,v3WorldInventory :: !Inventory,v3WorldJobs :: !(M.Map EntityId Job),v3WorldSites :: !(M.Map EntityId Site)
  ,v3WorldJobSites :: !(M.Map EntityId EntityId),v3WorldParticipants :: !(M.Map Word64 Participant)
  ,v3WorldHighWater :: !(M.Map (Word64,Epoch) Word64),v3WorldReceipts :: ![CommandReceipt]
  ,v3WorldRng :: !RngStreams,v3WorldRecentEvents :: ![DomainEvent]
  ,v3WorldPowerGrids :: !(M.Map EntityId PowerGrid),v3WorldSiteGrids :: !(M.Map EntityId EntityId)
  ,v3WorldPoweredSites :: !(S.Set EntityId),v3WorldWeather :: !Weather,v3WorldNeeds :: !NeedsState,v3WorldTransport :: !TransportState,v3WorldMaintenance :: !MaintenanceState
  ,v3WorldMaintenanceCrews :: !(M.Map EntityId Integer),v3WorldOperatingFacilities :: !(S.Set EntityId),v3WorldMaintenanceAttempts :: !Word64}
  deriving (Eq,Show,Read,Generic,NFData)

projectWorldV3 :: Current.World -> WorldV3
projectWorldV3 w=WorldV3
  (Current.worldId w)
  (Current.branchId w)
  (Current.worldAuthority w)
  (Current.worldRuleset w)
  (Current.simTick w)
  (Current.boundarySeq w)
  (Current.worldRevision w)
  (Current.worldMode w)
  (Current.worldContent w)
  (Current.worldInventory w)
  (Current.worldJobs w)
  (Current.worldSites w)
  (Current.worldJobSites w)
  (Current.worldParticipants w)
  (Current.worldHighWater w)
  (Current.worldReceipts w)
  (Current.worldRng w)
  (Current.worldRecentEvents w)
  (Current.worldPowerGrids w)
  (Current.worldSiteGrids w)
  (Current.worldPoweredSites w)
  (Current.worldWeather w)
  (Current.worldNeeds w)
  (Current.worldTransport w)
  (Current.worldMaintenance w)
  (Current.worldMaintenanceCrews w)
  (Current.worldOperatingFacilities w)
  (Current.worldMaintenanceAttempts w)

embedWorldV3 :: WorldV3 -> Current.World
embedWorldV3 v=(Current.initialWorld(v3WorldContent v))
  {Current.worldId=v3WorldId v,
   Current.branchId=v3BranchId v,
   Current.worldAuthority=v3WorldAuthority v,
   Current.worldRuleset=v3WorldRuleset v,
   Current.simTick=v3SimTick v,
   Current.boundarySeq=v3BoundarySeq v,
   Current.worldRevision=v3WorldRevision v,
   Current.worldMode=v3WorldMode v,
   Current.worldContent=v3WorldContent v,
   Current.worldInventory=v3WorldInventory v,
   Current.worldJobs=v3WorldJobs v,
   Current.worldSites=v3WorldSites v,
   Current.worldJobSites=v3WorldJobSites v,
   Current.worldParticipants=v3WorldParticipants v,
   Current.worldHighWater=v3WorldHighWater v,
   Current.worldReceipts=v3WorldReceipts v,
   Current.worldRng=v3WorldRng v,
   Current.worldRecentEvents=v3WorldRecentEvents v,
   Current.worldPowerGrids=v3WorldPowerGrids v,
   Current.worldSiteGrids=v3WorldSiteGrids v,
   Current.worldPoweredSites=v3WorldPoweredSites v,
   Current.worldWeather=v3WorldWeather v,
   Current.worldNeeds=v3WorldNeeds v,
   Current.worldTransport=v3WorldTransport v,
   Current.worldMaintenance=v3WorldMaintenance v,
   Current.worldMaintenanceCrews=v3WorldMaintenanceCrews v,
   Current.worldOperatingFacilities=v3WorldOperatingFacilities v,
   Current.worldMaintenanceAttempts=v3WorldMaintenanceAttempts v}
