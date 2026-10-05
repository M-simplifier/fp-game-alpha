module Colony.Fixture(fourColonyFixture,fixtureOrders) where
import Colony.Content
import Colony.Inventory
import Colony.Needs
import Colony.Power
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad(replicateM)
import qualified Data.Map.Strict as M

-- Explicit subsystem fixture, not S01, D0 or a playable campaign map.
-- Inputs start physically inside machine input stores; no teleport delivery is simulated.
fourColonyFixture :: Content -> Either Failure World
fourColonyFixture content=do
  ((sites,grids,residents,pantries,siteGrids),inv)<-runInventory build(emptyInventory content)
  let w=(initialWorld content) {worldInventory=inv,worldSites=M.fromList[(siteId s,s)|s<-sites],worldPowerGrids=M.fromList[(gridId g,g)|g<-grids]
                              ,worldSiteGrids=M.fromList siteGrids,worldNeeds=NeedsState(M.fromList[(residentId r,r)|r<-residents])(M.fromList pantries)}
  pure w
  where
    tx=TxId 1 1(BoundarySeq 0)P0 0
    grant owner resource q=mintLot tx InitialGrant Nothing resource q owner(SimTick 0)(case resource of Ration->Just(SimTick 576000);Crops->Just(SimTick 144000);_->Nothing)"explicit-foundation-fixture" >> pure()
    store colony kind=do
      ident<-freshId
      let owner=Owner kind ident
      addStorage owner(Storage 400000 Nothing colony)
      pure owner
    site colony rid inputs natural=do
      ident<-freshId
      let src=Owner MachineInput ident;dst=Owner MachineOutput ident
      addStorage src(Storage 400000 Nothing colony)
      addStorage dst(Storage 400000 Nothing colony)
      mapM_(uncurry(grant src))inputs
      pure(Site ident rid src dst natural 4 True)
    buildColony=do
      cid<-freshId
      pantry<-store cid Pantry
      grant pantry Water 120000
      grant pantry Ration 60000
      people<-replicateM 10(freshId >>= \ident->pure(newResident ident cid))
      aquifer<-addDeposit "aquifer" Water 50000000
      pump<-site cid "hand_water" [] (M.singleton "aquifer" aquifer)
      farm<-site cid "grow" [(Water,60000)] M.empty
      kitchen<-site cid "cook" [(Water,10000),(Crops,20000),(Fuel,1000)] M.empty
      generatorInput<-store cid MachineInput
      grant generatorInput Fuel 40000
      gid<-freshId
      generatorId'<-freshId
      let grid=PowerGrid gid [] [Generator generatorId' generatorInput True 100] [] M.empty
      pure([pump,farm,kitchen],[grid],people,[(cid,[pantry])],[(siteId kitchen,gid)])
    build=do
      groups<-replicateM 4 buildColony
      pure(foldr(\(s,g,r,p,m)(ss,gg,rr,pp,mm)->(s++ss,g++gg,r++rr,p++pp,m++mm))([],[],[],[],[])groups)

fixtureOrders :: World -> [OrderedCommand]
fixtureOrders world=[OrderedCommand ordinal(CommandId(worldId world)1(Epoch(worldAuthority world)1)(ordinal+1))(OrderProduction(siteId site))|(ordinal,site)<-zip[0..](M.elems(worldSites world))]
