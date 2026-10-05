{-# LANGUAGE ScopedTypeVariables #-}
-- | Line-delimited local shell. Only Game.Arena.play can mutate World. Save IO
-- runs on another thread from a strict P10 snapshot and cannot freeze ticks.
module Colony.UIShell (runUIShell,decodeUICommand) where
import Colony.Arena
import Colony.Codec
import Colony.Content
import qualified Colony.JSON as J
import Colony.Presentation
import Colony.Save
import Colony.Types
import Colony.UIFixture
import Colony.Units
import Colony.World
import Control.Concurrent (forkIO,threadDelay)
import Control.Concurrent.MVar
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (foldM,unless,void)
import qualified Data.Map.Strict as M
import Data.IORef
import Data.Word (Word64)
import Game.Arena (play,singleton)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectoryIfMissing)
import System.IO
import System.Posix.Time (epochTime)
import Text.Read (readMaybe)

-- World is private to this serial loop; workers receive captured bytes only.
data Runtime = Runtime { rtWorld :: !World, rtQueue :: !SaveQueue, rtSerial :: !Word64
  , rtIdentity :: !(IORef SaveIdentity), rtSaveState :: !(IORef J.JSON)
  , rtFinished :: !(MVar (SaveTicket,SaveResult)), rtSaveDirectory :: !FilePath
  , rtTrace :: !Handle }

runUIShell :: Content -> IO ()
runUIShell content=do
  hSetBuffering stdout LineBuffering
  hSetEncoding stdin utf8
  hSetEncoding stdout utf8
  (_,initial)<-either(fail.show)pure(uiFixture content)
  createDirectoryIfMissing True "evidence/ui/runtime-saves"
  createDirectoryIfMissing True "evidence/ui"
  traceHandle<-openFile "evidence/ui/native-boundaries.log" AppendMode
  hSetBuffering traceHandle LineBuffering
  sessionEpoch<-getMonotonicTimeNSec
  let identity=identityFor(Epoch "ui-native-session" sessionEpoch)initial
  identityRef<-newIORef identity
  saveRef<-newIORef(obj[("status",str "neverSaved"),("capturedTick",J.JNull),("lastSuccess",J.JNull)])
  completed<-newEmptyMVar
  loop(Runtime initial(emptySaveQueue identity)1 identityRef saveRef completed "evidence/ui/runtime-saves" traceHandle)
  where
    loop runtime=do
      ended<-hIsEOF stdin
      unless ended $ do
        line<-getLine
        ready<-finishCompleted runtime
        (next,result)<-case if length line>65536 then Left "Request too long" else J.parseJSON line >>= J.object of
          Left err->pure(ready,errorJSON "decodeRejected" err)
          Right request->dispatch ready request
        state<-stateJSON next
        putStrLn(encodeJSON(obj[("result",result),("view",presentation(rtWorld next)),("save",state)]))
        loop next

stateJSON :: Runtime -> IO J.JSON
stateJSON runtime=do
  status<-readIORef(rtSaveState runtime)
  pure(obj[("current",status),("pending",J.JBool(queueManual(rtQueue runtime)/=Nothing||queueAutosave(rtQueue runtime)/=Nothing))])
errorJSON :: String -> String -> J.JSON
errorJSON category reason=obj[("status",str category),("reason",str reason)]
okJSON :: String -> J.JSON
okJSON status=obj[("status",str status)]
getString :: String -> M.Map String J.JSON -> Either String String
getString k o=J.field k o >>= J.string
getWord :: String -> M.Map String J.JSON -> Either String Word64
getWord k o=do
  value<-getString k o
  if null value||length value>20||any(\c->c<'0'||c>'9')value||length value>1&&head value=='0' then Left("Invalid canonical decimal: "++k)
  else maybe(Left("Word64 range: "++k))Right(readMaybe value)
getQuantity :: String -> M.Map String J.JSON -> Either String Integer
getQuantity k o=do
  value<-getString k o
  n<-maybe(Left("Invalid quantity: "++k))Right(readMaybe value)
  if show n/=value||n<0||n>quantityMax then Left("Quantity range: "++k) else pure n
