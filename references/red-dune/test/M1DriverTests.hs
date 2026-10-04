module M1DriverTests(main,m1DriverTests,step,accept,assert,must,m1) where
import Colony.Arena
import Colony.Codec
import Colony.Content
import Colony.M1State
import Colony.Needs
import Colony.S01Fixture
import Colony.Scheduler
import Colony.Transport
import Colony.Types
import Colony.Units
import qualified Colony.Workforce as W
import Colony.World
import Control.Monad(foldM,unless)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Game.Arena(play,singleton)
import System.Directory(createDirectoryIfMissing)

assert :: String -> Bool -> IO()
assert label condition=unless condition(ioError(userError("M1 driver: "++label)))
must :: Show e => String -> Either e a -> IO a
must label=either(ioError . userError . ((label++": ")++) . show)pure
m1 :: World -> M1State
m1=maybe(error "expected M1")id . worldM1
step :: Bool -> [Command] -> [ManagementEvent] -> World -> IO(World,ColonyOutput)
step advance bodies events world=do
  let epoch=participantEpoch(worldParticipants world M.!1);highest=M.findWithDefault 0(1,epoch)(worldHighWater world)
      ordered=[OrderedCommand n(CommandId 1 1 epoch(highest+n+1))body|(n,body)<-zip[0..]bodies]
      header=BoundaryHeader 1 1(boundarySeq world)advance(worldAuthority world)(worldRuleset world)
      native=Boundary header ordered events
  result<-must "Arena admission"(play Colony(RecordedBoundary header(map commandId ordered)events)(singleton 1(OrderedBatch ordered))world)
  assert "real direct/Arena parity"(result==pureStep native world)
  assert("native diagnostics "++show(snd result))(null(outputDiagnostics(snd result)))
  pure result
accept :: Bool -> [Command] -> [ManagementEvent] -> World -> IO World
accept advance commands events world=do
  (next,out)<-step advance commands events world
  assert("accepted "++show(outputReceipts out))(all(\r->case receiptOutcome r of Applied _->True;_->False)(outputReceipts out))
  pure next
m1DriverTests :: Content -> IO()
m1DriverTests content=do
  (descriptor,base)<-must "S01 base"(s01Fixture content)
  let vehicle=head(s01Carts descriptor);driver=(s01ShiftResidents descriptor M.!0)!!9;reserve=(s01ShiftResidents descriptor M.!0)!!11
      needs=(worldNeeds base){needsResidents=M.adjust(\person->person{residentFatigue=899})driver(needsResidents(worldNeeds base))}
      extra=m1 base
      state=extra{m1Workforce=(m1Workforce extra){W.workforceWorkers=M.adjust(\person->person{W.workerFatigueRemainder=1199})driver(W.workforceWorkers(m1Workforce extra))}}
      -- Explicit isolated acceptance fixture, not the normative S01 start:
      -- same portable vector, one registered cart changed to Truck capacity and
      -- one actual driver's fatigue placed just below the approved threshold.
      inventory=(worldInventory base){invStorage=M.adjust(\store->store{storageCapacity=300000})(Owner Vehicle vehicle)(invStorage(worldInventory base))}
      transport=(worldTransport base){transportVehicles=M.adjust(\cart->cart{vehicleKind=Truck})vehicle(transportVehicles(worldTransport base))}
      initial=base{worldNeeds=needs,worldM1=Just state,worldInventory=inventory,worldTransport=transport}
      position w=vehiclePosition(transportVehicles(worldTransport w)M.!vehicle)
      fuel w=M.findWithDefault 0(Fuel,FuelBurned)(invLedger(worldInventory w))
      xp who w=W.workerSkills(W.workforceWorkers(m1Workforce(m1 w))M.!who)M.!W.TransportSkill
  must "explicit driver fixture valid"(validateWorld initial)
  createDirectoryIfMissing True "evidence/m1-driver-0.6"
  bytes<-must "driver fixture checkpoint"(encodeCheckpoint(CheckpointMeta 1 Nothing "driver-isolated-test")initial)
  BS.writeFile "evidence/m1-driver-0.6/initial.cbor"bytes
  assigned<-accept False(s01RosterCommands descriptor)[]initial
  let source=head(s01Warehouses descriptor)
  requested<-accept False[RequestDelivery source(s01Pantry descriptor)Stone 2000 2][ResumeWorld]assigned
  started<-accept True[][]requested
  assert "real truck entered one edge"(case position started of Traversing _ _ remaining _->remaining==10;_->False)
  assert "edge fuel charged once"(fuel started==100)
  assert "forced rest records full8h timer"(W.workerForcedRestUntil(W.workforceWorkers(m1Workforce(m1 started))M.!driver)==Just(SimTick 16801))
  assert "edge entry without movement has no transport XP"(xp driver started==W.SkillProgress 0 0)
  stopped<-accept True[][]started
  assert "no driver preserves exact edge remainder and spent fuel"(position stopped==position started&&fuel stopped==100)
  assert "public transport block is NoDriver"(vehicleBlock(transportVehicles(worldTransport stopped)M.!vehicle)==Just NoDriver)
  paused<-accept False[][PauseWorld]stopped
  pausedMany<-foldM(\world _->accept False[][]world)paused[1..25::Int]
  assert "paused boundaries preserve fatigue/timer/progress"(worldM1 pausedMany==worldM1 paused&&worldInventory pausedMany==worldInventory paused&&position pausedMany==position paused)
  snapshot<-must "forced rest in-edge V4 checkpoint"(encodeCheckpoint(CheckpointMeta 2 Nothing "driver-resting-save")pausedMany)
  (_,loaded)<-must "forced rest in-edge reload"(decodeCheckpoint snapshot)
  assert "rest/edge/cargo/fuel canonical roundtrip"(loaded==pausedMany)
  replacing<-accept False[AssignWorkers(W.DriveVehicle vehicle)0[driver,reserve]][ResumeWorld]loaded
  let other=(s01Carts descriptor)!!1
  (denied,out)<-step False[AssignWorkers(W.DriveVehicle other)0[reserve]][]replacing
  assert "replacement cannot drive two vehicles"(worldM1 denied==worldM1 replacing&&all(\r->case receiptOutcome r of CommandFailed _->True;_->False)(outputReceipts out))
  resumed<-accept True[][]denied
  assert "handoff resumes exactly one edge tick"(case(position stopped,position resumed)of (Traversing a b n r,Traversing x y m s)->(a,b,r)==(x,y,s)&&m==n-1;_->False)
  assert "handoff never charges same edge again"(fuel resumed==100)
  assert "actual replacement gets one XP, resting driver gets zero"(xp reserve resumed==W.SkillProgress 0 1&&xp driver resumed==W.SkillProgress 0 0)
  assert "exclusive actual replacement claim"(M.lookup reserve(W.workforceClaims(m1Workforce(m1 resumed)))==Just(W.DriveVehicle vehicle)&&not(M.member driver(W.workforceClaims(m1Workforce(m1 resumed)))))
  (busy,receipt)<-step False[AssignWorkers(W.DriveVehicle vehicle)0[]][]resumed
  assert "moving driver removal Busy is atomic"(worldM1 busy==worldM1 resumed&&all(\r->case receiptOutcome r of CommandFailed(InvalidReference reason)->take 4 reason=="Busy";_->False)(outputReceipts receipt))
  putStrLn "M1_DRIVER real truck edge / paid fuel /899+remainder forced rest / NoDriver / pause / V4 reload / existing named replacement / cross-vehicle exclusivity PASS; commuting positions unmodeled"
main :: IO()
main=loadContent "data/content-v1.json" >>= must "content" >>= m1DriverTests
