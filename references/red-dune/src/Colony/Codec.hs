{-# LANGUAGE DeriveGeneric, FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}
-- | Canonical, bounded foundation checkpoint and replay codecs. This is the
-- in-memory format layer; no function here claims an OS durability commit.
module Colony.Codec
  ( CodecError(..), DecodeLimits(..), defaultDecodeLimits
  , CheckpointMeta(..), defaultCheckpointMeta
  , ReplayHeader(..), ReplayFrame(..), Replay(..)
  , encodeCheckpoint, decodeCheckpoint, decodeCheckpointWith
  , canonicalWorldBytes, canonicalStateHash, contentHash
  , encodeNativeInput, decodeNativeInput, encodeReplay, decodeReplay
  , sha256, sha256Hex, supportedRuleset, supportedRulesets, checkpointSchemaVersion, checkpointSchemaFor
  ) where

import Colony.Codec.CBOR
import Colony.Codec.Value
import Colony.Codec.SHA256 (sha256,sha256Hex)
import Colony.Content
import Colony.ContentCodec(contentIdentity)
import Colony.Needs
import Colony.Power
import Colony.Jobs
import Colony.RNG
import Colony.Ruleset(allRulesets,isM1Ruleset)
import Colony.M1State
import Colony.Pickup(PickupClaim)
import qualified Colony.Space as Space
import qualified Colony.Workforce as Workforce
import qualified Colony.Construction as Construction
import Colony.Types
import Colony.Units
import Colony.World
import Colony.LegacyV3
import Colony.Transport
import Colony.Topology
import Colony.Maintenance
import Control.Monad (unless,when,forM_)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Word (Word64)
import GHC.Generics (Generic)

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
instance ValueCodec NeedsState
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
  toCBOR world=case worldM1 world of
    Nothing->do
      when(isM1Ruleset(worldRuleset world))(problem "M1 profile lacks schema4 state")
      toCBOR(projectWorldV3 world)
    Just state->do
      unless(isM1Ruleset(worldRuleset world))(problem "Legacy profile cannot contain schema4 state")
      common<-toCBOR(projectWorldV3 world)
      extra<-toCBOR state
      pure(CMap[(0,CInteger 4),(1,CMap[(0,common),(1,extra)])])
  fromCBOR(CMap[(0,CInteger 4),(1,CMap[(0,common),(1,extra)])])=do
    world<-embedWorldV3 <$> fromCBOR common
    unless(isM1Ruleset(worldRuleset world))(problem "Schema4 requires M1 profile")
    state<-fromCBOR extra
    pure world{worldM1=Just state}
  fromCBOR term=do
    world<-embedWorldV3 <$> fromCBOR term
    when(isM1Ruleset(worldRuleset world))(problem "M1 profile cannot decode schema3 payload")
    pure world
instance ValueCodec Rng
instance ValueCodec RngStreams
instance ValueCodec RngStream
instance ValueCodec DrawResult
instance ValueCodec a => ValueCodec (PendingRandomDraw a)

-- Intentionally uses the smart constructor; Qty's hidden constructor, Read,
-- Binary and unchecked coercions are never involved in the checkpoint codec.
instance ValueCodec (Qty r) where
  toCBOR = toCBOR . qtyValue
  fromCBOR term = do
    n <- fromCBOR term
    either (Left . CodecError) Right (mkQty n)

data CheckpointMeta = CheckpointMeta
  { checkpointSequence :: !Word64
  , checkpointParentHash :: !(Maybe BS.ByteString)
  , checkpointBuildId :: !String
  } deriving (Eq,Show)

defaultCheckpointMeta :: CheckpointMeta
defaultCheckpointMeta = CheckpointMeta 0 Nothing "red-dune-foundation-development"

supportedRuleset :: String
supportedRuleset = "red-dune-reference-0"
supportedRulesets :: [String]
supportedRulesets=allRulesets
checkpointSchemaVersion :: Word64
checkpointSchemaVersion = 3
-- Historical constant remains3 for old callers; actual envelopes use this.
checkpointSchemaFor :: World -> Word64
checkpointSchemaFor world=if isM1Ruleset(worldRuleset world)then 4 else 3

checkpointMagic, checkpointFooter, replayMagic, replayFooter, inputMagic :: String
checkpointMagic = "RDF-CHECKPOINT-FOUNDATION"
checkpointFooter = "RDF-CHECKPOINT-END"
replayMagic = "RDF-REPLAY-FOUNDATION"
replayFooter = "RDF-REPLAY-END"
inputMagic = "RDF-NATIVE-INPUT"

problem :: String -> Either CodecError a
problem = Left . CodecError

validateMeta :: CheckpointMeta -> Either CodecError ()
validateMeta meta = do
  unless (not (null (checkpointBuildId meta))) (problem "Empty checkpoint build ID")
  mapM_ (checkHash "parent checkpoint") (checkpointParentHash meta)

checkHash :: String -> BS.ByteString -> Either CodecError ()
checkHash label hash = unless (BS.length hash == 32) (problem (label ++ " hash must contain exactly 32 bytes"))

validatePersistedWorld :: World -> Either CodecError ()
validatePersistedWorld world = do
  unless (worldRuleset world `elem` supportedRulesets) (problem "UnsupportedRuleset")
  let inventory = worldInventory world
      definitions = contentResources (worldContent world)
      counts = [ M.size (invStorage inventory),M.size (invLots inventory)
               , M.size (invQuantity inventory),M.size (invCapacity inventory)
               , M.size (invNatural inventory),M.size (invDeposits inventory)
               , M.size (worldJobs world),M.size (worldSites world)
               , M.size (worldParticipants world),M.size (worldPowerGrids world)
               , M.size (needsResidents (worldNeeds world)),M.size(maintenanceJobs(worldMaintenance world))]
      transport=worldTransport world
      transportEntityCounts=[M.size(transportVehicles transport),M.size(transportRequests transport),M.size(transportShipments transport),M.size(transportRecoveries transport),M.size(pathSearches(transportPaths transport))]
      transportRouteRecords=sum[toInteger(length(vehicleRoute vehicle))|vehicle<-M.elems(transportVehicles transport)]
      m1Counts=case worldM1 world of
        Nothing->[]
        Just state->[M.size(Space.spatialPlacements(m1Space state)),M.size(Construction.constructionJobs(m1Construction state)),M.size(Workforce.workforceWorkers(m1Workforce state)),M.size(Space.mapTerrain(Space.spatialMap(m1Space state))),S.size(Space.spatialRoads(m1Space state))]
      powerEntityCounts = [toInteger(length(gridSolar grid))+toInteger(length(gridGenerators grid))+toInteger(length(gridBatteries grid)) | grid<-M.elems(worldPowerGrids world)]
  when (sum (map toInteger(counts++transportEntityCounts++m1Counts))+sum powerEntityCounts+transportRouteRecords > 200000) (problem "World entity count exceeds 200000")
  either (Left . CodecError . show) Right (validateWorld world)
  either (Left . CodecError) Right (validateRngStreams (worldRng world))
  either (Left . CodecError) Right (validateContent (worldContent world))
  unless (worldPoweredSites world `S.isSubsetOf` M.keysSet (worldSites world)) (problem "Dangling powered site")
  forM_ (M.toList (worldPowerGrids world)) $ \(ident,grid) -> do
    unless (ident == gridId grid) (problem "Power grid key/ID mismatch")
    let ascending xs = and (zipWith (<) xs (drop 1 xs))
    unless (ascending (map solarId (gridSolar grid))) (problem "Solar IDs must be unique and ascending")
    unless (ascending (map generatorId (gridGenerators grid))) (problem "Generator IDs must be unique and ascending")
    unless (ascending (map batteryId (gridBatteries grid))) (problem "Battery IDs must be unique and ascending")
  unless (invLoad inventory == M.map resourceLoad definitions) (problem "Inventory load catalog differs from checkpoint content")
  unless (invShelf inventory == M.map (fmap fromInteger . resourceShelfLife) definitions) (problem "Inventory expiry catalog differs from checkpoint content")
  forM_ (M.elems (worldJobs world)) $ \job -> do
    _ <- either (Left . CodecError) Right (lookupRecipe (worldContent world) (jobRecipe job))
    pure ()
  forM_ (M.toList (worldSites world)) $ \(ident,site) -> do
    unless (ident == siteId site) (problem "Site key/ID mismatch")
    _ <- either (Left . CodecError) Right (lookupRecipe (worldContent world) (siteRecipe site))
    unless (M.member (siteInput site) (invStorage inventory) && M.member (siteOutput site) (invStorage inventory)) (problem "Dangling site inventory endpoint")
    pure ()

canonicalWorldBytes :: World -> Either CodecError BS.ByteString
canonicalWorldBytes world = validatePersistedWorld world >> encodeValue world
canonicalStateHash :: World -> Either CodecError BS.ByteString
canonicalStateHash = fmap sha256 . canonicalWorldBytes
contentHash :: Content -> Either CodecError BS.ByteString
contentHash= either (Left . CodecError) Right . contentIdentity

-- The envelope metadata is outside the authoritative state hash. Version 1's
-- state hash is precisely SHA-256(canonical payload), not a host Show/Read hash.
encodeCheckpoint :: CheckpointMeta -> World -> Either CodecError BS.ByteString
encodeCheckpoint meta world = do
  validateMeta meta
  payload <- canonicalWorldBytes world
  hash <- contentHash (worldContent world)
  ruleset <- toCBOR (worldRuleset world)
  parent <- toCBOR (checkpointParentHash meta)
  build <- toCBOR (checkpointBuildId meta)
  let SimTick tick = simTick world
      BoundarySeq boundary = boundarySeq world
      number = CInteger . toInteger
      digest = CBytes (sha256 payload)
  encodeCanonical (CMap
    [ (0,CText (T.pack checkpointMagic)),(1,number (1 :: Word64))
    , (2,number (worldId world)),(3,number (branchId world))
    , (4,number (checkpointSequence meta)),(5,number(checkpointSchemaFor world))
    , (6,ruleset),(7,CBytes hash),(8,CText (T.pack "RDF-RNG-1"))
    , (9,number tick),(10,number boundary),(11,CInteger (toInteger (BS.length payload)))
    , (12,digest),(13,digest),(14,parent),(15,build)
    , (16,CBytes payload),(17,CText (T.pack checkpointFooter)) ])

decodeCheckpoint :: BS.ByteString -> Either CodecError (CheckpointMeta,World)
decodeCheckpoint = decodeCheckpointWith defaultDecodeLimits

decodeCheckpointWith :: DecodeLimits -> BS.ByteString -> Either CodecError (CheckpointMeta,World)
decodeCheckpointWith limits bytes = do
  root <- decodeCanonicalWith limits bytes
  fields <- exactFields 18 root
  expectString checkpointMagic (fields M.! 0)
  expectWord 1 (fields M.! 1) "Unsupported checkpoint format version"
  schema<-fromCBOR(fields M.! 5) :: Either CodecError Word64
  unless(schema `elem` [3,4])(problem "Unsupported checkpoint schema version")
  envelopeRuleset<-fromCBOR(fields M.! 6)
  unless(envelopeRuleset `elem` supportedRulesets)(problem "UnsupportedRuleset")
  expectString "RDF-RNG-1" (fields M.! 8)
  expectString checkpointFooter (fields M.! 17)
  payload <- fromCBOR (fields M.! 16)
  declared <- fromCBOR (fields M.! 11) :: Either CodecError Word64
  unless (toInteger declared == toInteger (BS.length payload)) (problem "Checkpoint payload length mismatch")
  storedDigest <- fromCBOR (fields M.! 12)
  stateDigest <- fromCBOR (fields M.! 13)
  checkHash "payload" storedDigest
  checkHash "canonical state" stateDigest
  unless (sha256 payload == storedDigest && storedDigest == stateDigest) (problem "Checkpoint SHA256 mismatch")
  world <- decodeCanonicalWith limits payload >>= fromCBOR
  validatePersistedWorld world
  expectWord(checkpointSchemaFor world)(fields M.! 5)"Checkpoint schema/profile mismatch"
  -- Re-encode as an additional typed-schema canonicality check. This also
  -- rejects any alternative representation accidentally admitted by a codec.
  canonical <- canonicalWorldBytes world
  unless (canonical == payload) (problem "Noncanonical typed checkpoint payload")
  expectWord (worldId world) (fields M.! 2) "Checkpoint world ID mismatch"
  expectWord (branchId world) (fields M.! 3) "Checkpoint branch ID mismatch"
  let SimTick tick = simTick world
      BoundarySeq boundary = boundarySeq world
  expectWord tick (fields M.! 9) "Checkpoint simulation tick mismatch"
  expectWord boundary (fields M.! 10) "Checkpoint boundary sequence mismatch"
  expectString (worldRuleset world) (fields M.! 6)
  expectedContent <- contentHash (worldContent world)
  actualContent <- fromCBOR (fields M.! 7)
  checkHash "content" actualContent
  unless (actualContent == expectedContent) (problem "Checkpoint content hash mismatch")
  meta <- CheckpointMeta <$> fromCBOR (fields M.! 4) <*> fromCBOR (fields M.! 14) <*> fromCBOR (fields M.! 15)
  validateMeta meta
  pure (meta,world)

exactFields :: Word64 -> CBOR -> Either CodecError (M.Map Word64 CBOR)
exactFields count (CMap fields) = do
  unless (map fst fields == [0..count-1]) (problem "Unknown or missing mandatory envelope field tag")
  pure (M.fromDistinctAscList fields)
exactFields _ _ = problem "Expected envelope field map"

expectString :: String -> CBOR -> Either CodecError ()
expectString expected term = do
  actual <- fromCBOR term
  unless (actual == expected) (problem ("Unsupported or inconsistent identifier: expected " ++ expected))
expectWord :: Word64 -> CBOR -> String -> Either CodecError ()
expectWord expected term err = do
  actual <- fromCBOR term
  unless (actual == expected) (problem err)

encodeNativeInput :: NativeInput -> Either CodecError BS.ByteString
encodeNativeInput input = do
  validateInputVocabulary input
  body <- toCBOR input
  encodeCanonical (CMap [(0,CText (T.pack inputMagic)),(1,CInteger 1),(2,body)])
decodeNativeInput :: BS.ByteString -> Either CodecError NativeInput
decodeNativeInput bytes = do
  fields <- decodeCanonical bytes >>= exactFields 3
  expectString inputMagic (fields M.! 0)
  expectWord 1 (fields M.! 1) "Unsupported native input codec version"
  input<-fromCBOR (fields M.! 2)
  validateInputVocabulary input
  pure input

validateInputVocabulary :: NativeInput -> Either CodecError()
validateInputVocabulary(Boundary header commands _)=do
  unless(headerRuleset header `elem` supportedRulesets)(problem "UnsupportedRuleset")
  unless(all(commandAllowedInRuleset(headerRuleset header).commandBody)commands)(problem "Input vocabulary is unsupported by profile")

data ReplayHeader = ReplayHeader
  { replayWorldId :: !Word64, replayBranchId :: !Word64
  , replayInitialCheckpointHash :: !BS.ByteString
  , replayRulesetId :: !String, replayContentHash :: !BS.ByteString
  , replayPrngVersion :: !String, replayProtocolVersion :: !Word64
  , replayBuildId :: !String, replayInputCodecVersion :: !Word64
  } deriving (Eq,Show,Generic)
data ReplayFrame = ReplayFrame
  { replayInput :: !NativeInput, replayOutput :: !ColonyOutput, replayStateHash :: !BS.ByteString }
  deriving (Eq,Show,Generic)
data Replay = Replay { replayHeader :: !ReplayHeader, replayFrames :: ![ReplayFrame] }
  deriving (Eq,Show,Generic)
instance ValueCodec ReplayHeader
instance ValueCodec ReplayFrame
instance ValueCodec Replay

validateReplay :: Replay -> Either CodecError ()
validateReplay replay = do
  let header = replayHeader replay
  unless (replayRulesetId header `elem` supportedRulesets) (problem "UnsupportedRuleset")
  unless (replayPrngVersion header == "RDF-RNG-1") (problem "Unsupported replay PRNG version")
  unless (replayProtocolVersion header == 1) (problem "Unsupported replay protocol version")
  unless (replayInputCodecVersion header == 1) (problem "Unsupported replay native input codec version")
  unless (not (null (replayBuildId header))) (problem "Empty replay build ID")
  checkHash "initial checkpoint" (replayInitialCheckpointHash header)
  checkHash "replay content" (replayContentHash header)
  forM_ (replayFrames replay) $ \frame->do
    checkHash "replay frame state" (replayStateHash frame)
    validateInputVocabulary(replayInput frame)
    let output=replayOutput frame;rules=replayRulesetId header
    unless(all(commandAllowedInRuleset rules.receiptBody)(outputReceipts output)&&all(eventAllowedInRuleset rules)(outputEvents output))(problem "Replay output vocabulary is unsupported by profile")
    let Boundary context _ _=replayInput frame
    unless(headerWorld context==replayWorldId header&&headerBranch context==replayBranchId header&&headerRuleset context==replayRulesetId header)(problem "Replay frame world/branch/ruleset differs from replay header")

encodeReplay :: Replay -> Either CodecError BS.ByteString
encodeReplay replay = do
  validateReplay replay
  body <- toCBOR replay
  encodeCanonical (CMap [(0,CText (T.pack replayMagic)),(1,CInteger 1),(2,body),(3,CText (T.pack replayFooter))])
decodeReplay :: BS.ByteString -> Either CodecError Replay
decodeReplay bytes = do
  fields <- decodeCanonical bytes >>= exactFields 4
  expectString replayMagic (fields M.! 0)
  expectWord 1 (fields M.! 1) "Unsupported replay format version"
  expectString replayFooter (fields M.! 3)
  replay <- fromCBOR (fields M.! 2)
  validateReplay replay
  pure replay
