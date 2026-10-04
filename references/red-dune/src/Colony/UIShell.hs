{-# LANGUAGE ScopedTypeVariables #-}
-- Gameplay mutates through Arena. Explicit restore activation follows a
-- validated immutable preparation, fresh session, durable branch and guarded
-- callback; it is a separate recorded shell transition, not a fake native tick.
module Colony.UIShell(runUIShell,decodeUICommand,nextLocalCommandSequence) where
import Colony.Arena
import Colony.Codec
import Colony.Content
import qualified Colony.JSON as J
import Colony.Presentation
import Colony.Save
import Colony.Session
import Colony.SessionTrace
import qualified Colony.CheckpointLibrary as L
import Colony.Types
import Colony.UIFixture
import Colony.S01Fixture
import qualified Colony.Space as Space
import qualified Colony.Workforce as W
import Colony.Units
import Colony.World
import Control.Concurrent(forkFinally,threadDelay)
import Control.Concurrent.MVar
import Control.DeepSeq(force)
import Control.Exception(evaluate,IOException,catch)
import Control.Monad(foldM,unless,void)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Data.IORef
import Data.Word(Word64)
import Game.Arena(play,singleton)
import System.Directory(createDirectoryIfMissing)
import System.Environment(lookupEnv)
import System.IO
import System.Posix.Time(epochTime)
import Text.Read(readMaybe)

data Stamp=Stamp !Word64 !Word64 !String !BoundarySeq !Word64 deriving(Eq,Show)
stamp :: World -> Stamp
stamp w=Stamp(worldId w)(branchId w)(worldAuthority w)(boundarySeq w)(worldRevision w)
data WorkKey=CatalogKey !RequestToken|ReadKey !RequestToken|ActivateKey !RequestToken|SaveKey !RequestToken deriving(Eq,Ord,Show)
data Intent=Intent { intentToken :: !RequestToken,intentStamp :: !Stamp,intentEntry :: !L.Entry,intentAction :: !L.RestoreAction }
data LoadState=LoadIdle|LoadReading !Intent|LoadPreview !Intent !BS.ByteString !L.PreparedSource
  |LoadActivating !Intent|LoadCancelling !Intent
  |LoadTerminal !String !Intent !(Maybe J.JSON) !(Maybe String) !String

data Completion=CatalogDone !RequestToken !(Either String([L.Entry],[String]))
  |ReadDone !RequestToken !(Either String(BS.ByteString,L.PreparedSource))
  |ActivatedDone !RequestToken !(Either String(Session,World,FilePath,SaveResult,ActivationRecord,BS.ByteString))
  |SavedDone !RequestToken !SaveTicket !Stamp !SimTick !BoundarySeq !Word64 !SaveResult

data ActivationEnvironment=ActivationEnvironment !L.LibraryConfig !AuthorityFactory !(IORef(Maybe(RequestToken,SaveIdentity))) !(IORef SaveIdentity)

data Runtime=Runtime {rtWorld :: !World,rtQueue :: !SaveQueue,rtSession :: !Session,rtFactory :: !AuthorityFactory
  ,rtIdentity :: !(IORef SaveIdentity),rtSaveState :: !(IORef J.JSON),rtLastSaved :: !(Maybe Stamp)
  ,rtSaveDirectory :: !FilePath,rtLibraryConfig :: !L.LibraryConfig
  ,rtCompleted :: !(MVar[Completion]),rtWorkers :: !(S.Set WorkKey)
  ,rtCatalogStatus :: !String,rtCatalogToken :: !(Maybe RequestToken),rtEntries :: !(M.Map String L.Entry)
  ,rtCatalogWarnings :: ![String],rtCatalogError :: !(Maybe String),rtLoad :: !LoadState
  ,rtLoadGuard :: !(IORef(Maybe(RequestToken,SaveIdentity))),rtResponseSerial :: !Word64,rtRuntimeId :: !String
  ,rtTrace :: !Handle,rtShellTrace :: !Handle,rtTraceWarning :: !(IORef(Maybe String))}

neverSaved :: J.JSON
neverSaved=obj[("status",str "neverSaved"),("capturedTick",J.JNull),("lastSuccess",J.JNull)]

runUIShell :: Content -> IO()
runUIShell content=do
  hSetBuffering stdout LineBuffering;hSetEncoding stdin utf8;hSetEncoding stdout utf8
  fixtureName<-maybe "legacy-four-colony" id <$> lookupEnv "RED_DUNE_UI_FIXTURE"
  template<-case fixtureName of
    "legacy-four-colony"->snd <$> either(fail.show)pure(uiFixture content)
    "s01"->snd <$> either(fail.show)pure(s01Fixture content)
    _->fail "Unknown RED_DUNE_UI_FIXTURE (legacy-four-colony or s01)"
  store<-lookupEnv "RED_DUNE_UI_STORE"
  traceRoot<-maybe "evidence/ui" id <$> lookupEnv "RED_DUNE_UI_TRACE_DIR"
  let config=case store of Nothing->L.defaultLibraryConfig;Just path->L.defaultLibraryConfig{L.libraryRoot=path,L.legacyFlatDirectory=Nothing}
  (branch,directory)<-L.reserveBranch config(worldId template)(branchId template) >>= either(fail.show)pure
  factory<-newAuthorityFactory
  session<-newSession factory(worldAuthorities template) >>= either(fail.show)pure
  initial<-either(fail.show)pure(activateWorldSession session branch template)
  createDirectoryIfMissing True traceRoot
  nativeLog<-openFile(traceRoot++"/native-boundaries.log")AppendMode
  shellLog<-openFile(traceRoot++"/shell-actions.log")AppendMode
  hSetBuffering nativeLog LineBuffering;hSetBuffering shellLog LineBuffering
  let identity=identityFor(sessionEpoch session)initial
  identityRef<-newIORef identity;saveRef<-newIORef neverSaved;completed<-newMVar [];guardRef<-newIORef Nothing;warning<-newIORef Nothing
  let runtime=Runtime initial(emptySaveQueue identity)session factory identityRef saveRef Nothing directory config completed S.empty
        "idle" Nothing M.empty [] Nothing LoadIdle guardRef 1(sessionAuthority session)nativeLog shellLog warning
  traceShell runtime("startup-fixture "++fixtureName)
  traceShell runtime("startup fresh branch="++show branch++" authority="++sessionAuthority session)
  loop runtime
  hClose nativeLog;hClose shellLog
  where
    loop runtime=do
      ended<-hIsEOF stdin
      unless ended $ do
        line<-getLine
        ready<-finishCompleted runtime
        if rtResponseSerial ready==maxBound
          then putStrLn(encodeJSON(obj[("result",errorJSON "shellStopped" "Response sequence exhausted"),("view",presentation(rtWorld ready)),("save",neverSaved)]))
          else do
            (next,result)<-case if length line>65536 then Left "Request too long" else J.parseJSON line >>= J.object of
              Left err->pure(ready,errorJSON "decodeRejected" err)
              Right request->dispatch ready request
            saved<-stateJSON next
            shell<-shellJSON next
            putStrLn(encodeJSON(obj[("result",result),("view",presentation(rtWorld next)),("save",saved),("shell",shell)]))
            loop next{rtResponseSerial=rtResponseSerial next+1}

traceShell :: Runtime -> String -> IO()
traceShell runtime text=(hPutStrLn(rtShellTrace runtime)text) `catch` \(_::IOException)->writeIORef(rtTraceWarning runtime)(Just "Shell trace write failed; live World retained")

stateJSON :: Runtime -> IO J.JSON
stateJSON runtime=do
  status<-readIORef(rtSaveState runtime)
  pure(obj[("current",status),("pending",J.JBool(queueManual(rtQueue runtime)/=Nothing||queueAutosave(rtQueue runtime)/=Nothing))])
dirty :: Runtime -> Bool
dirty runtime=rtLastSaved runtime/=Just(stamp(rtWorld runtime))

entryJSON :: L.Entry -> J.JSON
entryJSON entry=obj[("id",str(L.entryId entry)),("label",str(L.entryLabel entry)),("kind",str(L.kindId(L.entryKind entry)))
  ,("world",num(L.entryWorldId entry)),("branch",num(L.entryBranchId entry)),("tick",tickJSON(L.entryTick entry))
  ,("sequence",num(L.entrySequence entry)),("schema",num(L.entrySchema entry)),("ruleset",str(L.entryRuleset entry))
  ,("actions",arr[obj[("id",str(L.actionId action)),("label",str(L.actionLabel action))]|action<-L.entryActions entry])
  ,("warnings",arr(map str["未確定/互換fixtureです。確認して新しい枝へ復元します"|L.entryKind entry/=L.Committed]))]

previewJSON :: Runtime -> Intent -> L.PreparedSource -> Maybe Word64 -> J.JSON
previewJSON runtime intent prepared branch=obj
  [("source",obj[("world",num(L.entryWorldId entry)),("branch",num(L.entryBranchId entry)),("tick",tickJSON(L.entryTick entry)),("schema",num(L.entrySchema entry)),("ruleset",str(L.entryRuleset entry))])
  ,("target",obj[("world",num(worldId target)),("branch",maybe J.JNull num branch),("tick",tickJSON(simTick target)),("schema",num(checkpointSchemaFor target)),("ruleset",str(worldRuleset target))])
  ,("changes",arr(map str(L.preparedChanges prepared))), ("preserved",arr(map str(L.preparedPreserved prepared)))
  ,("dirtyCurrent",J.JBool(dirty runtime)),("warning",str "現在の未保存進行から別の枝へ切り替えます。必要なら先に保存してください。")]
  where entry=intentEntry intent;target=L.preparedWorld prepared

loadJSON :: Runtime -> J.JSON
loadJSON runtime=case rtLoad runtime of
  LoadIdle->base "idle" Nothing Nothing Nothing ""
  LoadReading intent->with "reading" intent Nothing Nothing "保存を読み込み、整合性を検査しています"
  LoadPreview intent _ prepared->with "preview" intent(Just(previewJSON runtime intent prepared Nothing))Nothing "未適用の復元・移行プレビューです"
  LoadActivating intent->with "activating" intent Nothing Nothing "新しい枝を検証・保存しています。まだ切替成功ではありません"
  LoadCancelling intent->with "cancelling" intent Nothing Nothing "読込み/準備処理を終了待ち。現在のWorldは維持します"
  LoadTerminal status intent preview failure message->with status intent preview failure message
  where
    base status intent preview failure message=obj[("status",str status),("ticket",maybe J.JNull(str.tokenText.intentToken)intent)
      ,("entry",maybe J.JNull(str.L.entryId.intentEntry)intent),("action",maybe J.JNull(str.L.actionId.intentAction)intent)
      ,("preview",maybe J.JNull id preview),("error",maybe J.JNull str failure),("message",str message)]
    with status intent=base status(Just intent)

shellJSON :: Runtime -> IO J.JSON
shellJSON runtime=do
  warning<-readIORef(rtTraceWarning runtime)
  let world=rtWorld runtime;Epoch _ counter=sessionEpoch(rtSession runtime)
  pure(obj[("schema",str "red-dune-shell-0.5"),("runtimeId",str(rtRuntimeId runtime)),("responseSerial",num(rtResponseSerial runtime))
    ,("session",obj[("authority",str(sessionAuthority(rtSession runtime))),("epochCounter",num counter),("world",num(worldId world)),("branch",num(branchId world)),("ruleset",str(worldRuleset world)),("dirty",J.JBool(dirty runtime))])
    ,("catalog",obj[("status",str(rtCatalogStatus runtime)),("entries",arr(map entryJSON(M.elems(rtEntries runtime)))),("warnings",arr(map str(rtCatalogWarnings runtime))),("error",maybe J.JNull str(rtCatalogError runtime))])
    ,("load",loadJSON runtime),("warnings",arr(map str(maybe [](:[])warning)))])

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
    "placePlan"->do
      exact["kind","colony","prototype","x","y","rotation","priority","source"]fields
      colony<-getId w "colony" fields
      prototype<-getString "prototype" fields
      x<-getQuantity "x" fields;y<-getQuantity "y" fields;priority<-getQuantity "priority" fields
      unless(x<512&&y<512&&priority<=3)(Left "Placement tile/priority outside bounds")
      rotationName<-getString "rotation" fields
      rotation<-case rotationName of "R0"->Right Space.R0;"R90"->Right Space.R90;"R180"->Right Space.R180;"R270"->Right Space.R270;_->Left "Unknown rotation"
      sourceValue<-J.field "source" fields
      source<-case sourceValue of J.JNull->Right Nothing;_->Just <$> getId w "source" fields
      shape<-if prototype=="road" then do
          unless(rotation==Space.R0&&source==Nothing)(Left "Road requires R0 and no natural source")
          Right(Space.RoadShape(Space.Tile x y))
        else Right(Space.BuildingShape prototype(Space.Tile x y)rotation)
      Right(PlaceConstructionPlan colony shape priority source)
    "cancelPlan"->do
      exact["kind","site","revision"]fields
      CancelConstructionPlan <$> getId w "site" fields <*> getWord "revision" fields
    "assignWorkers"->do
      exact["kind","target","shift","residents"]fields
      targetFields<-J.field "target" fields >>= J.object
      exact["kind","id"]targetFields
      identValue<-getId w "id" targetFields
      targetKind<-getString "kind" targetFields
      target<-case targetKind of
        "facility"->Right(W.OperateFacility identValue);"construction"->Right(W.ConstructSite identValue)
        "maintenance"->Right(W.MaintainJob identValue);"vehicle"->Right(W.DriveVehicle identValue);_->Left "Unknown workforce target kind"
      shift<-getQuantity "shift" fields
      unless(shift<=2)(Left "Shift outside0..2")
      residents<-J.field "residents" fields >>= J.array
      unless(length residents<=256)(Left "Workforce roster exceeds256 names")
      names<-mapM(\value->getId w "resident"(M.singleton "resident" value))residents
      Right(AssignWorkers target shift names)
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
      (hPutStrLn(rtTrace runtime)(show(Boundary (BoundaryHeader(worldId w)(branchId w)(boundarySeq w)advance(worldAuthority w)(worldRuleset w)) commands management)++" => "++show output)) `catch` \(_::IOException)->writeIORef(rtTraceWarning runtime)(Just "Native trace write failed; live World retained")
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

-- Archived epochs may be exhausted without exhausting the fresh active session.
nextLocalCommandSequence :: World -> Either String Word64
nextLocalCommandSequence w=do
  participant<-maybe(Left "Local controller is absent")Right(M.lookup 1(worldParticipants w))
  let current=M.findWithDefault 0(1,participantEpoch participant)(worldHighWater w)
  if current==maxBound then Left "Command sequence exhausted" else Right(current+1)

previewEnvelope :: World -> J.JSON -> J.JSON
previewEnvelope w command=obj[("op",str "command"),("world",num(worldId w)),("controller",num(1::Integer)),("epoch",epochJSON epoch),("sequence",num(sequenceNo)),("boundary",boundaryJSON(boundarySeq w)),("command",command)]
  where epoch=maybe(Epoch "invalid" 0)participantEpoch(M.lookup 1(worldParticipants w));sequenceNo=either(const 0)id(nextLocalCommandSequence w)

dispatchGame :: Runtime -> M.Map String J.JSON -> IO (Runtime,J.JSON)
dispatchGame runtime request=case getString "op" request of
  Left err->pure(runtime,errorJSON "decodeRejected" err)
  Right "state"->pure(runtime,okJSON "observed")
  Right "frame"->case getWord "count" request of
    Right count|count>=1&&count<=4->if worldMode(rtWorld runtime)==Active then foldM(\(rt,_) _->runBoundary rt True [] [])(runtime,okJSON "paused")[1..count] else pure(runtime,okJSON "paused")
    _->pure(runtime,errorJSON "decodeRejected" "Frame count must be decimal 1..4")
  Right "pause"->runBoundary runtime False [] [PauseWorld]
  Right "resume"->runBoundary runtime False [] [ResumeWorld]
  Right "preview"|Left err<-nextLocalCommandSequence(rtWorld runtime)->pure(runtime,errorJSON "admissionRejected" err)
  Right "preview"->do
    (paused,_)<-if worldMode(rtWorld runtime)==Active then runBoundary runtime False [] [PauseWorld] else pure(runtime,okJSON "alreadyPaused")
    let w=rtWorld paused
    case J.field "command" request of
      Left err->pure(paused,errorJSON "decodeRejected" err)
      Right body->case J.object(previewEnvelope w body) >>= commandFromRequest w of
        Left err->pure(paused,errorJSON "decodeRejected" err)
        Right command->case play Colony(context w False [command][])(singleton 1(OrderedBatch[command]))w of
          Left err->pure(paused,errorJSON "admissionRejected"(show err))
          Right(predicted,output)->pure(paused,obj[("previewPlan",previewPlanJSON predicted(commandBody command)output),("status",str "intentPreview"),("certainty",str "PreviewOnlyNotCommitted"),("envelope",previewEnvelope w body),("predictedReceipts",arr(map receiptJSON(outputReceipts output))),("costNotice",str "取消は巻戻しではありません。稼働中生産は進捗比例の現物損失、積載後配送は返送輸送、開始後保全は進捗比例の現物部品損失。下の対象状態・予測結果を確認。時間は確認中停止しています。")])
  Right "command"->case (getWord "boundary" request,commandFromRequest(rtWorld runtime)request) of
    (Right boundary,Right command)
      | BoundarySeq boundary/=boundarySeq(rtWorld runtime) && not(any(\r->receiptCommand r==commandId command&&receiptBody r==commandBody command)(worldReceipts(rtWorld runtime)))->pure(runtime,errorJSON "admissionRejected" "Stale intent: boundary changed; preview again")
      | otherwise->runBoundary runtime False [command][]
    (Left err,_)->pure(runtime,errorJSON "decodeRejected" err)
    (_,Left err)->pure(runtime,errorJSON "decodeRejected" err)
  Right "save"->requestSave runtime request
  Right other->pure(runtime,errorJSON "decodeRejected"("Unknown operation: "++other))

-- Worker closures receive only their bounded payload and completion cell.
spawn :: Runtime -> WorkKey -> (String -> Completion) -> IO Completion -> IO Runtime
spawn runtime key failure action=do
  box<-evaluate(rtCompleted runtime)
  void $ forkFinally action $ \result->do
    let completion=either(failure . show)id result
    modifyMVar_ box(pure . (++[completion]))
  pure runtime{rtWorkers=S.insert key(rtWorkers runtime)}

completionKey :: Completion -> WorkKey
completionKey event=case event of CatalogDone t _->CatalogKey t;ReadDone t _->ReadKey t;ActivatedDone t _->ActivateKey t;SavedDone t _ _ _ _ _ _->SaveKey t
sameEpoch :: Runtime -> RequestToken -> Bool
sameEpoch runtime(RequestToken epoch _)=epoch==sessionEpoch(rtSession runtime)

strictPrepared :: L.PreparedSource -> IO L.PreparedSource
strictPrepared prepared=do
  world<-evaluate(force(L.preparedWorld prepared));changes<-evaluate(force(L.preparedChanges prepared));preserved<-evaluate(force(L.preparedPreserved prepared))
  pure prepared{L.preparedWorld=world,L.preparedChanges=changes,L.preparedPreserved=preserved}

qa :: M.Map String J.JSON -> Either String(Word64,String)
qa request=do
  delay<-if M.member "testDelayMs" request then getWord "testDelayMs" request else Right 0
  unless(delay<=2000)(Left "Test delay must be0..2000ms")
  failure<-case M.lookup "testFailure" request of Nothing->Right "";Just(J.JBool True)->Right "write";Just(J.JBool False)->Right "";Just value->J.string value
  unless(failure `elem`["","read","write","entropy","branch"])(Left "Unknown test fault")
  pure(delay,failure)
rejectUnknown :: [String] -> M.Map String J.JSON -> Either String()
rejectUnknown allowed request=unless(all(`elem`allowed)(M.keys request))(Left "Unknown request field")

activeLoad :: LoadState -> Bool
activeLoad(LoadReading _)=True
activeLoad(LoadPreview _ _ _)=True
activeLoad(LoadActivating _)=True
activeLoad(LoadCancelling _)=True
activeLoad _=False
switching :: LoadState -> Bool
switching(LoadActivating _)=True
switching(LoadCancelling _)=True
switching _=False

dispatch :: Runtime -> M.Map String J.JSON -> IO(Runtime,J.JSON)
dispatch runtime request=case getString "op" request of
  Right "library"->requestCatalog runtime request
  Right "previewLoad"->requestLoadPreview runtime request
  Right "activateLoad"->requestActivation runtime request
  Right "cancelLoad"->requestLoadCancel runtime request
  Right op|switching(rtLoad runtime)&&op `notElem`["state","frame"]->pure(runtime,errorJSON "shellBusy" "Load activation/cancellation is still running")
  _->dispatchGame runtime request

requestCatalog :: Runtime -> M.Map String J.JSON -> IO(Runtime,J.JSON)
requestCatalog runtime request
  |rtCatalogStatus runtime=="loading"||S.size(rtWorkers runtime)>=2=pure(runtime,errorJSON "catalogRejected" "Busy: bounded I/O workers are occupied")
  |otherwise=case rejectUnknown["op","includeCompatibility","testDelayMs","testFailure"]request>>qa request of
    Left err->pure(runtime,errorJSON "decodeRejected" err)
    Right(delay,failure)->case maybe(Right False)J.boolean(M.lookup "includeCompatibility" request)of
      Left err->pure(runtime,errorJSON "decodeRejected" err)
      Right compatibility->do
        issued<-issueRequest(rtSession runtime)
        case issued of
          Left err->pure(runtime,errorJSON "catalogRejected"(show err))
          Right token->do
            config<-evaluate(rtLibraryConfig runtime)
            next<-spawn runtime{rtCatalogStatus="loading",rtCatalogToken=Just token,rtCatalogError=Nothing}(CatalogKey token)(CatalogDone token . Left)$do
              threadDelay(fromIntegral delay*1000)
              result<-if failure=="read"then pure(Left "Injected catalog read failure")else either(Left . show)Right <$> L.listLibrary config compatibility
              pure(CatalogDone token result)
            pure(next,okJSON "catalogRequested")

requestLoadPreview :: Runtime -> M.Map String J.JSON -> IO(Runtime,J.JSON)
requestLoadPreview runtime request
  |activeLoad(rtLoad runtime)||S.size(rtWorkers runtime)>=2=pure(runtime,errorJSON "loadRejected" "Busy: a load or bounded I/O operation is active")
  |otherwise=case do
    rejectUnknown["op","entry","action","testDelayMs","testFailure"]request
    key<-getString "entry" request;name<-getString "action" request
    entry<-maybe(Left "Unknown catalog entry")Right(M.lookup key(rtEntries runtime))
    action<-maybe(Left "Unknown restore action")Right(L.parseAction name)
    unless(action `elem`L.entryActions entry)(Left "Action is not advertised for this source")
    hooks<-qa request
    pure(entry,action,hooks)of
      Left err->pure(runtime,errorJSON "loadRejected" err)
      Right(entry,action,(delay,failure))->do
        (paused,_)<-if worldMode(rtWorld runtime)==Active then runBoundary runtime False[][PauseWorld]else pure(runtime,okJSON "paused")
        issued<-issueRequest(rtSession paused)
        case issued of
          Left err->pure(paused,errorJSON "loadRejected"(show err))
          Right token->do
            let intent=Intent token(stamp(rtWorld paused))entry action
                temporaryBranch=if L.entryBranchId entry==1 then 2 else 1
            next<-spawn paused{rtLoad=LoadReading intent}(ReadKey token)(ReadDone token . Left)$do
              loaded<-if failure=="read"then pure(Left "Injected checkpoint read failure")else either(Left . show)Right <$> L.readEntry entry
              prepared<-case loaded of
                Left err->pure(Left err)
                Right bytes->case L.prepareEntry entry action temporaryBranch bytes of
                  Left err->pure(Left(show err))
                  Right candidate->do strict<-strictPrepared candidate;pure(Right(bytes,strict))
              threadDelay(fromIntegral delay*1000)
              pure(ReadDone token prepared)
            traceShell next("load preview "++tokenText token++" entry="++L.entryId entry++" action="++L.actionId action)
            pure(next,obj[("status",str "loadPreviewRequested"),("ticket",str(tokenText token))])

requestActivation :: Runtime -> M.Map String J.JSON -> IO(Runtime,J.JSON)
requestActivation runtime request=case do
  rejectUnknown["op","ticket","discardUnsaved","testDelayMs","testFailure"]request
  token<-getString "ticket" request
  discard<-maybe(Right False)J.boolean(M.lookup "discardUnsaved" request)
  hooks<-qa request
  pure(token,discard,hooks)of
    Left err->pure(runtime,errorJSON "decodeRejected" err)
    Right(tokenTextValue,discard,(delay,failure))->case rtLoad runtime of
      LoadPreview intent _ _
        |tokenTextValue/=tokenText(intentToken intent)->pure(runtime,errorJSON "loadRejected" "Unknown load ticket")
        |intentStamp intent/=stamp(rtWorld runtime)->pure(runtime{rtLoad=LoadTerminal "failed" intent Nothing(Just "PreviewStale: boundary/session changed")"プレビューを取り直してください"},errorJSON "loadRejected" "PreviewStale: boundary/session changed")
        |dirty runtime&&not discard->pure(runtime,errorJSON "loadRejected" "DiscardConfirmationRequired")
        |S.size(rtWorkers runtime)>=2->pure(runtime,errorJSON "loadRejected" "Busy: bounded I/O workers are occupied")
        |otherwise->do
          let token=intentToken intent;sourceIdentity=identityFor(sessionEpoch(rtSession runtime))(rtWorld runtime)
              -- Pending old saves hold no snapshots and must not be started after
              -- activation confirmation. An existing worker may still finish.
              queue=(rtQueue runtime){queueManual=Nothing,queueAutosave=Nothing}
          known<-evaluate(force(worldAuthorities(rtWorld runtime)))
          liveHash<-either(fail.show)pure(canonicalStateHash(rtWorld runtime))
          environment<-evaluate(ActivationEnvironment(rtLibraryConfig runtime)(rtFactory runtime)(rtLoadGuard runtime)(rtIdentity runtime))
          writeIORef(rtLoadGuard runtime)(Just(token,sourceIdentity))
          next<-spawn runtime{rtLoad=LoadActivating intent,rtQueue=queue}(ActivateKey token)(ActivatedDone token . Left)$do
            prepared<-prepareActivation environment intent known liveHash sourceIdentity delay failure
            pure(ActivatedDone token prepared)
          traceShell next("load activation requested "++tokenText token)
          pure(next,okJSON "loadActivationRequested")
      _->pure(runtime,errorJSON "loadRejected" "No matching immutable load preview")

prepareActivation :: ActivationEnvironment -> Intent -> S.Set String -> BS.ByteString -> SaveIdentity -> Word64 -> String -> IO(Either String(Session,World,FilePath,SaveResult,ActivationRecord,BS.ByteString))
prepareActivation(ActivationEnvironment config factory guardRef identityRef)intent known liveHash sourceIdentity delay failure=do
  let entry=intentEntry intent;token=intentToken intent
  bytesResult<-L.readEntry entry
  case bytesResult of
    Left err->pure(Left(show err))
    Right bytes->do
      allocation<-if failure=="branch"then pure(Left(L.LibraryError "Injected branch allocation failure"))else L.reserveBranch config(L.entryWorldId entry)(L.entryBranchId entry)
      case allocation of
        Left err->pure(Left(show err))
        Right(branch,directory)->case L.prepareEntry entry(intentAction intent)branch bytes of
          Left err->pure(Left(show err))
          Right prepared->do
            fresh<-if failure=="entropy"then pure(Left(EntropyUnavailable "Injected entropy failure"))else newSession factory(S.union known(worldAuthorities(L.preparedWorld prepared)))
            case fresh of
              Left err->pure(Left(show err))
              Right session->case bindPreparedSession session(L.entryBranchId entry)(L.preparedWorld prepared)of
                Left err->pure(Left(show err))
                Right unforced->do
                  world<-evaluate(force unforced)
                  issued<-issueRequest session
                  case issued of
                    Left err->pure(Left(show err))
                    Right activationSaveToken->do
                      let identity=identityFor(sessionEpoch session)world
                          ticket=SaveTicket identity(requestSerial activationSaveToken)ManualSave
                          rejected=SaveIdentity 0 0(Epoch "not-an-issued-authority" 0)
                          current=do guardValue<-readIORef guardRef;actual<-readIORef identityRef
                                     pure(if guardValue==Just(token,sourceIdentity)&&actual==sourceIdentity then identity else rejected)
                          hook point=case point of
                            FaultPoint Before(WriteChunk GenerationFile 0)|failure=="write"->pure(FailWith "Injected prepared-branch write failure")
                            FaultPoint Before CallbackValidation->threadDelay(fromIntegral delay*1000)>>pure Proceed
                            _->pure Proceed
                      case captureSnapshot ticket(CheckpointMeta 1 Nothing "red-dune-ui-0.5-activation")world of
                        Left err->pure(Left(show err))
                        Right snapshot->do
                          adapter<-newSaveAdapter 65536 hook
                          result<-saveInBranch config identity adapter current snapshot
                          pure $ case makeActivationRecord(intentAction intent)bytes liveHash world of
                            Left err->Left(show err)
                            Right record->Right(session,world,directory,result,record,bytes)

requestLoadCancel :: Runtime -> M.Map String J.JSON -> IO(Runtime,J.JSON)
requestLoadCancel runtime request=case rejectUnknown["op","ticket"]request>>getString "ticket" request of
  Left err->pure(runtime,errorJSON "decodeRejected" err)
  Right supplied->case getIntent(rtLoad runtime)of
    Just intent|supplied==tokenText(intentToken intent)->do
      writeIORef(rtLoadGuard runtime)Nothing
      let pending=any(`S.member`rtWorkers runtime)[ReadKey(intentToken intent),ActivateKey(intentToken intent)]
          state=if pending then LoadCancelling intent else LoadTerminal "cancelled" intent Nothing Nothing "切替を中止しました。現在のWorldは保持されています"
      traceShell runtime("load cancelled "++supplied)
      pure(runtime{rtLoad=state},okJSON "loadCancelRequested")
    _->pure(runtime,errorJSON "loadRejected" "No pending load with this ticket")
  where
    getIntent(LoadReading intent)=Just intent
    getIntent(LoadPreview intent _ _)=Just intent
    getIntent(LoadActivating intent)=Just intent
    getIntent(LoadCancelling intent)=Just intent
    getIntent _=Nothing

requestSave :: Runtime -> M.Map String J.JSON -> IO(Runtime,J.JSON)
requestSave runtime request
  |switching(rtLoad runtime)=pure(runtime,errorJSON "saveRejected" "Busy: activating another branch")
  |otherwise=case rejectUnknown["op","kind","testFailure","testDelayMs"]request>>qa request of
    Left err->pure(runtime,errorJSON "decodeRejected" err)
    Right hooks->do
      let kind=if M.lookup "kind" request==Just(str "autosave")then Autosave else ManualSave
          oldWriter=any isOldWriter(S.toList(rtWorkers runtime))
          isOldWriter(SaveKey token)=not(sameEpoch runtime token)
          isOldWriter _=False
      if oldWriter||queueActive(rtQueue runtime)==Nothing&&S.size(rtWorkers runtime)>=2
      then pure(runtime,errorJSON "saveRejected" "Busy: previous-session/bounded I/O worker is finishing")
      else do
        issued<-issueRequest(rtSession runtime)
        case issued of
          Left err->pure(runtime,errorJSON "saveRejected"(show err))
          Right token->do
            let ticket=SaveTicket(queueIdentity(rtQueue runtime))(requestSerial token)kind
                (admission,queue)=enqueueSave ticket(rtQueue runtime)
                next=runtime{rtQueue=queue}
            case admission of
              Started->startSave hooks next ticket >>= \started->pure(started,okJSON "snapshotRequested")
              _->pure(next,obj[("status",num admission),("note",str "保存待機は開始時の最新P10 stateを捕捉します")])

saveToken :: SaveTicket -> RequestToken
saveToken ticket=RequestToken(saveEpoch(ticketIdentity ticket))(ticketSerial ticket)

startSave :: (Word64,String) -> Runtime -> SaveTicket -> IO Runtime
startSave(delay,failure) runtime ticket=do
  (capturedRuntime,_)<-runBoundary runtime False[][]
  let world=rtWorld capturedRuntime
      capturedStamp=stamp world;capturedTickValue=simTick world;capturedBoundaryValue=boundarySeq world;capturedRevisionValue=worldRevision world
      token=saveToken ticket
      directory=rtSaveDirectory capturedRuntime
  stateRef<-evaluate(rtSaveState capturedRuntime)
  identityRef<-evaluate(rtIdentity capturedRuntime)
  _<-evaluate capturedStamp
  previous<-readIORef stateRef
  let oldSuccess=jsonField "lastSuccess" previous
      status value phases failureValue=obj[("status",str value),("capturedTick",tickJSON capturedTickValue),("capturedBoundary",boundaryJSON capturedBoundaryValue),("capturedRevision",num capturedRevisionValue),("phases",arr(map num phases)),("lastSuccess",oldSuccess),("error",failureValue),("request",num(ticketSerial ticket))]
      done result=SavedDone token ticket capturedStamp capturedTickValue capturedBoundaryValue capturedRevisionValue result
  config<-evaluate(rtLibraryConfig capturedRuntime)
  sequenceWrapped<-L.withBranchDirectory config(worldId world)(branchId world)nextCheckpointSequence
  let sequenceResult=either(Left . InvalidStorage . show)id sequenceWrapped
  case sequenceResult >>= \sequenceNo->captureSnapshot ticket(defaultCheckpointMeta{checkpointSequence=sequenceNo,checkpointBuildId="red-dune-ui-0.5"})world of
    Left err->do
      writeIORef stateRef(status "failed"([]::[SavePhase])(num err))
      processSave capturedRuntime token ticket capturedStamp capturedTickValue capturedBoundaryValue capturedRevisionValue(SaveResult[](Left err)[])
    Right snapshot->do
      writeIORef stateRef(status "captured"[Captured]J.JNull)
      -- Force all scalar closure fields before discarding the World reference.
      _<-evaluate(force(capturedTickValue,capturedBoundaryValue,capturedRevisionValue,directory,encodeJSON oldSuccess))
      box<-evaluate(rtCompleted capturedRuntime)
      let hook point=case point of
            FaultPoint Before(WriteChunk GenerationFile 0)|failure=="write"->pure(FailWith "UI QA injected disk-write failure; World retained")
            FaultPoint After(FlushFile GenerationFile)->writeIORef stateRef(status "writing"[Captured,Written,Flushed]J.JNull)>>pure Proceed
            FaultPoint After RenameGeneration->writeIORef stateRef(status "writing"[Captured,Written,Flushed,Renamed]J.JNull)>>pure Proceed
            FaultPoint Before CallbackValidation->threadDelay(fromIntegral delay*1000)>>pure Proceed
            _->pure Proceed
      void $ forkFinally (do adapter<-newSaveAdapter 65536 hook;saveInBranch config(ticketIdentity ticket)adapter(readIORef identityRef)snapshot) $ \outcome->do
        let result=either(\exception->SaveResult[](Left(InvalidStorage("Save worker stopped: "++show exception)))[])id outcome
        modifyMVar_ box(pure . (++[done result]))
      pure capturedRuntime{rtWorkers=S.insert(SaveKey token)(rtWorkers capturedRuntime)}

saveInBranch :: L.LibraryConfig -> SaveIdentity -> SaveAdapter -> IO SaveIdentity -> CapturedSnapshot -> IO SaveResult
saveInBranch config identity adapter current snapshot=do
  result<-L.withBranchDirectory config(saveWorldId identity)(saveBranchId identity)(\directory->nativeSave adapter directory current snapshot)
  pure(either(\failure->SaveResult[](Left(InvalidStorage(show failure)))[])id result)

jsonField :: String -> J.JSON -> J.JSON
jsonField fieldName(J.JObject fields)=M.findWithDefault J.JNull fieldName fields
jsonField _ _=J.JNull

processSave :: Runtime -> RequestToken -> SaveTicket -> Stamp -> SimTick -> BoundarySeq -> Word64 -> SaveResult -> IO Runtime
processSave runtime token ticket savedStamp savedTick savedBoundary savedRevision result=do
  let(valid,queue)=finishSave ticket(rtQueue runtime)
  if not valid||not(sameEpoch runtime token) then traceShell runtime("ignored old/duplicate save callback "++tokenText token)>>pure runtime else do
    old<-readIORef(rtSaveState runtime)
    wallTime<-epochTime
    let success=case saveCompletion result of
          Right committed->obj[("tick",tickJSON(committedTick committed)),("sequence",num(committedSequence committed)),("boundary",boundaryJSON savedBoundary),("revision",num savedRevision),("wallUnixSeconds",num wallTime)]
          Left _->jsonField "lastSuccess" old
        state=obj[("status",str(either(const "failed")(const "saved")(saveCompletion result))),("capturedTick",tickJSON savedTick),("capturedBoundary",boundaryJSON savedBoundary),("capturedRevision",num savedRevision),("lastSuccess",success),("phases",arr(map num(saveProgress result))),("error",either num(const J.JNull)(saveCompletion result)),("warnings",arr(map num(saveWarnings result)))]
    writeIORef(rtSaveState runtime)state
    let next=runtime{rtQueue=queue,rtLastSaved=either(const(rtLastSaved runtime))(const(Just savedStamp))(saveCompletion result)}
    traceShell next("save callback "++tokenText token++" completion="++show(saveCompletion result))
    case queueActive queue of
      Nothing->pure next
      Just pending|switching(rtLoad next)->pure next{rtQueue=emptySaveQueue(queueIdentity queue)}
                  |otherwise->startSave(0,"")next pending

finishCompleted :: Runtime -> IO Runtime
finishCompleted runtime=do
  events<-modifyMVar(rtCompleted runtime)(\queued->pure([],queued))
  foldM finish runtime events
  where
    finish current event=do
      let key=completionKey event
      if not(S.member key(rtWorkers current)) then traceShell current("ignored unknown/duplicate worker "++show key)>>pure current else do
        let next=current{rtWorkers=S.delete key(rtWorkers current)}
        case event of
          SavedDone token ticket savedStamp savedTick savedBoundary savedRevision result->processSave next token ticket savedStamp savedTick savedBoundary savedRevision result
          CatalogDone token result
            |rtCatalogToken next/=Just token||not(sameEpoch next token)->pure next
            |otherwise->case result of
              Left err->pure next{rtCatalogStatus="failed",rtCatalogError=Just err,rtCatalogToken=Nothing}
              Right(entries,warnings)->pure next{rtCatalogStatus="ready",rtEntries=M.fromList[(L.entryId entry,entry)|entry<-entries],rtCatalogWarnings=warnings,rtCatalogError=Nothing,rtCatalogToken=Nothing}
          ReadDone token result->case rtLoad next of
            LoadCancelling intent|intentToken intent==token->pure next{rtLoad=LoadTerminal "cancelled" intent Nothing Nothing "読込みを中止しました。Worldは変更していません"}
            LoadReading intent|intentToken intent==token&&sameEpoch next token->case result of
              Left err->pure next{rtLoad=LoadTerminal "failed" intent Nothing(Just err)"読込み/検証に失敗しました。現在のWorldは保持されています"}
              Right(bytes,prepared)->pure next{rtLoad=LoadPreview intent bytes prepared}
            _->pure next
          ActivatedDone token result->case rtLoad next of
            LoadCancelling intent|intentToken intent==token->do
              writeIORef(rtLoadGuard next)Nothing
              traceShell next("cancelled activation completion "++tokenText token)
              pure next{rtLoad=LoadTerminal "cancelled" intent Nothing Nothing "切替を中止しました。既に書込みが完了した枝は保存一覧に残る場合があります"}
            LoadActivating intent|intentToken intent==token&&sameEpoch next token->do
              writeIORef(rtLoadGuard next)Nothing
              case result of
                Left err->pure next{rtLoad=LoadTerminal "failed" intent Nothing(Just err)"復元準備に失敗しました。現在のWorldは保持されています"}
                Right(session,target,directory,saved,record,sourceBytes)
                  |intentStamp intent/=stamp(rtWorld next)->pure next{rtLoad=LoadTerminal "failed" intent Nothing(Just "ActivationStale: current boundary/session changed")"新しい枝は保存済みの場合がありますが、現在のWorldへ適用していません"}
                  |otherwise->case saveCompletion saved of
                    Left err->pure next{rtLoad=LoadTerminal "failed" intent Nothing(Just(show err))"新しい枝の保存確認に失敗しました。現在のWorldは保持されています"}
                    Right committed->do
                      let identity=identityFor(sessionEpoch session)target
                      writeIORef(rtIdentity next)identity
                      wallTime<-epochTime
                      let success=obj[("tick",tickJSON(committedTick committed)),("sequence",num(committedSequence committed)),("boundary",boundaryJSON(boundarySeq target)),("revision",num(worldRevision target)),("wallUnixSeconds",num wallTime)]
                          savedView=obj[("status",str "saved"),("capturedTick",tickJSON(simTick target)),("capturedBoundary",boundaryJSON(boundarySeq target)),("capturedRevision",num(worldRevision target)),("lastSuccess",success),("phases",arr(map num(saveProgress saved))),("error",J.JNull)]
                          info=obj[("source",obj[("world",num(L.entryWorldId(intentEntry intent))),("branch",num(L.entryBranchId(intentEntry intent))),("tick",tickJSON(L.entryTick(intentEntry intent))),("schema",num(L.entrySchema(intentEntry intent))),("ruleset",str(L.entryRuleset(intentEntry intent)))])
                            ,("target",obj[("world",num(worldId target)),("branch",num(branchId target)),("tick",tickJSON(simTick target)),("schema",num(checkpointSchemaFor target)),("ruleset",str(worldRuleset target))])]
                      -- Old worker hooks retain their old status ref, while the
                      -- shared identity ref above makes their callback stale.
                      saveRef<-newIORef savedView
                      recordBytes<-either(fail.show)pure(encodeActivationRecord record)
                      traceShell next("activation-source-checkpoint "++hexBytes sourceBytes)
                      traceShell next("activation-cbor-v1 "++hexBytes recordBytes)
                      traceShell next("activated "++tokenText token++" targetHash="++show(activationTargetHash record)++" branch="++show(branchId target)++" authority="++sessionAuthority session)
                      pure next{rtWorld=target,rtSession=session,rtQueue=emptySaveQueue identity,rtSaveState=saveRef,rtLastSaved=Just(stamp target),rtSaveDirectory=directory
                        ,rtLoad=LoadTerminal "activated" intent(Just info)Nothing "検証済みの新しい枝へ切り替えました。時間は停止しています"
                        ,rtCatalogToken=Nothing,rtCatalogStatus="idle",rtCatalogError=Nothing}
            _->pure next

hexBytes :: BS.ByteString -> String
hexBytes=concatMap(\byte->[digits!!fromIntegral(byte `div` 16),digits!!fromIntegral(byte `mod` 16)]) . BS.unpack
  where digits="0123456789abcdef"