getId :: World -> String -> M.Map String J.JSON -> Either String EntityId
getId w k o=do
  n<-getWord k o
  if n==0||n>=invNextId(worldInventory w) then Left "Unknown future entity ID" else pure(EntityId n)
getOwner :: World -> String -> M.Map String J.JSON -> Either String Owner
getOwner w k o=do
  value<-getString k o
  case [owner|owner<-M.keys(invStorage(worldInventory w)),ownerKey owner==value] of
    [owner]->Right owner
    _->Left("Unknown owner: "++k)

decodeUICommand :: World -> J.JSON -> Either String Command
decodeUICommand w input=do
  fields<-J.object input
  kind<-getString "kind" fields
  case kind of
    "produce"->exact["kind","site"] fields>>OrderProduction <$> getId w "site" fields
    "cancelProduction"->exact["kind","job"] fields>>CancelProduction <$> getId w "job" fields
    "siteEnabled"->do exact["kind","site","enabled"]fields;SetSiteEnabled <$> getId w "site" fields <*> (J.field "enabled" fields >>= J.boolean)
    "deliver"->do
      exact["kind","source","destination","resource","quantity","priority"]fields
      resource<-getString "resource" fields >>= parseResource
      quantity<-getQuantity "quantity" fields
      priority<-getQuantity "priority" fields
      unless(quantity>0&&priority<=3)(Left "Delivery quantity must be positive and priority 0..3")
      RequestDelivery <$> getOwner w "source" fields <*> getOwner w "destination" fields <*> pure resource <*> pure quantity <*> pure priority
    "cancelDelivery"->exact["kind","request"]fields>>CancelDelivery <$> getId w "request" fields
    "maintenance"->exact["kind","target","source","return"]fields>>RequestMaintenance <$> getId w "target" fields <*> getOwner w "source" fields <*> getOwner w "return" fields
    "cancelMaintenance"->exact["kind","job"]fields>>CancelFacilityMaintenance <$> getId w "job" fields
    _->Left "Unknown command kind"
  where exact=J.fieldsExactly

context :: World -> Bool -> [OrderedCommand] -> [ManagementEvent] -> RecordedBoundary
context w advance commands management=RecordedBoundary(BoundaryHeader(worldId w)(branchId w)(boundarySeq w)advance(worldAuthority w)(worldRuleset w))(map commandId commands)management
runBoundary :: Runtime -> Bool -> [OrderedCommand] -> [ManagementEvent] -> IO (Runtime,J.JSON)
runBoundary runtime advance commands management=do
  let w=rtWorld runtime
  case play Colony(context w advance commands management)(singleton 1(OrderedBatch commands))w of
    Left err->pure(runtime,errorJSON "admissionRejected"(show err))
    Right result->do
      (next,output)<-evaluate(force result)
      hPutStrLn(rtTrace runtime)(show(Boundary (BoundaryHeader(worldId w)(branchId w)(boundarySeq w)advance(worldAuthority w)(worldRuleset w)) commands management)++" => "++show output)
      pure(runtime {rtWorld=next},obj[("status",str(if null(outputDiagnostics output)then "boundaryCommitted" else "kernelFault")),("receipts",arr(map receiptJSON(outputReceipts output))),("diagnostics",arr(map num(outputDiagnostics output)))])

commandFromRequest :: World -> M.Map String J.JSON -> Either String OrderedCommand
commandFromRequest w request=do
  controller<-getWord "controller" request
  wid<-getWord "world" request
  seqNo<-getWord "sequence" request
  unless(seqNo>0)(Left "Command sequence starts at 1")
  ep<-J.field "epoch" request >>= J.object
  J.fieldsExactly["authority","generation"]ep
  epoch<-Epoch <$> getString "authority" ep <*> getWord "generation" ep
  command<-J.field "command" request >>= decodeUICommand w
  pure(OrderedCommand 0(CommandId wid controller epoch seqNo)command)

