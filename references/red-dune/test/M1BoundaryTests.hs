module M1BoundaryTests(main,m1BoundaryTests) where
import Colony.Arena
import Colony.Codec
import Colony.Content
import qualified Colony.Construction as C
import Colony.M1State
import Colony.S01Fixture
import Colony.Scheduler
import qualified Colony.Space as S
import Colony.Transport
import Colony.Types
import Colony.Units
import qualified Colony.Workforce as W
import Colony.World
import M1DriverTests(step,accept,assert,must,m1)
import Control.Monad(foldM)
import qualified Data.Map.Strict as M
import Game.Arena(play,singleton)

m1BoundaryTests :: Content -> IO()
m1BoundaryTests content=do
  (descriptor,initial)<-must "S01 boundary control"(s01Fixture content)
  let vehicle=head(s01Carts descriptor);driver=(s01ShiftResidents descriptor M.!0)!!9;builders=take 2(drop 11(s01ShiftResidents descriptor M.!0))
      colony=s01Colony descriptor;tile=S.Tile 61 64;home=head(s01Warehouses descriptor)
      job world site=C.constructionJobs(m1Construction(m1 world))M.!site
      physical world owner resource=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots(worldInventory world)),lotOwner lot==owner,lotResource lot==resource]
  staffed<-accept False[AssignWorkers(W.DriveVehicle vehicle)0[driver]][]initial
  (planned,out)<-step False[PlaceConstructionPlan colony(S.RoadShape tile)2 Nothing][]staffed
  site<-case[ident|receipt<-outputReceipts out,Applied(Just ident)<-[receiptOutcome receipt]]of [ident]->pure ident;_->ioError(userError "site receipt")
  supplied<-accept False[AssignWorkers(W.ConstructSite site)0 builders,RequestDelivery home(Owner MachineInput site)Stone 2000 2][ResumeWorld]planned
  beforeArrival<-untilBound 500(\world->case vehiclePosition(transportVehicles(worldTransport world)M.!vehicle)of
    Traversing _ to 1 _->Just to==M.lookup(Owner MachineInput site)(transportPorts(worldTransport world));_->False)supplied
  assert "cancel/arrival witness really precedes physical unload"(physical beforeArrival(Owner MachineInput site)Stone==0)
  snapshot<-must "same-boundary predecessor save"(encodeCheckpoint(CheckpointMeta 1 Nothing "same-boundary-arrival")beforeArrival)
  (_,restored)<-must "same-boundary predecessor reload"(decodeCheckpoint snapshot)
  let cancel=CancelConstructionPlan site(C.constructionRevision(job beforeArrival site))
  cancelled<-accept True[cancel][]beforeArrival
  sameSaved<-accept True[cancel][]restored
  assert "P1 cancel beats P4 arrival and P5 start, reload identical"(cancelled==sameSaved&&C.constructionPhase(job cancelled site)==C.ConstructionCancelled&&C.constructionProgress(job cancelled site)==0)
  assert "unreceived stock is not refunded or lost"(M.findWithDefault 0(Stone,ConstructionLoss)(invLedger(worldInventory cancelled))==0&&M.findWithDefault 0(Stone,ConstructionConsumed)(invLedger(worldInventory cancelled))==0)
  assert "loaded cargo now has one real Return owner"(any(\shipment->case shipmentKind shipment of ReturnShipment _->shipmentStatus shipment==ShipmentCarrying;_->False)(M.elems(transportShipments(worldTransport cancelled))))
  returned<-untilBound 1000(\world->all shipmentTerminal(M.elems(transportShipments(worldTransport world))))cancelled
  assert "real Return restores all source stone exactly once"(physical returned home Stone==physical initial home Stone)
  control<-accept True[][]beforeArrival
  assert "without cancel same arrival legitimately starts and credits work"(C.constructionPhase(job control site)==C.ConstructionRunning&&C.constructionProgress(job control site)==100)
  almost<-foldM(\world _->accept True[][]world)control[1..18::Int]
  assert "completion collision witness is one tick from finish"(C.constructionProgress(job almost site)==1900)
  finished<-accept True[][]almost
  assert "control completes atomically"(C.constructionPhase(job finished site)==C.ConstructionCompleted&&M.findWithDefault 0(Stone,ConstructionConsumed)(invLedger(worldInventory finished))==2000)
  cancelledFinish<-accept True[CancelConstructionPlan site(C.constructionRevision(job almost site))][]almost
  assert "P1 cancel beats same tick P7 completion"(C.constructionPhase(job cancelledFinish site)==C.ConstructionCancelled&&M.findWithDefault 0(Stone,ConstructionConsumed)(invLedger(worldInventory cancelledFinish))==0&&M.findWithDefault 0(Stone,ConstructionLoss)(invLedger(worldInventory cancelledFinish))==950)
  let receipt=head(worldReceipts cancelledFinish)
      repeated=OrderedCommand 0(receiptCommand receipt)(receiptBody receipt)
      header=BoundaryHeader(worldId cancelledFinish)(branchId cancelledFinish)(boundarySeq cancelledFinish)False(worldAuthority cancelledFinish)(worldRuleset cancelledFinish)
      native=Boundary header[repeated][]
      direct=pureStep native cancelledFinish
  replayed<-must "duplicate admitted through actual Arena"(play Colony(RecordedBoundary header[receiptCommand receipt][])(singleton 1(OrderedBatch[repeated]))cancelledFinish)
  assert "duplicate cancellation returns cached receipt without repeated loss/refund"(direct==replayed&&worldInventory(fst direct)==worldInventory cancelledFinish&&worldM1(fst direct)==worldM1 cancelledFinish&&outputReceipts(snd direct)==[receipt]&&null(outputEvents(snd direct)))
  putStrLn "M1_BOUNDARY real loaded cancel-before-arrival/start and cancel-before-completion + V4 reload + command dedup PASS"
  where
    untilBound remaining predicate world
      |predicate world=pure world
      |remaining==(0::Integer)=ioError(userError("boundary witness timed out at "++show(simTick world)))
      |otherwise=accept True[][]world >>= untilBound(remaining-1)predicate
main :: IO()
main=loadContent "data/content-v1.json" >>= must "content" >>= m1BoundaryTests
