-- Explicit initial assets for the B01 interruption scenario. After this initial
-- construction, all gameplay changes run through ordinary NativeInput commands.
module Colony.CombinedFixture(combinedFixture) where
import Colony.Content
import Colony.Inventory
import Colony.Ruleset(currentV1Ruleset)
import Colony.SupplyChainFixture
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World

combinedFixture :: Content -> Either Failure(SupplyChainDescriptor,Owner,World)
combinedFixture content=do
  (descriptor,base)<-fourColonySupplyChain content
  let sourceColony=last(supplyColonies descriptor)
      sourceNode=last(supplyColonyPorts descriptor)
      generator=Owner MachineInput(supplyGenerator descriptor)
  ((source,transport),inventory)<-runInventory(do
    ident<-freshId
    let source=Owner Warehouse ident
    addStorage source(Storage 2000000 Nothing sourceColony)
    -- Reposition existing grant only during explicit initial setup. Generator
    -- starts with2000;48000 is physically at the remote warehouse after the
    -- additional10000 InitialGrant. No post-start refill or state edit exists.
    moveFree(SimTick 0)generator source Fuel 38000
    _<-mintLot(TxId 1 1(BoundarySeq 0)P0 1)InitialGrant Nothing Fuel 10000 source(SimTick 0)Nothing"b01-explicit-additional-fuel-bootstrap"
    connected<-addTransportPort source sourceNode(worldTransport base)
    pure(source,connected))(worldInventory base)
  let world=base{worldInventory=inventory,worldTransport=transport,worldRuleset=currentV1Ruleset}
  validateWorld world
  pure(descriptor{supplyFixtureVersion="b01-combined-interruption-v1"},source,world)