previewEnvelope :: World -> J.JSON -> J.JSON
previewEnvelope w command=obj[("op",str "command"),("world",num(worldId w)),("controller",num(1::Integer)),("epoch",epochJSON epoch),("sequence",num(sequenceNo)),("boundary",boundaryJSON(boundarySeq w)),("command",command)]
  where epoch=maybe(Epoch "invalid" 0)participantEpoch(M.lookup 1(worldParticipants w));sequenceNo=M.findWithDefault 0(1,epoch)(worldHighWater w)+1

dispatch :: Runtime -> M.Map String J.JSON -> IO (Runtime,J.JSON)
dispatch runtime request=case getString "op" request of
  Left err->pure(runtime,errorJSON "decodeRejected" err)
  Right "state"->pure(runtime,okJSON "observed")
  Right "frame"->case getWord "count" request of
    Right count|count>=1&&count<=4->if worldMode(rtWorld runtime)==Active then foldM(\(rt,_) _->runBoundary rt True [] [])(runtime,okJSON "paused")[1..count] else pure(runtime,okJSON "paused")
    _->pure(runtime,errorJSON "decodeRejected" "Frame count must be decimal 1..4")
  Right "pause"->runBoundary runtime False [] [PauseWorld]
  Right "resume"->runBoundary runtime False [] [ResumeWorld]
  Right "preview"|any(==maxBound)(M.elems(worldHighWater(rtWorld runtime)))->pure(runtime,errorJSON "admissionRejected" "Command sequence exhausted")
  Right "preview"->do
    (paused,_)<-if worldMode(rtWorld runtime)==Active then runBoundary runtime False [] [PauseWorld] else pure(runtime,okJSON "alreadyPaused")
    let w=rtWorld paused
    case J.field "command" request of
      Left err->pure(paused,errorJSON "decodeRejected" err)
      Right body->case J.object(previewEnvelope w body) >>= commandFromRequest w of
        Left err->pure(paused,errorJSON "decodeRejected" err)
        Right command->case play Colony(context w False [command][])(singleton 1(OrderedBatch[command]))w of
          Left err->pure(paused,errorJSON "admissionRejected"(show err))
          Right(_,output)->pure(paused,obj[("status",str "intentPreview"),("certainty",str "PreviewOnlyNotCommitted"),("envelope",previewEnvelope w body),("predictedReceipts",arr(map receiptJSON(outputReceipts output))),("costNotice",str "取消は巻戻しではありません。稼働中生産は進捗比例の現物損失、積載後配送は返送輸送、開始後保全は進捗比例の現物部品損失。下の対象状態・予測結果を確認。時間は確認中停止しています。")])
  Right "command"->case (getWord "boundary" request,commandFromRequest(rtWorld runtime)request) of
    (Right boundary,Right command)
      | BoundarySeq boundary/=boundarySeq(rtWorld runtime) && not(any(\r->receiptCommand r==commandId command&&receiptBody r==commandBody command)(worldReceipts(rtWorld runtime)))->pure(runtime,errorJSON "admissionRejected" "Stale intent: boundary changed; preview again")
      | otherwise->runBoundary runtime False [command][]
    (Left err,_)->pure(runtime,errorJSON "decodeRejected" err)
    (_,Left err)->pure(runtime,errorJSON "decodeRejected" err)
  Right "save"->requestSave runtime request
  Right other->pure(runtime,errorJSON "decodeRejected"("Unknown operation: "++other))

requestSave :: Runtime -> M.Map String J.JSON -> IO (Runtime,J.JSON)
requestSave runtime _|rtSerial runtime==maxBound=pure(runtime,errorJSON "saveRejected" "Save request sequence exhausted")
requestSave runtime request=do
  let kind=if M.lookup "kind" request==Just(str "autosave")then Autosave else ManualSave
      injectFailure=M.lookup "testFailure" request==Just(J.JBool True)
      ticket=SaveTicket(queueIdentity(rtQueue runtime))(rtSerial runtime)kind
      (admission,queue)=enqueueSave ticket(rtQueue runtime)
      next=runtime {rtQueue=queue,rtSerial=rtSerial runtime+1}
  case admission of
    Started->startSave injectFailure next ticket >>= \started->pure(started,okJSON "snapshotRequested")
    _->pure(next,obj[("status",num admission),("note",str "保存待機は最新のP10 stateを開始時に捕捉します")])

