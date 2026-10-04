{-# LANGUAGE DeriveGeneric #-}
-- | Explicit compatibility schemas. Neither legacy payload contains 'World',
-- current Inventory, lot claims, or independent capacity claims. These are
-- prerelease compatibility fixtures, not a claim that an old game was shipped.
module Colony.Migrate where

import Colony.Codec (sha256,canonicalWorldBytes,supportedRulesets)
import Colony.Codec.CBOR
import Colony.Codec.Value
import Colony.Content
import Colony.Inventory
import Colony.Jobs
import Colony.Maintenance
import Colony.Needs
import Colony.Power
import Colony.RNG
import Colony.Ruleset
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad (foldM,forM_,unless,when)
import qualified Data.ByteString as BS
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word (Word64)
import GHC.Generics (Generic)

-- Unchanged authority fields have an explicit wire product. Future World fields
-- must be reviewed here; serializing a current World under an old tag is forbidden.
data LegacyCore = LegacyCore
  { legacyWorldId :: !Word64, legacyBranchId :: !Word64
  , legacyAuthority :: !String, legacyRuleset :: !String
  , legacyTick :: !SimTick, legacyBoundary :: !BoundarySeq, legacyRevision :: !Word64
  , legacyMode :: !CoreMode, legacyContent :: !Content
  , legacyJobs :: !(M.Map EntityId Job), legacySites :: !(M.Map EntityId Site)
  , legacyJobSites :: !(M.Map EntityId EntityId)
  , legacyParticipants :: !(M.Map Word64 Participant)
  , legacyHighWater :: !(M.Map (Word64,Epoch) Word64)
  , legacyReceipts :: ![CommandReceipt], legacyRng :: !RngStreams
  , legacyEvents :: ![DomainEvent], legacyPower :: !(M.Map EntityId PowerGrid)
  , legacySiteGrids :: !(M.Map EntityId EntityId), legacyPowered :: !(S.Set EntityId)
  , legacyWeather :: !Weather, legacyNeeds :: !NeedsState
  , legacyMaintenance :: !MaintenanceState, legacyMaintenanceCrews :: !(M.Map EntityId Integer)
  , legacyOperatingFacilities :: !(S.Set EntityId), legacyMaintenanceAttempts :: !Word64
  } deriving (Eq,Show,Generic)

-- V1/V2 combined reservation: source is an owner/resource aggregate, not a
-- lot reference. A capacity-only WIP/output claim has no source and quantity 0.
-- For shipped cargo source records the historical loading owner; the actual
-- physical owner is derived from its shipment vehicle, never recreated there.
data LegacyReservation = LegacyReservation
  { legacyReservationId :: !EntityId, legacyReservationJob :: !EntityId
  , legacySource :: !(Maybe Owner), legacyResource :: !Resource
  , legacyQuantity :: !Integer, legacyDestination :: !(Maybe Owner)
  , legacyCapacity :: !Integer, legacyShipped :: !Bool
  } deriving (Eq,Show,Generic)

data LegacyInventoryMeta = LegacyInventoryMeta
  { legacyNextId :: !Word64, legacyStorage :: !(M.Map Owner Storage)
  , legacyNatural :: !(M.Map EntityId NaturalReservation)
  , legacyDeposits :: !(M.Map EntityId Deposit)
  , legacyLedger :: !(M.Map (Resource,Reason) Integer)
  , legacyRecentLedger :: ![LedgerEntry]
  } deriving (Eq,Show,Generic)

data LegacyShipment = LegacyShipment
  { oldShipmentId :: !EntityId, oldShipmentKind :: !ShipmentKind
  , oldShipmentSource :: !Owner, oldShipmentDestination :: !(Maybe Owner)
  , oldShipmentResource :: !Resource, oldShipmentQuantity :: !Integer
  , oldShipmentVehicle :: !EntityId, oldShipmentStatus :: !ShipmentStatus
  , oldShipmentBlock :: !(Maybe TransportBlock)
  } deriving (Eq,Show,Generic)

data LegacyTransport = LegacyTransport
  { oldTopology :: !RoadTopology, oldPaths :: !PathQueue
  , oldPorts :: !(M.Map Owner RoadNode), oldGroundCaches :: !(M.Map RoadNode Owner)
  , oldRemovedPorts :: !(M.Map Owner BoundarySeq)
  , oldRecoveries :: !(M.Map EntityId VehicleRecovery)
  , oldVehicles :: !(M.Map EntityId TransportVehicle)
  , oldRequests :: !(M.Map EntityId DeliveryRequest)
  , oldShipments :: !(M.Map EntityId LegacyShipment)
  , oldAssignCursor :: !(Maybe EntityId), oldLastAssignments :: !Word64
  , oldMatchCursors :: !(M.Map EntityId EntityId), oldLastMatches :: !Word64
  } deriving (Eq,Show,Generic)

data LegacyV1 = LegacyV1
  { v1Core :: !LegacyCore, v1Meta :: !LegacyInventoryMeta
  , v1Stock :: !(M.Map (Owner,Resource) Integer)
  , v1Reservations :: !(M.Map EntityId LegacyReservation), v1Transport :: !LegacyTransport
  } deriving (Eq,Show,Generic)

data LegacyV2 = LegacyV2
  { v2Core :: !LegacyCore, v2Meta :: !LegacyInventoryMeta
  , v2Lots :: !(M.Map EntityId Lot)
  , v2Reservations :: !(M.Map EntityId LegacyReservation), v2Transport :: !LegacyTransport
  } deriving (Eq,Show,Generic)

instance ValueCodec LegacyCore
instance ValueCodec LegacyReservation
instance ValueCodec LegacyInventoryMeta
instance ValueCodec LegacyShipment
instance ValueCodec LegacyTransport
instance ValueCodec LegacyV1
instance ValueCodec LegacyV2

-- A receipt distinguishes preserved assets from deliberately changed freshness.
-- Fields for absent campaign/contracts/unlocks are not fabricated.
data PreservationReport = PreservationReport
  { migrationSourceSchema :: !Word64, migrationSourceBranch :: !Word64
  , migrationTargetBranch :: !Word64
  , migrationAssetsBefore :: !(M.Map (Owner,Resource) Integer)
  , migrationAssetsAfter :: !(M.Map (Owner,Resource) Integer)
  , migrationOwners :: !(M.Map Owner Storage)
  , migrationNaturalDeposits :: !(M.Map EntityId Deposit)
  , migrationNaturalClaims :: !(M.Map EntityId NaturalReservation)
  , migrationResidents :: !(M.Map EntityId Resident), migrationMaintenance :: !MaintenanceState
  , migrationWorkProgress :: !(M.Map EntityId (Integer,Integer))
  , migrationShipmentDestinations :: !(M.Map EntityId (Maybe Owner))
  , migrationRulesChanged :: ![String], migrationPendingSystems :: ![String]
  } deriving (Eq,Show)

data MigrationResult = MigrationResult
  { migrationSourceBytes :: !BS.ByteString, migrationSourceHash :: !BS.ByteString
  , migrationWorld :: !World, migrationReport :: !PreservationReport
  } deriving (Eq,Show)

bad :: String -> Either CodecError a
bad=Left . CodecError
check :: Bool -> String -> Either CodecError ()
check ok message=unless ok(bad message)
checkedFailure :: Either Failure a -> Either CodecError a
checkedFailure=either (bad.show) Right

coreFromWorld :: World -> LegacyCore
coreFromWorld w=LegacyCore (worldId w)(branchId w)(worldAuthority w)(worldRuleset w)
  (simTick w)(boundarySeq w)(worldRevision w)(worldMode w)(worldContent w)
  (worldJobs w)(worldSites w)(worldJobSites w)(worldParticipants w)(worldHighWater w)
  (worldReceipts w)(worldRng w)(worldRecentEvents w)(worldPowerGrids w)(worldSiteGrids w)
  (worldPoweredSites w)(worldWeather w)(worldNeeds w)
  (worldMaintenance w)(worldMaintenanceCrews w)(worldOperatingFacilities w)(worldMaintenanceAttempts w)

worldFromCore :: LegacyCore -> Inventory -> TransportState -> World
worldFromCore c inventory transport=World
  (legacyWorldId c)(legacyBranchId c)(legacyAuthority c)(legacyRuleset c)
  (legacyTick c)(legacyBoundary c)(legacyRevision c)(legacyMode c)(legacyContent c)
  inventory(legacyJobs c)(legacySites c)(legacyJobSites c)(legacyParticipants c)
  (legacyHighWater c)(legacyReceipts c)(legacyRng c)(legacyEvents c)(legacyPower c)
  (legacySiteGrids c)(legacyPowered c)(legacyWeather c)(legacyNeeds c)transport
  (legacyMaintenance c)(legacyMaintenanceCrews c)(legacyOperatingFacilities c)(legacyMaintenanceAttempts c) Nothing

metaFromInventory :: Inventory -> LegacyInventoryMeta
metaFromInventory i=LegacyInventoryMeta(invNextId i)(invStorage i)(invNatural i)(invDeposits i)(invLedger i)(invRecentLedger i)

inventoryFromMeta :: Content -> LegacyInventoryMeta -> Inventory
inventoryFromMeta content meta=(emptyInventory content)
  {invNextId=legacyNextId meta,invStorage=legacyStorage meta,invNatural=legacyNatural meta
  ,invDeposits=legacyDeposits meta,invLedger=legacyLedger meta,invRecentLedger=legacyRecentLedger meta}

transportToLegacy :: TransportState -> LegacyTransport
transportToLegacy t=LegacyTransport(transportTopology t)(transportPaths t)(transportPorts t)
  (transportGroundCaches t)(transportRemovedPorts t)(transportRecoveries t)(transportVehicles t)
  (transportRequests t)(M.map old(transportShipments t))(transportAssignCursor t)(transportLastAssignments t)
  (transportMatchCursors t)(transportLastMatches t)
  where old s=LegacyShipment(shipmentId s)(shipmentKind s)(shipmentSource s)(shipmentDestination s)
          (shipmentResource s)(shipmentQuantity s)(shipmentVehicle s)(shipmentStatus s)(shipmentBlock s)

transportFromLegacy :: LegacyTransport -> Inventory -> TransportState
transportFromLegacy t inventory=TransportState(oldTopology t)(oldPaths t)(oldPorts t)
  (oldGroundCaches t)(oldRemovedPorts t)(oldRecoveries t)(oldVehicles t)(oldRequests t)
  (M.map current(oldShipments t))(oldAssignCursor t)(oldLastAssignments t)(oldMatchCursors t)(oldLastMatches t)
  where current s=Shipment(oldShipmentId s)(oldShipmentKind s)(oldShipmentSource s)(oldShipmentDestination s)
          (oldShipmentResource s)(oldShipmentQuantity s)(oldShipmentVehicle s)(oldShipmentStatus s)
          [lotId lot|lot<-M.elems(invLots inventory),any(\r->quantityJob r==oldShipmentId s&&quantityLot r==lotId lot)(M.elems(invQuantity inventory))]
          (oldShipmentBlock s)

assetTotals :: Inventory -> M.Map (Owner,Resource) Integer
assetTotals inventory=M.fromListWith(+)[((lotOwner lot,lotResource lot),qtyValue(lotQty lot))|lot<-M.elems(invLots inventory)]

-- Used by fixture authors; this explicitly destroys expiry and lot identity and
-- coalesces quantity+capacity into the historical combined record format.
legacyV1Fixture :: World -> Either CodecError LegacyV1
legacyV1Fixture world=do
  v2<-legacyV2Fixture world
  let old=LegacyV1(v2Core v2)(v2Meta v2)(assetTotals(worldInventory world))(v2Reservations v2)(v2Transport v2)
  validateLegacyV1 old
  pure old

legacyV2Fixture :: World -> Either CodecError LegacyV2
legacyV2Fixture world=do
  check(not(isM1Ruleset(worldRuleset world))&&worldM1 world==Nothing)"Schema4 M1 state cannot be projected into a legacy fixture"
  _<-canonicalWorldBytes world
  let inventory=worldInventory world
      quantities=M.elems(invQuantity inventory)
      groups=M.fromListWith(++)[((quantityJob claim,lotOwner lot,lotResource lot),[claim])|claim<-quantities,Just lot<-[M.lookup(quantityLot claim)(invLots inventory)]]
      capacities=M.elems(invCapacity inventory)
      -- Keep quantity groups and output-only capacity claims distinct. Their
      -- old combined representation still allows an explicit source+destination
      -- pair; tests also construct those records directly.
      quantityRecords=[let ident=minimum(map quantityReservationId claims)
                           shipment=M.lookup job(transportShipments(worldTransport world))
                           shipped=maybe False((==ShipmentCarrying).shipmentStatus)shipment
                           source=if shipped then maybe owner shipmentSource shipment else owner
                       in (ident,LegacyReservation ident job(Just source)resource(sum(map(qtyValue.quantityAmount)claims))Nothing 0 shipped)
                      |((job,owner,resource),claims)<-M.toAscList groups]
      capacityRecords=[(capacityReservationId claim,LegacyReservation(capacityReservationId claim)(capacityJob claim)Nothing Water 0(Just(capacityOwner claim))(capacityWeight claim)False)|claim<-capacities]
      old=LegacyV2(coreFromWorld world)(metaFromInventory inventory)(invLots inventory)(M.fromList(quantityRecords++capacityRecords))(transportToLegacy(worldTransport world))
  validateLegacyV2 old
  pure old

-- The original counter is validated, not repaired. It must already exceed
-- every global ID, including residents, colonies, grids/devices and transport.
validateLegacyBase :: LegacyCore -> LegacyInventoryMeta -> M.Map EntityId Lot -> M.Map EntityId LegacyReservation -> LegacyTransport -> Either CodecError ()
validateLegacyBase core meta lots reservations transport=do
  check(legacyRuleset core `elem` supportedRulesets&&not(isM1Ruleset(legacyRuleset core)))"UnsupportedRuleset"
  either bad Right(validateContent(legacyContent core))
  check(legacyNextId meta>0)"Legacy ID counter is zero"
  forM_(M.toList reservations)$ \(ident,r)->do
    check(ident==legacyReservationId r)"Legacy reservation key mismatch"
    check(legacyQuantity r>=0&&legacyQuantity r<=quantityMax&&legacyCapacity r>=0&&legacyCapacity r<=quantityMax)"Invalid legacy reservation quantity/capacity"
    check((legacyQuantity r>0)==maybe False(const True)(legacySource r))"Legacy quantity/source mismatch"
    check((legacyCapacity r>0)==maybe False(const True)(legacyDestination r))"Legacy capacity/destination mismatch"
    check(legacyQuantity r>0||legacyCapacity r>0)"Empty legacy reservation"
    check(not(legacyShipped r)||legacyQuantity r>0)"Shipped capacity-only legacy reservation"
    forM_(legacyDestination r)$ \owner->check(M.member owner(legacyStorage meta))"Legacy capacity owner missing"
  let inventory=(inventoryFromMeta(legacyContent core)meta)
        {invLots=lots,invCapacity=M.map(\r->CapacityReservation(legacyReservationId r)(legacyReservationJob r)(maybe(Owner Warehouse(EntityId 0))id(legacyDestination r))(legacyCapacity r))reservations}
  checkedFailure(validateGlobalIds(worldFromCore core inventory(transportFromLegacy transport inventory)))
  forM_(M.elems(legacyJobs core))$ \job->either bad(const(Right()))(lookupRecipe(legacyContent core)(jobRecipe job))
  forM_(M.elems(legacySites core))$ \site->either bad(const(Right()))(lookupRecipe(legacyContent core)(siteRecipe site))

freshLegacy :: Word64 -> Either CodecError (EntityId,Word64)
freshLegacy next=do
  check(next>0&&next<maxBound)"Legacy allocator overflow"
  pure(EntityId next,next+1)

-- Ascending (old ownerID, resourceID, ordinal); owner-kind is only a stable
-- tie-breaker where two typed stores intentionally share the same site ID.
stockOrder :: ((Owner,Resource),Integer) -> (EntityId,Resource,OwnerKind)
stockOrder((Owner kind ident,resource),_)=(ident,resource,kind)

migrateV1ToV2 :: LegacyV1 -> Either CodecError LegacyV2
migrateV1ToV2 old=do
  validateLegacyBase(v1Core old)(v1Meta old)M.empty(v1Reservations old)(v1Transport old)
  (next,lots)<-foldM add(legacyNextId(v1Meta old),M.empty)(sortOn stockOrder(M.toList(v1Stock old)))
  let result=LegacyV2(v1Core old)((v1Meta old){legacyNextId=next})lots(v1Reservations old)(v1Transport old)
  validateLegacyV2 result
  pure result
  where
    add(next,lots)((owner,resource),quantity)=do
      check(quantity>0&&quantity<=quantityMax)"Invalid V1 aggregate quantity"
      check(M.member owner(legacyStorage(v1Meta old)))"V1 aggregate owner missing"
      definition<-either bad Right(lookupResource(legacyContent(v1Core old))resource)
      (ident,after)<-freshLegacy next
      amount<-either bad Right(mkQty quantity)
      let born@(SimTick tick)=legacyTick(v1Core old)
      expires<-case resourceShelfLife definition of
        Nothing->pure Nothing
        Just life->do
          check(toInteger tick+life<=toInteger(maxBound::Word64))"Freshness grace tick overflow"
          pure(Just(SimTick(fromInteger(toInteger tick+life))))
      pure(after,M.insert ident(Lot ident resource amount owner born expires "schema-v1-aggregate")lots)

validateLegacyV1 :: LegacyV1 -> Either CodecError ()
validateLegacyV1 old=migrateV1ToV2 old >> pure()

physicalClaimOwner :: LegacyTransport -> LegacyReservation -> Either CodecError Owner
physicalClaimOwner transport claim=case legacySource claim of
  Nothing->bad "Quantity claim has no source"
  Just source|not(legacyShipped claim)->pure source
             |otherwise->do
      shipment<-maybe(bad "Shipped claim has no shipment")Right(M.lookup(legacyReservationJob claim)(oldShipments transport))
      check(oldShipmentStatus shipment==ShipmentCarrying)"Shipped claim is not physically carrying"
      check(source==oldShipmentSource shipment)"Shipped claim historical source mismatch"
      check(M.member(oldShipmentVehicle shipment)(oldVehicles transport))"Shipped claim vehicle missing"
      pure(Owner Vehicle(oldShipmentVehicle shipment))

-- Split in ascending reservationId order. Within each owner/resource use stable
-- lotId order, rather than hash iteration. Never mint stock during this split.
splitLegacyReservations :: LegacyV2 -> Either CodecError Inventory
splitLegacyReservations old=foldM split initial(M.elems(v2Reservations old))
  where
    initial=(inventoryFromMeta(legacyContent(v2Core old))(v2Meta old)){invLots=v2Lots old}
    split inventory claim=do
      let amount=legacyQuantity claim; capacity=legacyCapacity claim
      owner<-if amount==0 then pure Nothing else Just <$> physicalClaimOwner(v2Transport old)claim
      selected<-case owner of
        Nothing->pure []
        Just source->do
          check(M.member source(invStorage inventory))"Legacy quantity owner missing"
          pick inventory amount [lot|lot<-M.elems(invLots inventory),lotOwner lot==source,lotResource lot==legacyResource claim]
      when(amount>0&&capacity>0)$check(capacity==weightOf inventory(legacyResource claim)amount)"Contradictory legacy quantity/capacity"
      (withQuantity,usedOld)<-foldM(addQuantity claim)(inventory,False)selected
      case legacyDestination claim of
        Nothing->pure withQuantity
        Just destination->do
          (ident,next)<-if usedOld then freshLegacy(invNextId withQuantity)else pure(legacyReservationId claim,invNextId withQuantity)
          pure withQuantity{invNextId=next,invCapacity=M.insert ident(CapacityReservation ident(legacyReservationJob claim)destination capacity)(invCapacity withQuantity)}
    pick _ 0 _=pure []
    pick _ _ []=bad "Legacy quantity overreservation"
    pick inventory remaining(lot:rest)=do
      let free=qtyValue(lotQty lot)-lotReserved inventory(lotId lot)
          takeAmount=min remaining free
      check(free>=0)"Legacy negative free stock"
      suffix<-pick inventory(remaining-takeAmount)rest
      pure([(lotId lot,takeAmount)|takeAmount>0]++suffix)
    addQuantity claim(inventory,usedOld)(lot,quantity)=do
      (ident,next)<-if usedOld then freshLegacy(invNextId inventory)else pure(legacyReservationId claim,invNextId inventory)
      amount<-either bad Right(mkQty quantity)
      pure(inventory{invNextId=next,invQuantity=M.insert ident(QuantityReservation ident(legacyReservationJob claim)lot amount)(invQuantity inventory)},True)

validateLegacyV2 :: LegacyV2 -> Either CodecError ()
validateLegacyV2 old=do
  validateLegacyBase(v2Core old)(v2Meta old)(v2Lots old)(v2Reservations old)(v2Transport old)
  forM_(M.elems(v2Lots old))$ \lot->do
    check(lotBorn lot<=legacyTick(v2Core old))"V2 lot born after saved tick"
    check(maybe True(>lotBorn lot)(lotExpires lot))"V2 expiry does not follow birth"
  inventory<-splitLegacyReservations old
  -- Full current invariants validate stock, ledger, global IDs, references,
  -- exact WIP/snapshots/capacity, needs, RNG, power and actual road transport.
  _<-canonicalWorldBytes(worldFromCore(v2Core old)inventory(transportFromLegacy(v2Transport old)inventory))
  pure()

migrateV2ToV3 :: Word64 -> LegacyV2 -> Either CodecError (World,PreservationReport)
migrateV2ToV3 newBranch old=do
  check(newBranch>0&&newBranch/=legacyBranchId(v2Core old))"Migration requires a distinct nonzero branch"
  validateLegacyV2 old
  inventory<-splitLegacyReservations old
  let core=v2Core old
      world=(worldFromCore core inventory(transportFromLegacy(v2Transport old)inventory)){branchId=newBranch}
      before=M.fromListWith(+)[((lotOwner lot,lotResource lot),qtyValue(lotQty lot))|lot<-M.elems(v2Lots old)]
      report=PreservationReport 2(legacyBranchId core)newBranch before(assetTotals inventory)(legacyStorage(v2Meta old))(legacyDeposits(v2Meta old))(legacyNatural(v2Meta old))
        (needsResidents(legacyNeeds core))(legacyMaintenance core)
        (M.union(M.map(\j->(jobProgress j,jobRequired j))(legacyJobs core))(M.map(\j->(maintenanceProgress j,maintenanceRequired j))(maintenanceJobs(legacyMaintenance core))))
        (M.map oldShipmentDestination(oldShipments(v2Transport old)))
        ["V2 owner/resource reservations split into lot quantity and destination capacity claims"]
        ["Contracts/collateral and unlock/progression state are not implemented in this kernel","OverflowHold capacity-shrink migration is pending"]
  _<-canonicalWorldBytes world
  check(before==assetTotals inventory)"Migration asset/owner preservation failure"
  pure(world,report)

-- The explicit legacy envelopes are canonical, bounded, digested and distinct
-- from the latest checkpoint schema. Original bytes are never rewritten.
encodeLegacyEnvelope :: ValueCodec a => Word64 -> a -> Either CodecError BS.ByteString
encodeLegacyEnvelope version old=do
  payload<-encodeValue old
  magic<-toCBOR("RDF-LEGACY-CHECKPOINT"::String)
  encodeCanonical(CMap[(0,magic),(1,CInteger(toInteger version)),(2,CBytes payload),(3,CBytes(sha256 payload))])

decodeLegacyEnvelope :: BS.ByteString -> Either CodecError (Word64,BS.ByteString)
decodeLegacyEnvelope bytes=do
  term<-decodeCanonical bytes
  case term of
    CMap[(0,magic),(1,version),(2,CBytes payload),(3,CBytes digest)]->do
      name<-fromCBOR magic
      check(name==("RDF-LEGACY-CHECKPOINT"::String))"Unknown legacy checkpoint magic"
      schema<-fromCBOR version
      check(schema==1||schema==2)"Unsupported legacy schema (including future schema)"
      check(sha256 payload==digest)"Legacy checkpoint digest mismatch"
      pure(schema,payload)
    _->bad "Invalid legacy checkpoint envelope"

encodeLegacyV1 :: LegacyV1 -> Either CodecError BS.ByteString
encodeLegacyV1 old=validateLegacyV1 old >> encodeLegacyEnvelope 1 old
encodeLegacyV2 :: LegacyV2 -> Either CodecError BS.ByteString
encodeLegacyV2 old=validateLegacyV2 old >> encodeLegacyEnvelope 2 old

decodeLegacyV1 :: BS.ByteString -> Either CodecError LegacyV1
decodeLegacyV1 bytes=do
  (version,payload)<-decodeLegacyEnvelope bytes
  check(version==1)"Expected legacy schema V1"
  old<-decodeValue payload
  validateLegacyV1 old
  encoded<-encodeValue old
  check(encoded==payload)"Noncanonical V1 typed payload"
  pure old

decodeLegacyV2 :: BS.ByteString -> Either CodecError LegacyV2
decodeLegacyV2 bytes=do
  (version,payload)<-decodeLegacyEnvelope bytes
  check(version==2)"Expected legacy schema V2"
  old<-decodeValue payload
  validateLegacyV2 old
  encoded<-encodeValue old
  check(encoded==payload)"Noncanonical V2 typed payload"
  pure old

-- Import convenience routes only through the mandated sequential migrations.
-- This is a pure preparation result. Save/OS commit must write a new branch and
-- generation and verify success before any UI announces a durable migration.
migrateLegacyBytes :: Word64 -> BS.ByteString -> Either CodecError MigrationResult
migrateLegacyBytes newBranch source=do
  (version,_)<-decodeLegacyEnvelope source
  old<-if version==1 then decodeLegacyV1 source >>= migrateV1ToV2 else decodeLegacyV2 source
  (world,receipt)<-migrateV2ToV3 newBranch old
  let report=receipt{migrationSourceSchema=version,migrationRulesChanged=
        ["V1 aggregate stock became deterministic lots, born at saved tick, with a full normal shelf-life grace"|version==1]++migrationRulesChanged receipt}
  pure(MigrationResult source(sha256 source)world report)

-- The balance exercise is an explicitly new ruleset on a new branch. The
-- original content remains stored in the original immutable World value.
-- Nothing replaces already-started RecipeSnapshot or its original content ID.
applyCookBalanceV2 :: Word64 -> Content -> World -> Either CodecError World
applyCookBalanceV2 newBranch proposed original=do
  _<-canonicalWorldBytes original
  check(newBranch>0&&newBranch/=branchId original)"Balance update requires a distinct nonzero branch"
  targetProfile<-either bad Right(balancedProfile(worldRuleset original))
  let before=worldContent original
  oldCook<-either bad Right(lookupRecipe before "cook")
  check(M.lookup Fuel(recipeInputs oldCook)==Just 1000&&M.lookup Ration(recipeOutputs oldCook)==Just 18000)"Balance update requires original cook quantities"
  let newCook=oldCook{recipeInputs=M.insert Fuel 800(recipeInputs oldCook),recipeOutputs=M.insert Ration 19000(recipeOutputs oldCook)}
      expected=before{contentRecipes=M.insert "cook" newCook(contentRecipes before)}
  check(proposed==expected)"Content-v2 must change only cook fuel 1000->800 and ration 18000->19000"
  let updated=original{branchId=newBranch,worldRuleset=targetProfile,worldContent=proposed}
  _<-canonicalWorldBytes updated
  pure updated

-- Explicit branch transition; old checkpoint bytes/replays remain unchanged.
-- Existing progress, WIP and recipe snapshots are preserved exactly. After this
-- transition a future cancellation uses resource-level loss; no historical
-- ledger entry is rewritten or compensated. Durability still belongs to Save.
applyCancellationCorrection :: Word64 -> World -> Either CodecError World
applyCancellationCorrection newBranch original=do
  _<-canonicalWorldBytes original
  check(newBranch>0&&newBranch/=branchId original)"Cancellation correction requires a distinct nonzero branch"
  targetProfile<-either bad Right(correctedCancellationProfile(worldRuleset original))
  let updated=original{branchId=newBranch,worldRuleset=targetProfile}
  _<-canonicalWorldBytes updated
  pure updated

-- Pure opt-in to exact split placement; no source checkpoint is rewritten.
-- Progress, physical WIP, snapshots, catalog IDs and all other fields are kept.
applyReturnPlacementCorrection :: Word64 -> World -> Either CodecError World
applyReturnPlacementCorrection newBranch original=do
  _<-canonicalWorldBytes original
  check(newBranch>0&&newBranch/=branchId original)"Return-placement correction requires a distinct nonzero branch"
  targetProfile<-either bad Right(correctedReturnPlacementProfile(worldRuleset original))
  let updated=original{branchId=newBranch,worldRuleset=targetProfile}
  _<-canonicalWorldBytes updated
  pure updated
