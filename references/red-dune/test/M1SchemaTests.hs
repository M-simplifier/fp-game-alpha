module M1SchemaTests(main,m1SchemaTests) where
import Colony.Codec
import Colony.Arena
import Colony.Scheduler(pureStep)
import Colony.S01Fixture
import Colony.RNG
import Game.Arena(play,singleton,observe)
import Colony.Codec.CBOR
import Colony.Codec.Value
import Colony.CheckpointLibrary
import Colony.Content
import Colony.KnownCatalog
import Colony.ContentCodec(contentIdentity,knownV1ContentId,knownV2ContentId)
import Colony.Construction(emptyConstruction)
import Colony.M1Rules
import Colony.M1State
import Colony.Migrate(legacyV1Fixture,legacyV2Fixture)
import qualified Colony.Space as Space
import Colony.Types
import qualified Colony.Workforce as Workforce
import Colony.World
import Control.Monad(forM_,unless)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.Text as T

assert :: String -> Bool -> IO()
assert label value=unless value(ioError(userError("M1 schema: "++label)))
must :: Show e => String -> Either e a -> IO a
must label=either(ioError . userError . ((label++": ")++) . show)pure
left :: Either a b -> Bool
left(Left _)=True
left _=False
fixture :: Content -> World
fixture content=
  let old=initialWorld content
      space=Space.emptySpatial(Space.MapSpec "schema4-component" 1(Space.Rect(Space.Tile 0 0)128 128)(Space.Tile 192 224)M.empty)
      state=M1State space(Workforce.initialWorkforce(SimTick 0)(worldNeeds old))emptyConstruction M.empty M.empty 500 "S01-short-v1" m1RuleVersion m1RuleHash M.empty
  in old{worldRuleset="red-dune-reference-6",worldM1=Just state}
replaceEnvelope :: Word -> CBOR -> BS.ByteString -> IO BS.ByteString
replaceEnvelope tag value bytes=do
  root<-must "parse envelope"(decodeCanonical bytes)
  case root of
    CMap fields->must "encode mutation"(encodeCanonical(CMap[(k,if toInteger k==toInteger tag then value else v)|(k,v)<-fields]))
    _->ioError(userError "envelope shape")
resignPayload :: CBOR -> BS.ByteString -> IO BS.ByteString
resignPayload term original=do
  payload<-must "mutated payload"(encodeCanonical term)
  a<-replaceEnvelope 16(CBytes payload)original
  b<-replaceEnvelope 11(CInteger(toInteger(BS.length payload)))a
  c<-replaceEnvelope 12(CBytes(sha256 payload))b
  replaceEnvelope 13(CBytes(sha256 payload))c
