module M1IntegrityTests(main,m1IntegrityTests,rejectMalformedWorld) where
import Colony.Codec
import Colony.Codec.CBOR
import Colony.Codec.Value(toCBOR)
import Colony.Content
import Colony.Inventory
import Colony.Jobs
import Colony.M1State
import Colony.Power
import Colony.Maintenance
import Colony.S01Fixture
import qualified Colony.Space as S
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World
import M1DriverTests(step,accept,assert,must)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.Set as Set

left :: Either a b -> Bool
left(Left _)=True
left _=False
m1IntegrityTests :: Content -> IO()
m1IntegrityTests content=do
  (d,base)<-must "normative base"(s01Fixture content)
  let home=head(s01Warehouses d);remote=(s01Warehouses d)!!1;vehicle=head(s01Carts d)
      extra=maybe(error "M1 absent")id(worldM1 base);space=m1Space extra;transport=worldTransport base
      mutateSpace f w=w{worldM1=fmap(\state->state{m1Space=f(m1Space state)})(worldM1 w)}
      swapped=mutateSpace(\state->state{S.spatialOwnerLocations=M.insert home(S.spatialOwnerLocations space M.!remote)(S.spatialOwnerLocations state)})base
      displaced=swapped{worldTransport=transport{transportPorts=M.insert home(transportPorts transport M.!remote)(transportPorts transport)}}
  rejectMalformedWorld "warehouse geometry+port moved together"base displaced
  rejectMalformedWorld "siteInput alias"base base{worldSites=M.adjust(\site->site{siteInput=Owner MachineInput(s01Kitchen d)})(s01Farm d)(worldSites base)}
  rejectMalformedWorld "siteOutput alias"base base{worldSites=M.adjust(\site->site{siteOutput=Owner MachineOutput(s01Kitchen d)})(s01Farm d)(worldSites base)}
  rejectMalformedWorld "unknown vehicle colony"base base{worldTransport=transport{transportVehicles=M.adjust(\v->v{vehicleColony=EntityId 99999999})vehicle(transportVehicles transport)}}
  rejectMalformedWorld "missing vehicle fuel owner"base base{worldTransport=transport{transportVehicles=M.adjust(\v->v{vehicleFuelSource=Owner Warehouse(EntityId 99999999)})vehicle(transportVehicles transport)}}
  rejectMalformedWorld "vehicle cargo artificially water-only"base base{worldInventory=(worldInventory base){invStorage=M.adjust(\store->store{storageResource=Just Water})(Owner Vehicle vehicle)(invStorage(worldInventory base))}}
  planned<-accept False[OrderProduction(s01Farm d)][]base
  let jobIdValue=head(M.keys(worldJobs planned));wip=Owner MachineInput jobIdValue
      wipLocated=mutateSpace(\state->state{S.spatialOwnerLocations=M.insert wip(S.spatialOwnerLocations space M.!remote)(S.spatialOwnerLocations state)})planned
      wipPublic=wipLocated{worldTransport=(worldTransport wipLocated){transportPorts=M.insert wip(transportPorts transport M.!remote)(transportPorts(worldTransport wipLocated))}}
  rejectMalformedWorld "internal WIP exposed as public remote port"planned wipPublic
  rejectMalformedWorld "recipe job remapped to another facility"planned planned{worldJobSites=M.singleton jobIdValue(s01Kitchen d)}
  rejectMalformedWorld "recipe job missing required facility link"planned planned{worldJobSites=M.empty}
  rejectMalformedWorld "jobInput retargeted independently"planned planned{worldJobs=M.adjust(\job->job{jobInput=Owner MachineInput(s01Kitchen d)})jobIdValue(worldJobs planned)}
  naturalPlan<-accept False[OrderProduction(s01Pump d)][]base
  (source,inventory)<-must "independent distant natural source"(runInventory(addDeposit "aquifer" Water 100000)(worldInventory naturalPlan))
  let distant=mutateSpace(\state->state{S.spatialSources=M.insert source(S.SourceRegion source "aquifer" Water(S.Rect(S.Tile 10 50)8 8))(S.spatialSources state)})naturalPlan{worldInventory=inventory}
      naturalJob=head(M.keys(worldJobs distant))
  must "valid distant source control"(validateWorld distant)
  rejectMalformedWorld "job natural source differs from physical pump"distant distant{worldJobs=M.adjust(\job->job{jobNaturalSources=M.singleton "aquifer" source})naturalJob(worldJobs distant)}
  ordered<-accept False[RequestDelivery home(s01Pantry d)Stone 1000 2][]base
  let deliveries=worldTransport ordered;request=head(M.keys(transportRequests deliveries))
  rejectMalformedWorld "request source differs from lot reservations"ordered ordered{worldTransport=deliveries{transportRequests=M.adjust(\r->r{requestSource=remote})request(transportRequests deliveries)}}
  rejectMalformedWorld "request resource differs from lot reservations"ordered ordered{worldTransport=deliveries{transportRequests=M.adjust(\r->r{requestResource=Water})request(transportRequests deliveries)}}
  -- Runtime admission and checkpoint validation share the same public-port
  -- lookup. Merely owning an internal WIP store never exposes it for shipping.
  (denied,denial)<-step False[RequestDelivery home wip Stone 1000 2,RequestDelivery wip(s01Pantry d)Stone 1000 2][]planned
  assert "internal WIP delivery admission rejects both directions atomically"(worldInventory denied==worldInventory planned&&worldTransport denied==worldTransport planned&&all(\receipt->case receiptOutcome receipt of CommandFailed(InvalidReference "MissingRoadPort")->True;_->False)(outputReceipts denial))
  legitimate<-accept False[RequestDelivery home(s01Pantry d)Stone 1000 2][]planned
  let tr=worldTransport legitimate;ri=head(M.keys(transportRequests tr));inv=worldInventory legitimate
      forged=legitimate{worldTransport=tr{transportRequests=M.adjust(\r->r{requestDestination=wip})ri(transportRequests tr)}
        ,worldInventory=inv{invCapacity=M.map(\claim->if capacityJob claim==ri then claim{capacityOwner=wip}else claim)(invCapacity inv)}}
  rejectMalformedWorld "live parent and matching capacity cannot target internal WIP"legitimate forged
  (ghost,freshInventory)<-must "fresh isolated power device ID"(runInventory freshId(worldInventory base))
  let gid=head(M.keys(worldPowerGrids base));grid=worldPowerGrids base M.!gid
      fresh=base{worldInventory=freshInventory}
      solar=solarId(head(gridSolar grid));battery=batteryId(head(gridBatteries grid))
      powerChange changed=fresh{worldPowerGrids=M.insert gid changed(worldPowerGrids fresh)}
  must "fresh counter control"(validateWorld fresh)
  rejectMalformedWorld "ghost solar lacks Built placement"fresh(powerChange grid{gridSolar=gridSolar grid++[Solar ghost 100]})
  rejectMalformedWorld "ghost battery lacks Built placement"fresh(powerChange grid{gridBatteries=gridBatteries grid++[Battery ghost 0 0 100]})
  rejectMalformedWorld "grid key aliases unknown entity"fresh(powerChange grid{gridId=ghost})
  mapM_(\ident->rejectMalformedWorld("missing mandatory maintenance "++show ident)base base{worldMaintenance=(worldMaintenance base){maintenanceFacilities=M.delete ident(maintenanceFacilities(worldMaintenance base))}})[s01Pump d,solar,battery]
  rejectMalformedWorld "disconnected solar wire cannot power a fixed circuit"base(mutateSpace(\state->state{S.spatialWires=Set.delete(S.Tile 97 43)(S.spatialWires state)})base)
  rejectMalformedWorld "powered kitchen missing circuit binding"base base{worldSiteGrids=M.delete(s01Kitchen d)(worldSiteGrids base)}
  putStrLn "M1_INTEGRITY physical geometry/site/job/source/parent reservation/vehicle/power/lifecycle references:22 typed validate + encode + correctly rehashed decode rejection cases PASS"


rejectMalformedWorld :: String -> World -> World -> IO()
rejectMalformedWorld label good bad=do
  assert(label++" World validator rejects")(left(validateWorld bad))
  assert(label++" encode rejects")(left(encodeCheckpoint defaultCheckpointMeta bad))
  envelope<-must "valid comparison envelope"(encodeCheckpoint defaultCheckpointMeta good)
  tree<-must "encode malformed typed state"(toCBOR bad)
  payload<-must "canonical malformed payload"(encodeCanonical tree)
  root<-must "parse valid envelope"(decodeCanonical envelope)
  forged<-case root of
    CMap fields->must "correct checksum forged checkpoint"(encodeCanonical(CMap[(key,case key of 11->CInteger(toInteger(BS.length payload));12->CBytes(sha256 payload);13->CBytes(sha256 payload);16->CBytes payload;_->value)|(key,value)<-fields]))
    _->ioError(userError "envelope shape")
  assert(label++" valid checksum cannot bypass semantic reject")(left(decodeCheckpoint forged))

main :: IO()
main=loadContent "data/content-v1.json" >>= must "content" >>= m1IntegrityTests
