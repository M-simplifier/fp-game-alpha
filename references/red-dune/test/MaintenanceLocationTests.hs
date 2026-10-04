module MaintenanceLocationTests(maintenanceLocationTests) where
import Colony.Content
import Colony.Maintenance
import Colony.Scheduler
import Colony.SupplyChainFixture
import Colony.Types
import Colony.Units
import Colony.UIFixture
import Colony.World
import Control.Monad(unless)
import qualified Data.Map.Strict as M

maintenanceLocationTests :: Content -> IO()
maintenanceLocationTests content=do
  (descriptor,world)<-either(fail.show)pure(uiFixture content)
  let target=supplyKitchen descriptor
  targetColony<-maybe(fail "fixture target location missing")pure(maintenanceTargetColony world target)
  let warehouses=[(owner,storageColony storage)|(owner@(Owner Warehouse _),storage)<-M.toList(invStorage(worldInventory world))]
      local=head[owner|(owner,colony)<-warehouses,colony==targetColony]
      remote=head[owner|(owner,colony)<-warehouses,colony/=targetColony]
      send source destination=pureStep(Boundary(BoundaryHeader(worldId world)(branchId world)(boundarySeq world)False(worldAuthority world)(worldRuleset world))
        [OrderedCommand 0(CommandId(worldId world)1(Epoch(worldAuthority world)1)1)(RequestMaintenance target source destination)][])world
      (badSource,sourceOut)=send remote local
      (badReturn,returnOut)=send local remote
      (good,goodOut)=send local local
      rejected out=case outputReceipts out of [receipt]->receiptOutcome receipt==CommandFailed(InvalidReference "MaintenancePartsNeedLocalDelivery");_->False
      applied out=case map receiptOutcome(outputReceipts out)of [Applied(Just _)]->True;_->False
  assert "remote maintenance source rejects without stock movement"(rejected sourceOut&&worldInventory badSource==worldInventory world&&M.null(maintenanceJobs(worldMaintenance badSource)))
  assert "remote cancellation return target also rejects"(rejected returnOut&&worldInventory badReturn==worldInventory world)
  assert "local source/return creates real planned reservation while paused"(length(maintenanceJobs(worldMaintenance good))==1&&applied goodOut)
  assert "local maintenance plan does not consume Parts"(M.findWithDefault 0(Parts,RecipeInput)(invLedger(worldInventory good))==0&&M.size(invQuantity(worldInventory good))>0)
  putStrLn "MaintenanceLocationTests PASS: cross-colony source/return rejected without material movement; local paused plan reserves physical Parts without consuming them"
  where assert label condition=unless condition(fail label)