m1SchemaTests :: Content -> IO()
m1SchemaTests content=do
  assert "trusted compiled content equals normative decoded data"(knownCatalogV1==content)
  forM_[(knownCatalogV1,knownV1ContentId),(knownCatalogV2,knownV2ContentId)]$ \(definition,digest)->do
    canonical<-must "independent full content encoding"(encodeValue definition)
    assert "compiled shortcut is exact canonical SHA256, not a label"(sha256 canonical==digest&&contentIdentity definition==Right digest)
  let tampered=content{contentBuildings=M.adjust(\building->building{buildingWorkers=buildingWorkers building+1})"hand_pump"(contentBuildings content)}
  assert "nearby altered catalog never gets trusted digest"(contentIdentity tampered/=Right knownV1ContentId)
  bytesOnDisk<-BS.readFile "data/m1-rules/rules-v1.json"
  assert "closed numeric contract byte identity"(bytesOnDisk==m1RuleBytes)
  let world=fixture content;meta=CheckpointMeta 6 Nothing "schema4-focused"
  state<-maybe(ioError(userError "fixture absent M1"))pure(worldM1 world)
  bytes<-must "encode schema4"(encodeCheckpoint meta world)
  decoded<-must "decode schema4"(decodeCheckpoint bytes)
  assert "new world roundtrip"(decoded==(meta,world)&&checkpointSchemaFor world==4)
  tree<-must "schema4 tree"(toCBOR world)
  case tree of
    CMap[(0,CInteger 4),(1,CMap[(0,common),(1,extra)])]->do
      case common of
        CMap[(0,CInteger 0),(1,CMap fields)]->assert "schema4 embeds unchanged28-field product"(length fields==28)
        _->assert "legacy product shape"False
      assert "extra fields nonempty"(extra/=CNull)
      bad<-resignPayload common bytes
      assert "M1 common cannot be silently decoded as schema3"(left(decodeCheckpoint bad))
      malformed<-resignPayload(CMap[(0,CInteger 4),(1,CMap[(0,common)])])bytes
      assert "schema4 adjunct mandatory after checksum recomputation"(left(decodeCheckpoint malformed))
    _->assert "schema4 distinct tagged two-field product"False
  forM_ [("legacy profile with extra state",world{worldRuleset="red-dune-reference-4"})
        ,("M1 profile without adjunct",world{worldM1=Nothing})
        ,("unknown numerical digest",world{worldM1=Just state{m1RulesHash=BS.replicate 32 0}})
        ,("changed rule version",world{worldM1=Just state{m1RulesVersion=2}})
        ,("skipped workforce tick",world{simTick=SimTick 1})] $ \(label,bad)->
    assert label(left(encodeCheckpoint meta bad))
  wrongSchema<-replaceEnvelope 5(CInteger 3)bytes
  assert "schema/profile envelope mismatch"(left(decodeCheckpoint wrongSchema))
  unknown<-replaceEnvelope 6(CText(T.pack "red-dune-reference-8"))bytes
  assert "unknown rules"(left(decodeCheckpoint unknown))
  assert "schema4 cannot destructively project legacy1"(left(legacyV1Fixture world))
  assert "schema4 cannot destructively project legacy2"(left(legacyV2Fixture world))
  restored<-must "library restore"(prepareCheckpoint Restore 2 bytes)
  assert "library advertises actual schema4"(preparedSourceSchema restored==4)
  assert "restore preserves all adjuncts"(worldM1(preparedWorld restored)==Just state)
  balanced<-must "library balance6->7"(prepareCheckpoint Balance 3 bytes)
  let target=preparedWorld balanced
  assert "balance profile7 adjunct preservation"(worldRuleset target=="red-dune-reference-7"&&worldM1 target==Just state&&checkpointSchemaFor target==4)
  v2bytes<-must "balanced checkpoint"(encodeCheckpoint meta target)
  _<-must "balanced decode"(decodeCheckpoint v2bytes)
  assert "M1 no rules downgrade"(left(prepareCheckpoint Rules 4 bytes)&&left(prepareCheckpoint RulesBalance 4 bytes))
  assert "profile7 restore only"(left(prepareCheckpoint Balance 5 v2bytes))
  oldBytes<-must "legacy retained"(encodeCheckpoint meta(initialWorld content))
  assert "legacy schema3 retained"(checkpointSchemaFor(initialWorld content)==3)
  oldMismatch<-replaceEnvelope 5(CInteger 4)oldBytes
  assert "legacy envelope cannot claim4"(left(decodeCheckpoint oldMismatch))
  let old=initialWorld content
      planCommand=PlaceConstructionPlan(EntityId 1)(Space.RoadShape(Space.Tile 1 1))2 Nothing
      cid=CommandId 1 1(Epoch "development-authority-1" 1)1
      tx=TxId 1 1(BoundarySeq 0)P1 0
      ordered=[OrderedCommand 0 cid planCommand]
      oldHeader=BoundaryHeader 1 1(BoundarySeq 0)False(worldAuthority old)(worldRuleset old)
      native=Boundary oldHeader ordered[]
      forgedReceipt=CommandReceipt cid(BoundarySeq 0)(Applied(Just(EntityId 2)))tx planCommand
      forgedEvent=ConstructionPlanned(EventId tx 0)(EntityId 2)
  assert "old native encoder rejects new command tag"(left(encodeNativeInput native))
  assert "old direct boundary rejects new command"(fst(pureStep native old)==old&&not(null(outputDiagnostics(snd(pureStep native old)))))
  assert "old Arena rejects new command"(left(play Colony(RecordedBoundary oldHeader[cid][])(singleton 1(OrderedBatch ordered))old))
  assert "old nested receipt vocabulary rejected"(left(encodeCheckpoint meta old{worldReceipts=[forgedReceipt]}))
  assert "old nested event vocabulary rejected"(left(encodeCheckpoint meta old{worldRecentEvents=[forgedEvent]}))
  forM_[old{worldReceipts=[forgedReceipt]},old{worldRecentEvents=[forgedEvent]}]$ \forged->do
    raw<-must "generic forged legacy payload"(toCBOR forged)
    signed<-resignPayload raw oldBytes
    assert "legacy vocabulary fails even after valid outer checksum"(left(decodeCheckpoint signed))
  oldHash<-must "old hash"(canonicalStateHash old)
  contentDigest<-must "content digest"(contentHash content)
  let header=ReplayHeader 1 1(sha256 oldBytes)(worldRuleset old)contentDigest "RDF-RNG-1" 1 "legacy-vocabulary-negative" 1
      emptyInput=Boundary oldHeader[][]
      replay=Replay header[ReplayFrame emptyInput(ColonyOutput[forgedEvent][forgedReceipt][])oldHash]
  assert "legacy replay output cannot smuggle new vocab"(left(encodeReplay replay))
  (descriptor,actual)<-must "actual S01 observable fixture"(s01Fixture content)
  let changedSecrets=actual{worldRng=initialRng 99}
  assert "M1 public observation ignores private RNG"(observe Colony 1 actual==observe Colony 1 changedSecrets)
  case observe Colony 1 actual of
    ColonyViewM1{}->pure()
    _->assert "actual M1 Arena projection constructor"False
  let m1Header=oldHeader{headerRuleset=worldRuleset actual,expectedBoundarySeq=boundarySeq actual}
      permitted=Boundary m1Header[OrderedCommand 0 cid(PlaceConstructionPlan(s01Colony descriptor)(Space.RoadShape(Space.Tile 61 64))2 Nothing)][]
  inputBytes<-must "M1 public input canonical encoding"(encodeNativeInput permitted)
  assert "M1 input decode preserves typed target/shape"(decodeNativeInput inputBytes==Right permitted)
  putStrLn("M1_SCHEMA schema3/4 profile6/7 typed-shape/hash/tamper/balance/restore PASS rules="++sha256Hex m1RuleBytes)
main :: IO()
main=loadContent "data/content-v1.json" >>= must "content" >>= m1SchemaTests
