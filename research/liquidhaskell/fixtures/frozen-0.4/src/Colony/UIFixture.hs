-- Explicit interactive M1 fixture extension. No operational credit or hidden
-- replenishment is created; bootstrap Parts are visible InitialGrant assets.
module Colony.UIFixture(uiFixture) where
import Colony.Content
import Colony.Inventory
import Colony.Maintenance
import Colony.Power
import Colony.Ruleset(currentV1Ruleset)
import Colony.SupplyChainFixture
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad(foldM)
import qualified Data.Map.Strict as M

uiFixture :: Content -> Either Failure (SupplyChainDescriptor,World)
uiFixture content=do
  (descriptor,base)<-fourColonySupplyChain content
  let siteFacilities=[(siteId site,recipeBuilding recipe)|site<-M.elems(worldSites base),Just recipe<-[M.lookup(siteRecipe site)(contentRecipes content)]]
      powerFacilities=concatMap(\grid->[(solarId panel,"solar")|panel<-gridSolar grid]++[(generatorId generator,"generator")|generator<-gridGenerators grid]++[(batteryId battery,"battery")|battery<-gridBatteries grid])(M.elems(worldPowerGrids base))
  facilities<-mapM(uncurry(newFacility content))(siteFacilities++powerFacilities)
  (transport,inventory)<-runInventory (foldM addPartsStore(worldTransport base)(zip(supplyColonies descriptor)(supplyColonyPorts descriptor)))(worldInventory base)
  let maintenance=MaintenanceState(M.fromList[(facilityId facility,facility)|facility<-facilities])M.empty
      crews=M.fromList[(facilityId facility,1)|facility<-facilities,facilityPeriod facility>0]
      next=base {worldInventory=inventory,worldTransport=transport,worldMaintenance=maintenance,worldMaintenanceCrews=crews,worldMode=Paused,worldRuleset=currentV1Ruleset}
      labeled=descriptor {supplyFixtureVersion="four-colony-road-v1+ui-maintenance-bootstrap-v1+split-return-profile4"}
  validateWorld next
  pure(labeled,next)
  where
    addPartsStore transport(colony,node)=do
      ident<-freshId
      let owner=Owner Warehouse ident
      addStorage owner(Storage 2000000 Nothing colony)
      _<-mintLot(TxId 1 1(BoundarySeq 0)P0 1)InitialGrant Nothing Parts 40 owner(SimTick 0)Nothing"explicit-ui-fixture-maintenance-bootstrap"
      addTransportPort owner node transport