startSave :: Bool -> Runtime -> SaveTicket -> IO Runtime
startSave injectFailure runtime ticket=do
  -- Explicit non-advancing management boundary establishes snapshot ordering.
  (capturedRuntime,_)<-runBoundary runtime False [] []
  let w=rtWorld capturedRuntime
  previous<-readIORef(rtSaveState runtime)
  let oldSuccess=case previous of J.JObject fields->M.findWithDefault J.JNull "lastSuccess" fields;_->J.JNull
      status value phase err=obj[("status",str value),("capturedTick",tickJSON(simTick w)),("capturedBoundary",boundaryJSON(boundarySeq w)),("capturedRevision",num(worldRevision w)),("phases",arr(map str phase)),("lastSuccess",oldSuccess),("error",err),("request",num(ticketSerial ticket))]
  sequenceResult<-nextCheckpointSequence(rtSaveDirectory runtime)
  case sequenceResult >>= \sequenceNo->captureSnapshot ticket (defaultCheckpointMeta {checkpointSequence=sequenceNo,checkpointBuildId="red-dune-ui-0.4"}) w of
    Left err->do
      writeIORef(rtSaveState runtime)(status "failed" [](num err))
      putMVar(rtFinished runtime)(ticket,SaveResult[](Left err)[])
    Right snapshot->do
      writeIORef(rtSaveState runtime)(status "captured" ["Captured"] J.JNull)
      void $ forkIO $ do
        let hook point=case point of
              FaultPoint Before(WriteChunk GenerationFile 0)|injectFailure->pure(FailWith "UI QA injected disk-write failure; world retained")
              FaultPoint After(FlushFile GenerationFile)->writeIORef(rtSaveState runtime)(status "writing" ["Captured","Written","Flushed"] J.JNull)>>pure Proceed
              FaultPoint After RenameGeneration->writeIORef(rtSaveState runtime)(status "writing" ["Captured","Written","Flushed","Renamed"] J.JNull)>>pure Proceed
              _->pure Proceed
        adapter<-newSaveAdapter 65536 hook
        -- Yield IO worker independently; no sleep or write is on the tick loop.
        threadDelay 1000
        result<-nativeSave adapter(rtSaveDirectory runtime)(readIORef(rtIdentity runtime))snapshot
        putMVar(rtFinished runtime)(ticket,result)
  pure capturedRuntime

finishCompleted :: Runtime -> IO Runtime
finishCompleted runtime=do
  finished<-tryTakeMVar(rtFinished runtime)
  case finished of
    Nothing->pure runtime
    Just(ticket,result)->do
      let (valid,queue)=finishSave ticket(rtQueue runtime)
      if not valid then pure runtime else do
        old<-readIORef(rtSaveState runtime)
        wallTime<-epochTime
        let oldSuccess=case old of J.JObject fields->M.findWithDefault J.JNull "lastSuccess" fields;_->J.JNull
            captured=case old of J.JObject fields->M.findWithDefault J.JNull "capturedTick" fields;_->J.JNull
            oldField name=case old of J.JObject fields->M.findWithDefault J.JNull name fields;_->J.JNull
            success=case saveCompletion result of Right committed->obj[("tick",tickJSON(committedTick committed)),("sequence",num(committedSequence committed)),("boundary",oldField "capturedBoundary"),("revision",oldField "capturedRevision"),("wallUnixSeconds",num wallTime)];Left _->oldSuccess
            status=case saveCompletion result of Right _->"saved";Left _->"failed"
        writeIORef(rtSaveState runtime)(obj[("status",str status),("capturedTick",captured),("capturedBoundary",oldField "capturedBoundary"),("capturedRevision",oldField "capturedRevision"),("lastSuccess",success),("phases",arr(map num(saveProgress result))),("error",either num(const J.JNull)(saveCompletion result)),("warnings",arr(map num(saveWarnings result)))])
        let next=runtime {rtQueue=queue}
        case queueActive queue of Nothing->pure next;Just pending->startSave False next pending
