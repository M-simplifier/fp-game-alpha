module SessionTests(sessionTests) where
import Colony.UIShell(nextLocalCommandSequence)
import Colony.Session
import Colony.SessionTrace
import Colony.CheckpointLibrary(RestoreAction(Restore))
import Colony.Codec.CBOR
import qualified Data.Text as T
import Colony.Codec
import Colony.Content
import Colony.Fixture
import Colony.JSON
import Colony.Save
import Colony.Scheduler
import Colony.Types
import Colony.World
import Control.Concurrent(forkIO,newEmptyMVar,putMVar,takeMVar)
import Control.Monad(forM_,replicateM,unless)
import qualified Data.ByteString as BS
import Data.Char(toUpper)
import Data.Either(isLeft)
import Data.IORef(newIORef,atomicModifyIORef')
import Data.List(sort)
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.Word(Word64)

assert :: String -> Bool -> IO()
assert label condition=unless condition(fail("Session: "++label))
right :: Show e => Either e a -> IO a
right=either(fail.show)pure

sessionTests :: Content -> IO()
sessionTests content=do
  goldenBytes<-BS.readFile "data/session/activation-v1-golden.cbor"
  let goldenRecord=ActivationRecord 1 "restore"(BS.replicate 32 17)(BS.replicate 32 34)99 "11111111-2222-4333-8444-555555555555"(BS.replicate 32 51)
  actualGolden<-right(encodeActivationRecord goldenRecord)
  decodedGolden<-right(decodeActivationRecord goldenBytes)
  assert "activation stable-tag CBOR matches independent explicit encoder"(actualGolden==goldenBytes&&decodedGolden==goldenRecord)
  raw<-readFile "data/session/uuid-v4-golden.json"
  rows<-right(parseJSON raw >>= array)
  forM_ rows $ \value->do
    fields<-right(object value)
    numbers<-right(field "bytes" fields >>= array >>= mapM integer)
    expected<-right(field "uuid" fields >>= string)
    actual<-right(uuidV4FromBytes(BS.pack(map fromInteger numbers)))
    assert "UUIDv4 format matches Python standard-library64-row oracle"(actual==expected&&validUUIDv4 actual)
  assert "UUID requires exact entropy length"(isLeft(uuidV4FromBytes BS.empty)&&isLeft(uuidV4FromBytes(BS.replicate 17 1)))
  calls<-newIORef(0::Integer)
  let repeated=atomicModifyIORef' calls(\n->(n+1,BS.replicate 16 0))
  factory<-newAuthorityFactoryWith repeated
  first<-newSession factory S.empty >>= right
  collision<-newSession factory S.empty
  count<-atomicModifyIORef' calls(\n->(n,n))
  assert "repeated entropy fails after bounded16 collisions, without reuse"(case collision of Left AuthorityCollision->count==17;_->False)
  upperFactory<-newAuthorityFactoryWith(pure(BS.replicate 16 0))
  excluded<-newSession upperFactory(S.singleton(map toUpper(sessionAuthority first)))
  assert "known imported UUID is excluded case-insensitively"(case excluded of Left AuthorityCollision->True;_->False)
  failureFactory<-newAuthorityFactoryWith(ioError(userError "injected entropy source failure"))
  failed<-newSession failureFactory S.empty
  assert "entropy failure is not replaced by clock/game RNG"(case failed of Left(EntropyUnavailable _)->True;_->False)
  freshFactory<-newAuthorityFactory
  observed<-replicateM 32(newSession freshFactory S.empty >>= right)
  assert "real OS source produces32 observed distinct valid UUIDs"(all(validUUIDv4.sessionAuthority)observed&&S.size(S.fromList(map sessionAuthority observed))==32)
  let shared=head observed
  boxes<-replicateM 32 newEmptyMVar
  forM_ boxes $ \box->do
    _<-forkIO(replicateM 32(issueRequest shared >>= right) >>= putMVar box)
    pure()
  issued<-concat <$> mapM takeMVar boxes
  assert "1024 concurrent requests have unique monotonic serials"(sort(map requestSerial issued)==[1..1024]&&S.size(S.fromList issued)==1024)
  assert "all request tickets bind their issuing epoch"(all(\(RequestToken epoch _)->epoch==sessionEpoch shared)issued)
  edge<-newSessionStartingAt freshFactory S.empty(maxBound-1) >>= right
  lastTicket<-issueRequest edge >>= right
  exhausted<-issueRequest edge
  stillExhausted<-issueRequest edge
  assert "maxBound cannot wrap or be retried into ticket reuse"(requestSerial lastTicket==(maxBound::Word64)-1&&exhausted==Left RequestSerialExhausted&&stillExhausted==Left RequestSerialExhausted)
  zero<-newSessionStartingAt freshFactory S.empty 0
  assert "zero request start rejected"(case zero of Left InvalidSerialStart->True;_->False)
  base<-right(fourColonyFixture content)
  let sites=M.elems(worldSites base);sourceSite=head sites;targetSite=sites!!1
      boundary world active commands=Boundary(BoundaryHeader(worldId world)(branchId world)(boundarySeq world)active(worldAuthority world)(worldRuleset world))commands[]
      originalInput=boundary base True[OrderedCommand 0(CommandId(worldId base)1(participantEpoch(worldParticipants base M.!1))1)(OrderProduction(siteId sourceSite))]
      (old,oldOut)=pureStep originalInput base
  assert "source world is an actual started kernel state"(null(outputDiagnostics oldOut)&&not(M.null(worldJobs old)))
  saved<-right(encodeCheckpoint defaultCheckpointMeta old)
  (_,decoded)<-right(decodeCheckpoint saved)
  fresh<-newSession freshFactory(worldAuthorities decoded) >>= right
  restored<-right(activateWorldSession fresh 2 decoded)
  liveHash<-right(canonicalStateHash old)
  activation<-right(makeActivationRecord Restore saved liveHash restored)
  activationBytes<-right(encodeActivationRecord activation)
  decodedActivation<-right(decodeActivationRecord activationBytes)
  replayedActivation<-right(replayActivation decodedActivation old saved)
  assert "versioned activation CBOR replays exact session/gameplay state"(decodedActivation==activation&&replayedActivation==restored)
  let differentLive=(initialWorld content){worldId=9,branchId=branchId restored}
  differentLiveHash<-right(canonicalStateHash differentLive)
  crossWorldRecord<-right(makeActivationRecord Restore saved differentLiveHash restored)
  crossWorldReplayed<-right(replayActivation crossWorldRecord differentLive saved)
  assert "branch numbers are scoped by world identity in trace replay"(crossWorldReplayed==restored)
  assert "activation rejects live/source/target mismatch"(isLeft(replayActivation activation restored saved)&&isLeft(replayActivation activation old(saved<>BS.singleton 0))&&isLeft(replayActivation activation{activationTargetHash=BS.replicate 32 0}old saved))
  assert "activation rejects old authority and unknown action/version"(isLeft(replayActivation activation{activationAuthority=worldAuthority old}old saved)&&isLeft(encodeActivationRecord activation{activationAction="other"})&&isLeft(encodeActivationRecord activation{activationVersion=2}))
  genericValue<-right(decodeCanonical activationBytes)
  unknownWire<-right(encodeCanonical(case genericValue of CMap fields->CMap(fields++[(99,CText(T.pack "unknown"))]);other->other))
  assert "activation CBOR rejects trailing/unknown mandatory fields"(isLeft(decodeActivationRecord(activationBytes<>BS.singleton 0))&&isLeft(decodeActivationRecord unknownWire))
  let oldEpoch=participantEpoch(worldParticipants old M.!1)
      oldExhausted=restored{worldHighWater=M.insert(1,oldEpoch)maxBound(worldHighWater restored)}
      currentExhausted=restored{worldHighWater=M.insert(1,sessionEpoch fresh)maxBound(worldHighWater restored)}
  assert "old exhausted epoch does not block fresh command sequence"(nextLocalCommandSequence oldExhausted==Right 1)
  assert "current exhausted command sequence refuses wrap"(isLeft(nextLocalCommandSequence currentExhausted))
  assert "malformed source is not repaired by branch replacement"(isLeft(activateWorldSession fresh 2 decoded{branchId=0}))
  let normalized=restored{branchId=branchId old,worldAuthority=worldAuthority old,worldParticipants=worldParticipants old,worldHighWater=worldHighWater old,worldMode=worldMode old}
  assert "activation preserves all non-session gameplay state including RNG/WIP/history"(normalized==old&&worldMode restored==Paused&&worldAuthority restored==sessionAuthority fresh)
  assert "old sequence high-water archive remains"(all(\(key,value)->M.lookup key(worldHighWater restored)==Just value)(M.toList(worldHighWater old)))
  assert "archive bytes unchanged after activation"(encodeCheckpoint defaultCheckpointMeta old==Right saved)
  let stale=boundary old False[OrderedCommand 0(CommandId(worldId old)1(participantEpoch(worldParticipants old M.!1))2)(OrderProduction(siteId targetSite))]
      (unchanged,rejected)=pureStep stale restored
  assert "old branch/authority command cannot apply after load"(unchanged==restored&&not(null(outputDiagnostics rejected))&&null(outputReceipts rejected))
  let freshCommand=OrderedCommand 0(CommandId(worldId restored)1(sessionEpoch fresh)1)(OrderProduction(siteId targetSite))
      (progressed,out)=pureStep(boundary restored False[freshCommand])restored
  assert "fresh epoch sequence1 reaches real production planning"(null(outputDiagnostics out)&&M.size(worldJobs progressed)==M.size(worldJobs restored)+1)
  assert "same branch and reused authority activation refused"(isLeft(activateWorldSession fresh(branchId old)decoded)&&isLeft(activateWorldSession fresh 3 restored))
  let abandoned=decoded{worldMode=Abandoned}
  abandonedCopy<-right(activateWorldSession fresh 2 abandoned)
  assert "load never resurrects an abandoned world"(worldMode abandonedCopy==Abandoned)
  let oldTicket=SaveTicket(identityFor(sessionEpoch first)old)1 ManualSave
      newTicket=SaveTicket(identityFor(sessionEpoch fresh)restored)1 ManualSave
      (_,queue)=enqueueSave newTicket(emptySaveQueue(ticketIdentity newTicket))
  assert "same serial across fresh authorities is distinct; old callback rejected"(oldTicket/=newTicket&&fst(finishSave oldTicket queue)==False&&queueActive(snd(finishSave oldTicket queue))==Just newTicket)
  putStrLn "SessionTests PASS:64 independent UUID vectors; bounded collisions/entropy errors/case normalization;32 real OS UUID observations;1024 concurrent unique tickets; overflow/no reset; versioned activation CBOR golden/replay; actual archive activation/new command, old command/callback rejection and complete gameplay-state preservation"
  putStrLn "UUID observations are not a mathematical uniqueness proof. Concrete freshness assumes the OS random source and a fresh UUID; saved epochs never reset the private request issuer."
