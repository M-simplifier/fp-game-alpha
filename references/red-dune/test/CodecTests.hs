{-# LANGUAGE ScopedTypeVariables #-}
module CodecTests (codecTests) where

import Colony.Codec
import Colony.Codec.CBOR
import Colony.Codec.Value
import Colony.Content
import Colony.Inventory
import Colony.Jobs
import Colony.Power
import Colony.Scheduler (pureStep)
import Colony.RNG
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad (forM_,unless)
import qualified Data.ByteString as BS
import Data.Bits (xor)
import Data.Either (isLeft)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Word (Word64)
import SHA256Tests (sha256Tests)

assert :: String -> Bool -> IO ()
assert label passed = unless passed (ioError (userError ("Codec assertion failed: " ++ label)))
must :: Show e => String -> Either e a -> IO a
must label = either (ioError . userError . ((label ++ ": ") ++) . show) pure

codecTests :: Content -> IO ()
codecTests content = do
  sha256Tests
  testCanonicalProfile
  testValueSchema
  world <- sampleWorld content
  let meta = CheckpointMeta 17 (Just (BS.replicate 32 42)) "test-build-GHC"
  encoded <- must "checkpoint encode" (encodeCheckpoint meta world)
  decoded <- must "checkpoint decode" (decodeCheckpoint encoded)
  assert "checkpoint roundtrip" (decoded == (meta,world))
  assert "checkpoint deterministic bytes" (encodeCheckpoint meta world == Right encoded)
  reencoded <- must "checkpoint canonical reencode" (uncurry encodeCheckpoint decoded)
  assert "checkpoint reencode byte equality" (reencoded == encoded)
  let inventory = worldInventory world
      world' = world {worldInventory=inventory {invLots=M.fromList(reverse(M.toList(invLots inventory)))}}
  assert "map insertion order does not alter canonical bytes" (encodeCheckpoint meta world' == Right encoded)
  hash <- must "canonical state hash" (canonicalStateHash world)
  payload <- must "canonical world bytes" (canonicalWorldBytes world)
  assert "state hash is pure SHA256 canonical payload" (hash == sha256 payload)
  encodedOtherMeta <- must "different envelope metadata" (encodeCheckpoint meta {checkpointSequence=18,checkpointBuildId="different-build"} world)
  assert "envelope metadata can differ without changing state hash" (encodedOtherMeta /= encoded && canonicalStateHash world == Right hash)
  assert "reject trailing garbage" (isLeft (decodeCheckpoint (encoded <> BS.singleton 0)))
  assert "reject truncated envelope" (isLeft (decodeCheckpoint (BS.init encoded)))
  assert "reject input-byte budget before parsing" (isLeft (decodeCheckpointWith defaultDecodeLimits {maxPayloadBytes=16} encoded))
  forM_ [1,2,3,5,6,7,8,9,10,11,12,13,17] $ \tag -> do
    let replacement = case tag of
          6 -> CText (T.pack "unknown-ruleset")
          7 -> CBytes (BS.replicate 32 3)
          8 -> CText (T.pack "unknown-prng")
          12 -> CBytes (BS.replicate 32 4)
          13 -> CBytes (BS.replicate 32 4)
          17 -> CText (T.pack "incomplete")
          _ -> CInteger 999999
    changed <- mutateEnvelope encoded tag replacement
    assert ("reject inconsistent header tag " ++ show tag) (isLeft (decodeCheckpoint changed))
  root <- must "decode envelope tree" (decodeCanonical encoded)
  case root of
    CMap fields -> do
      unknown <- must "add unknown field" (encodeCanonical (CMap(fields++[(18,CNull)])))
      assert "reject unknown mandatory envelope tag" (isLeft (decodeCheckpoint unknown))
      missing <- must "remove mandatory field" (encodeCanonical (CMap(filter((/=15).fst)fields)))
      assert "reject missing mandatory envelope tag" (isLeft (decodeCheckpoint missing))
    _ -> assert "envelope is map" False
  let invalidRng=world {worldRng=(worldRng world) {weatherRng=Rng 0 0}}
      invalidSeed=world {worldRng=(worldRng world) {rngNormalizedSeed=42}}
      invalidLedger=world {worldInventory=inventory {invLedger=M.empty}}
      invalidReference=world {worldInventory=inventory {invLots=M.map(\lot->lot {lotOwner=Owner Warehouse(EntityId 999999)}) (invLots inventory)}}
      invalidContent=world {worldContent=content {contentQuantityMax=99}}
      invalidCatalog=world {worldInventory=inventory {invLoad=M.insert Water 3 (invLoad inventory)}}
  forM_ [("zero RNG",invalidRng),("bad seed marker",invalidSeed),("broken conservation",invalidLedger),("dangling owner",invalidReference),("invalid content",invalidContent),("catalog mismatch",invalidCatalog)] $ \(label,badWorld)->do
    assert ("invalid world cannot encode: "++label) (isLeft (encodeCheckpoint meta badWorld))
    badPayload <- must "encode malformed typed payload" (encodeValue badWorld)
    resigned <- replacePayload encoded badPayload
    assert ("semantic invalidity rejected after valid checksum: "++label) (isLeft (decodeCheckpoint resigned))
  -- A payload whose checksum is genuinely wrong must be rejected before any
  -- quantity/record decode; a valid checksum never bypasses semantic checks.
  corrupted <- mutateEnvelope encoded 16 (CBytes (flipFirst payload))
  assert "one-byte corruption rejected" (isLeft (decodeCheckpoint corrupted))
  let oversizedInventory = inventory {invStorage=M.fromDistinctAscList
        [(Owner Warehouse(EntityId n),Storage 0 Nothing(EntityId 1)) | n<-[1..200000]]}
  assert "aggregate entity cap checked before semantic validation/encoding"
    (encodeCheckpoint meta world {worldInventory=oversizedInventory} == Left(CodecError "World entity count exceeds 200000"))
  let unorderedGrid=PowerGrid(EntityId 300)[Solar(EntityId 302)100,Solar(EntityId 301)100][] [] M.empty
  assert "semantic power-device set rejects nonascending IDs"
    (isLeft(encodeCheckpoint meta world {worldPowerGrids=M.singleton(EntityId 300)unorderedGrid}))
  qtyTerm <- must "world tree" (toCBOR world)
  let invalidQtyTerm = recordField 9 (recordField 2 (firstMapValue (recordField 2 (const (CInteger (quantityMax+1)))))) qtyTerm
  invalidQtyPayload <- must "encode quantity outside smart constructor" (encodeCanonical invalidQtyTerm)
  invalidQtyCheckpoint <- replacePayload encoded invalidQtyPayload
  assert "malicious Qty over limit rejected after checksum validation" (isLeft (decodeCheckpoint invalidQtyCheckpoint))
  let commands = [OrderedCommand 9 (CommandId 1 1 (Epoch "development-authority-1" 1) 9) (SetSiteEnabled (EntityId 43) False),
                  OrderedCommand 2 (CommandId 1 1 (Epoch "development-authority-1" 1) 2) (OrderProduction (EntityId 11))]
      input = Boundary (BoundaryHeader 1 1 (BoundarySeq 0) True "development-authority-1" supportedRuleset) commands [ResumeWorld,PauseWorld]
      output = ColonyOutput [] [CommandReceipt (commandId (head commands)) (BoundarySeq 0) (CommandFailed MissingStock) (TxId 1 1 (BoundarySeq 0) P2 9) (commandBody(head commands))] [FatalBoundaryRejected "intentional test"]
  inputBytes <- must "native input encode" (encodeNativeInput input)
  assert "native input ordered command list preserved, not sorted" (decodeNativeInput inputBytes == Right input)
  cHash <- must "content hash" (contentHash content)
  let header = ReplayHeader 1 1 (sha256 encoded) supportedRuleset cHash "RDF-RNG-1" 1 "test-build-GHC" 1
      replay = Replay header [ReplayFrame input output hash,ReplayFrame input mempty hash]
  replayBytes <- must "replay encode" (encodeReplay replay)
  assert "replay roundtrip preserves frames/receipts/events/input" (decodeReplay replayBytes == Right replay)
  assert "truncated replay cannot claim complete" (isLeft (decodeReplay (BS.init replayBytes)))
  assert "unavailable old ruleset cannot claim successful replay" (isLeft (encodeReplay replay {replayHeader=header {replayRulesetId="old-unsupported"}}))
  assert "protocol version not silently upgraded" (isLeft (encodeReplay replay {replayHeader=header {replayProtocolVersion=42}}))
  assert "frame hash requires 32 bytes" (isLeft (encodeReplay replay {replayFrames=[ReplayFrame input output BS.empty]}))
  testEveryBoundaryRoundtrip content
  putStrLn "Canonical CBOR/checkpoint/replay: profile, bounded corruption, semantic validation and ordered roundtrip tests passed"

sampleWorld :: Content -> IO World
sampleWorld content = do
  let owner=Owner Warehouse (EntityId 100)
      tx=TxId 1 1 (BoundarySeq 0) P0 0
      action=do
        addStorage owner (Storage 2000000 Nothing(EntityId 1))
        _<-mintLot tx InitialGrant Nothing Water 1000 owner (SimTick 0) Nothing "fixture water"
        _<-mintLot tx InitialGrant Nothing Crops 50 owner (SimTick 0) (Just(SimTick 300)) "fixture crops"
        pure ()
  (_,inventory)<-must "sample inventory" (runInventory action (worldInventory(initialWorld content)))
  pure (initialWorld content) {worldInventory=inventory}

mutateEnvelope :: BS.ByteString -> Word64 -> CBOR -> IO BS.ByteString
mutateEnvelope encoded tag value = do
  root <- must "envelope parse for mutation" (decodeCanonical encoded)
  case root of
    CMap fields -> must "envelope mutation encoding" (encodeCanonical(CMap(map(\(key,old)->(key,if key==tag then value else old))fields)))
    _ -> ioError(userError "not envelope map")

replacePayload :: BS.ByteString -> BS.ByteString -> IO BS.ByteString
replacePayload encoded payload = do
  a<-mutateEnvelope encoded 16 (CBytes payload)
  b<-mutateEnvelope a 11 (CInteger(toInteger(BS.length payload)))
  c<-mutateEnvelope b 12 (CBytes(sha256 payload))
  mutateEnvelope c 13 (CBytes(sha256 payload))

flipFirst :: BS.ByteString -> BS.ByteString
flipFirst bytes = case BS.uncons bytes of
  Nothing -> BS.singleton 0
  Just(x,rest)->BS.cons (x `xor` 1) rest
recordField :: Word64 -> (CBOR->CBOR) -> CBOR -> CBOR
recordField tag f (CMap [(0,constructor),(1,CMap fields)]) = CMap [(0,constructor),(1,CMap(map(\(k,v)->(k,if k==tag then f v else v))fields))]
recordField _ _ other = other
firstMapValue :: (CBOR->CBOR) -> CBOR -> CBOR
firstMapValue f (CArray(CArray[key,value]:xs)) = CArray(CArray[key,f value]:xs)
firstMapValue _ other = other

testCanonicalProfile :: IO ()
testCanonicalProfile = do
  let vectors = [(CInteger 0,[0]),(CInteger 23,[23]),(CInteger 24,[24,24]),(CInteger 255,[24,255]),
        (CInteger 256,[25,1,0]),(CInteger 65535,[25,255,255]),(CInteger 65536,[26,0,1,0,0]),
        (CInteger 4294967296,[27,0,0,0,1,0,0,0,0]),
        (CInteger (-1),[32]),(CInteger (-25),[56,24]),(CBool False,[244]),(CBool True,[245]),(CNull,[246]),
        (CText(T.pack "a"),[97,97]),(CBytes(BS.pack[1,2]),[66,1,2]),
        (CArray[CInteger 1,CInteger 2],[130,1,2]),(CMap[(0,CInteger 1),(24,CNull)],[162,0,1,24,24,246])]
  forM_ vectors $ \(term,raw)->do
    assert ("RFC canonical encode "++show term) (encodeCanonical term == Right(BS.pack raw))
    assert ("RFC canonical decode "++show term) (decodeCanonical(BS.pack raw) == Right term)
  forM_ [("overlong integer",[24,0]),("overlong negative",[56,1]),("overlong text length",[120,1,97]),
         ("overlong array length",[152,0]),("overlong map length",[184,0]),("truncated integer",[27,1]),
         ("indefinite array",[159,255]),("indefinite map",[191,255]),("indefinite bytes",[95,255]),
         ("semantic tag",[192,0]),("float16",[249,0,0]),("float32",[250,0,0,0,0]),
         ("float64",[251,0,0,0,0,0,0,0,0]),("extended false",[248,20]),("undefined",[247]),
         ("invalid UTF8",[97,255]),("duplicate map key",[162,0,0,0,1]),
         ("map keys reversed",[162,1,0,0,0]),("nonunsigned map key",[161,97,97,0]),
         ("huge bytes declaration",[91,255,255,255,255,255,255,255,255]),
         ("huge array declaration",[155,255,255,255,255,255,255,255,255]),
         ("huge map declaration",[187,255,255,255,255,255,255,255,255]),
         ("truncated array",[131,1]),("truncated map",[162,0,0]),("empty input",[]),
         ("trailing bytes",[0,0])] $ \(label,raw)->assert label (isLeft(decodeCanonical(BS.pack raw)))
  assert "depth64 accepted" (not(isLeft(decodeCanonical(BS.replicate 63 129<>BS.singleton 0))))
  assert "depth65 rejected" (isLeft(decodeCanonical(BS.replicate 64 129<>BS.singleton 0)))
  assert "declared nodes checked before item parse" (isLeft(decodeCanonicalWith defaultDecodeLimits {maxNodes=2} (BS.pack[130,0,0])))
  assert "text cap checked before allocation" (isLeft(decodeCanonicalWith defaultDecodeLimits {maxTextBytes=1} (BS.pack[98,97,98])))
  assert "container cap checked before allocation" (isLeft(decodeCanonicalWith defaultDecodeLimits {maxContainerItems=1} (BS.pack[130,0,0])))
  assert "encoder rejects noncanonical map" (isLeft(encodeCanonical(CMap[(1,CNull),(0,CNull)])))
  assert "encoder rejects duplicate map key" (isLeft(encodeCanonical(CMap[(0,CNull),(0,CNull)])))
  assert "bignum profile forbidden" (isLeft(encodeCanonical(CInteger(2^(64::Int)))))
  forM_ [0..255] $ \n -> do
    let bytes=BS.singleton n
    case decodeCanonical bytes of
      Left _ -> pure ()
      Right value -> assert "all accepted one-byte CBOR reencodes identically" (encodeCanonical value == Right bytes)

testValueSchema :: IO ()
testValueSchema = do
  assert "frozen EntityId tag/field golden" (encodeValue(EntityId 24)==Right(BS.pack[162,0,0,1,161,0,24,24]))
  assert "unknown constructor rejected" (isLeft(fromCBOR(CMap[(0,CInteger 999),(1,CMap[])])::Either CodecError Resource))
  assert "unknown mandatory record field rejected" (isLeft(fromCBOR(CMap[(0,CInteger 0),(1,CMap[(0,CInteger 1),(1,CNull)])])::Either CodecError EntityId))
  assert "missing mandatory record field rejected" (isLeft(fromCBOR(CMap[(0,CInteger 0),(1,CMap[])])::Either CodecError EntityId))
  assert "negative unsigned rejected" (isLeft(fromCBOR(CInteger(-1))::Either CodecError Word64))
  assert "Qty negative rejected via mkQty" (isLeft(fromCBOR(CInteger(-1))::Either CodecError (Qty StockUnit)))
  assert "Qty over max rejected via mkQty" (isLeft(fromCBOR(CInteger(quantityMax+1))::Either CodecError (Qty StockUnit)))
  assert "Qty zero accepted" (fmap qtyValue(fromCBOR(CInteger 0)::Either CodecError(Qty StockUnit))==Right 0)
  assert "Qty maximum accepted" (fmap qtyValue(fromCBOR(CInteger quantityMax)::Either CodecError(Qty StockUnit))==Right quantityMax)
  assert "invalid surrogate not silently replaced" (isLeft(encodeValue(['\xD800']::String)))
  unicode <- must "UTF8 encode" (encodeValue ("水 / café / 🪐"::String))
  assert "UTF8 roundtrip" ((decodeValue unicode::Either CodecError String)==Right "水 / café / 🪐")
  assert "unordered map IDs rejected" (isLeft(fromCBOR(CArray[CArray[CInteger 2,CBool True],CArray[CInteger 1,CBool False]])::Either CodecError(M.Map Word64 Bool)))
  assert "duplicate map IDs rejected" (isLeft(fromCBOR(CArray[CArray[CInteger 1,CBool True],CArray[CInteger 1,CBool False]])::Either CodecError(M.Map Word64 Bool)))
  assert "set stable order encoding" (toCBOR(S.fromList[3,1,2]::S.Set Word64)==Right(CArray(map CInteger[1,2,3])))
  assert "duplicate set IDs rejected" (isLeft(fromCBOR(CArray[CInteger 1,CInteger 1])::Either CodecError(S.Set Word64)))


-- Same fixed ordered input stream drives two worlds. One persists and restores
-- after every boundary, including running WIP, pause/resume, food expiry,
-- cancellation, duplicate retry receipts, power state and new reservations.
testEveryBoundaryRoundtrip :: Content -> IO ()
testEveryBoundaryRoundtrip content = do
  let source=Owner Warehouse(EntityId 100)
      output=Owner Warehouse(EntityId 101)
      tx=TxId 1 1 (BoundarySeq 0) P0 0
      action=do
        addStorage source(Storage 2000000 Nothing(EntityId 1))
        addStorage output(Storage 2000000 Nothing(EntityId 1))
        _<-mintLot tx InitialGrant Nothing Ore 50000 source (SimTick 10800) Nothing "suffix ore"
        _<-mintLot tx InitialGrant Nothing Fuel 20000 source (SimTick 10800) Nothing "suffix fuel"
        _<-mintLot tx InitialGrant Nothing Crops 30000 source (SimTick 10800) (Just(SimTick 10950)) "suffix crops"
        _<-mintLot tx InitialGrant Nothing Water 20000 source (SimTick 10800) Nothing "suffix water"
        pure()
  (_,inventory)<-must "suffix inventory fixture" (runInventory action(worldInventory(initialWorld content)))
  let site ident recipe=Site(EntityId ident)recipe source output M.empty 100 True
      grid=PowerGrid(EntityId 300)[Solar(EntityId 301)100,Solar(EntityId 302)100][] [] M.empty
      world=(initialWorld content) {worldInventory=inventory {invNextId=303},simTick=SimTick 10800,
        worldSites=M.fromList[(EntityId 200,site 200 "smelt"),(EntityId 201,site 201 "cook")],
        worldPowerGrids=M.singleton(EntityId 300)grid,
        worldSiteGrids=M.fromList[(EntityId 200,EntityId 300),(EntityId 201,EntityId 300)]}
  _<-must "suffix initial checkpoint" (encodeCheckpoint defaultCheckpointMeta world)
  finalWorld<-go (1::Word64) world world Nothing
  assert "suffix includes terminal cancellation" (any((==Cancelled).jobPhase)(M.elems(worldJobs finalWorld)))
  assert "suffix includes food-expiry job failure" (any((==Failed ExpiredInput).jobPhase)(M.elems(worldJobs finalWorld)))
  assert "suffix includes running physical WIP" (any((==Running).jobPhase)(M.elems(worldJobs finalWorld)))
  assert "suffix power state persisted" (any((>0) . M.findWithDefault 0 SolarGenerated . gridEnergyLedger)(M.elems(worldPowerGrids finalWorld)))
  putStrLn "Same-ruleset every-boundary checkpoint restoration equals uninterrupted simulation: 320 boundaries with WIP, pause/resume, expiry, cancellation, retry and power"
  where
    go n plain restored firstJob
      | n>320 = pure plain
      | otherwise = do
          let command ordinal sequenceNumber body=OrderedCommand ordinal(CommandId 1 1(Epoch "development-authority-1" 1)sequenceNumber)body
              commands
                | n==1=[command 0 1(OrderProduction(EntityId 200)),command 1 2(OrderProduction(EntityId 201))]
                | n==160=maybe [] (\ident->[command 0 3(CancelProduction ident)]) firstJob
                | n==180=[command 0 4(OrderProduction(EntityId 200))]
                | n==190=maybe [] (\ident->[command 0 3(CancelProduction ident)]) firstJob
                | otherwise=[]
              management | n==80=[PauseWorld] | n==81=[ResumeWorld] | otherwise=[]
              input=Boundary(BoundaryHeader(worldId plain)(branchId plain)(boundarySeq plain)(null management)(worldAuthority plain)(worldRuleset plain))commands management
              (next,expectedOutput)=pureStep input plain
              (nextSaved,savedOutput)=pureStep input restored
              foundJob=case firstJob of
                Just ident->Just ident
                Nothing->case [jobId job|job<-M.elems(worldJobs next),jobRecipe job=="smelt"] of
                  ident:_->Just ident
                  []->Nothing
          assert ("same suffix world boundary "++show n) (next==nextSaved)
          assert ("same suffix receipts/events boundary "++show n) (expectedOutput==savedOutput)
          assert ("suffix no fatal diagnostic boundary "++show n) (null(outputDiagnostics expectedOutput))
          encoded<-must "every-boundary checkpoint" (encodeCheckpoint defaultCheckpointMeta {checkpointSequence=n} nextSaved)
          (_,loaded)<-must "every-boundary restore" (decodeCheckpoint encoded)
          assert ("every-boundary exact state restore "++show n) (loaded==next)
          go (n+1) next loaded foundJob
