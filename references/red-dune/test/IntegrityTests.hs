module IntegrityTests(integrityTests) where
import Colony.Codec
import Colony.Content
import Colony.Fixture
import Colony.Inventory
import Colony.Jobs
import Colony.Needs
import Colony.Scheduler
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad(unless)
import Data.Either(isLeft)
import qualified Data.Map.Strict as M

integrityTests :: Content -> IO()
integrityTests content=do
  world<-right(fourColonyFixture content)
  right(validateWorld world)
  let inv=worldInventory world
      hand=head[s|s<-M.elems(worldSites world),siteRecipe s=="hand_water"]
      farm=head[s|s<-M.elems(worldSites world),siteRecipe s=="grow"]
      colony=storageColony(head(M.elems(invStorage inv)))
      source=head(M.elems(siteNatural hand))
      wrongDeposit=inv {invDeposits=M.adjust(\d->d {depositKind="ore_deposit",depositResource=Ore})source(invDeposits inv)}
      wrongWorld=world {worldInventory=wrongDeposit}
  assert "wrong hand-pump ore binding rejected by world and checkpoint"(isLeft(validateWorld wrongWorld)&&isLeft(encodeCheckpoint defaultCheckpointMeta wrongWorld))
  let collisionId=EntityId(invNextId inv)
      collision=world {worldNeeds=(worldNeeds world){needsResidents=M.insert collisionId(newResident collisionId colony)(needsResidents(worldNeeds world))}}
  assert "future allocator collision with resident rejected"(isLeft(validateWorld collision)&&isLeft(encodeCheckpoint defaultCheckpointMeta collision))
  let (rejected,out)=runCommand(OrderProduction(siteId hand))collision
  assert "allocator collision cannot publish job or receipt"(case worldMode rejected of Faulted _->worldJobs rejected==worldJobs collision&&simTick rejected==simTick collision&&boundarySeq rejected==boundarySeq collision&&null(outputReceipts out)&&null(outputEvents out);_->False)
  let lot=head(M.elems(invLots inv));existing=lotId lot
  assert "storage cannot reuse physical lot ID"(isLeft(runInventory(addStorage(Owner Warehouse existing)(Storage 100000 Nothing colony))inv))
  let (running,startOut)=runCommand(OrderProduction(siteId farm))world
  assert "real farm started"(null(outputDiagnostics startOut))
  let job=head(M.elems(worldJobs running));jid=jobId job
  (_,drained)<-right(runInventory(moveFree(simTick running)(wipOwner job)(jobOutput job)Water 60000)(worldInventory running))
  let stolen=running {worldInventory=drained}
  assert "missing WIP rejected by World and checkpoint"(isLeft(validateWorld stolen)&&isLeft(encodeCheckpoint defaultCheckpointMeta stolen))
  assert "complete cannot mint from missing WIP"(isLeft(runInventory(completeJob content(TxId 1 1(BoundarySeq 2)P7 0)(SimTick 7200)(job {jobProgress=jobRequired job}))drained))
  (_,unreserved)<-right(runInventory(releaseJob jid)(worldInventory running))
  assert "missing output capacity rejects running world"(isLeft(validateWorld(running {worldInventory=unreserved})))
  let pantry=head[o|o@(Owner Pantry _)<-M.keys(invStorage inv)]
      overCapacity=inv {invStorage=M.adjust(\storage->storage {storageCapacity=400001})pantry(invStorage inv)}
  assert "World cannot inflate owner-class capacity"(isLeft(validateWorld(world {worldInventory=overCapacity})))
  (_,orphan)<-right(runInventory(reserveQuantity(SimTick 0)(EntityId 999999)pantry Water 1)inv)
  assert "reservation must refer to registered job"(isLeft(validateWorld(world {worldInventory=orphan})))
  putStrLn "IntegrityTests PASS: wrong extraction, global ID reuse, storage/lot collision, missing WIP, missing capacity and orphan reservations rejected by actual kernel/checkpoint paths"
  where
    assert label condition=unless condition(ioError(userError label))
    right=either(ioError.userError.show)pure
    runCommand body world=pureStep(Boundary(BoundaryHeader(worldId world)(branchId world)(boundarySeq world)True(worldAuthority world)(worldRuleset world))
      [OrderedCommand 0(CommandId(worldId world)1(Epoch(worldAuthority world)1)1)body][])world
