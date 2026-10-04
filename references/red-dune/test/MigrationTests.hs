{-# LANGUAGE BangPatterns #-}
module MigrationTests (migrationTests) where

import Colony.Codec
import Colony.Content
import Colony.Inventory
import Colony.Jobs
import Colony.Maintenance
import Colony.Migrate
import Colony.Needs
import Colony.Power
import Colony.RNG
import Colony.Scheduler
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad (forM_,unless,void)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Data.Word (Word64)
import System.Directory (createDirectoryIfMissing)

assert :: String -> Bool -> IO ()
assert label ok=unless ok(ioError(userError("Migration assertion: "++label)))
must :: Show e => Either e a -> IO a
must=either(ioError.userError.show)pure
rejects :: Either a b -> Bool
rejects(Left _)=True
rejects _=False

tickInput :: Bool -> [Command] -> World -> NativeInput
tickInput advance commands world=Boundary header ordered []
  where
    header=BoundaryHeader(worldId world)(branchId world)(boundarySeq world)advance(worldAuthority world)(worldRuleset world)
    epoch=Epoch(worldAuthority world)1
    previous=M.findWithDefault 0(1,epoch)(worldHighWater world)
    ordered=[OrderedCommand ordinal(CommandId(worldId world)1 epoch(previous+ordinal+1))command|(ordinal,command)<-zip[0..]commands]

step :: Bool -> [Command] -> World -> IO World
step advance commands world=do
  let(next,out)=pureStep(tickInput advance commands world)world
  assert("pureStep rejected/faulted "++show(outputDiagnostics out))(null(outputDiagnostics out)&&worldMode next==Active)
  must(validateWorld next)
  pure next

suffix :: Word64 -> World -> IO World
suffix count=go count where
  go 0 !world=pure world
  go n !world=step True [] world >>= go(n-1)

-- A real kitchen with a battery-backed grid, an allocated resident, pantry and
-- independent PRNG streams. All IDs come from the common inventory allocator.
kitchenFixture :: Content -> Bool -> IO (EntityId,World)
kitchenFixture content hasIngredients=do
  ((site,grid,resident,pantry),inventory)<-must$runInventory(do
    colony<-freshId
    sid<-freshId
    let input=Owner MachineInput sid;output=Owner MachineOutput sid
    addStorage input(Storage 400000 Nothing colony)
    addStorage output(Storage 400000 Nothing colony)
    if hasIngredients then mapM_(\(resource,quantity)->void(mintLot tx InitialGrant Nothing resource quantity input(SimTick 10)(if resource==Crops then Just(SimTick 144010)else Nothing)"legacy-fixture"))[(Crops,20000),(Water,10000),(Fuel,1000)]else pure()
    pid<-freshId
    let pantry=Owner Pantry pid
    addStorage pantry(Storage 400000 Nothing colony)
    void(mintLot tx InitialGrant Nothing Water 60000 pantry(SimTick 10)Nothing "pantry")
    void(mintLot tx InitialGrant Nothing Ration 30000 pantry(SimTick 10)(Just(SimTick 576010))"pantry")
    rid<-freshId
    gid<-freshId
    bid<-freshId
    pure(Site sid "cook" input output M.empty 4 True,PowerGrid gid [] [] [Battery bid 720000000 3 100](M.singleton InitialEnergy 720000000),newResident rid colony,pantry)) (emptyInventory content)
  (_,drawn)<-must(drawFromStream 37 WeatherStream(initialRng 987))
  let world=(initialWorld content){simTick=SimTick 100,worldInventory=inventory,worldSites=M.singleton(siteId site)site
        ,worldPowerGrids=M.singleton(gridId grid)grid,worldSiteGrids=M.singleton(siteId site)(gridId grid)
        ,worldNeeds=NeedsState(M.singleton(residentId resident)resident)(M.singleton(residentColony resident)[pantry]),worldRng=drawn}
  must(validateWorld world)
  pure(siteId site,world)
  where tx=TxId 1 1(BoundarySeq 0)P0 0

jobSnapshots :: Content -> IO [(String,World)]
jobSnapshots content=do
  (sid,initial)<-kitchenFixture content True
  planned<-step False[OrderProduction sid]initial
  running<-step True[]planned >>= suffix 37
  let job=head(M.elems(worldJobs running))
      requiredTicks=fromInteger(jobRequired job `div` 100)
  completed<-suffix requiredTicks running
  cancelled<-step False[CancelProduction(jobId job)]running
  let SimTick tick=simTick running
      almostExpired=running{worldInventory=(worldInventory running){invLots=M.map(\lot->if lotOwner lot==wipOwner job&&lotResource lot==Crops then lot{lotExpires=Just(SimTick(tick+1))}else lot)(invLots(worldInventory running))}}
  failed<-step True[]almostExpired
  (waitingSite,noInputs)<-kitchenFixture content False
  waiting<-step True[OrderProduction waitingSite]noInputs
  assert "actual kernel-generated production phases"
    (map(jobPhase.head.M.elems.worldJobs)[planned,waiting,running,completed,cancelled,failed]==[Planned,WaitingInputs,Running,Completed,Cancelled,Failed ExpiredInput])
  (naturalSite,naturalBase)<-kitchenFixture content False
  (deposit,withDeposit)<-must(runInventory(addDeposit "aquifer" Water 500000)(worldInventory naturalBase))
  let naturalInitial=naturalBase{worldInventory=withDeposit,worldSites=M.adjust(\site->site{siteRecipe="hand_water",siteNatural=M.singleton "aquifer" deposit})naturalSite(worldSites naturalBase)}
  naturalRunning<-step True[OrderProduction naturalSite]naturalInitial >>= suffix 37
  assert "real natural extraction reservation is present"(not(M.null(invNatural(worldInventory naturalRunning))))
  pure[("planned",planned),("waiting-inputs",waiting),("running-wip",running),("completed",completed),("cancelled",cancelled),("failed-expiry",failed),("natural-running",naturalRunning)]

transportSnapshots :: Content -> IO [(String,World)]
transportSnapshots content=do
  a<-must(roadNode 10 10);b<-must(roadNode 11 10);c<-must(roadNode 12 10)
  topology<-must(setRoad(BoundarySeq 0)a b 10 True emptyTopology >>= setRoad(BoundarySeq 0)b c 10 True)
  ((request,transport),inventory)<-must$runInventory(do
    colony<-freshId
    srcId<-freshId;dstId<-freshId
    let src=Owner Warehouse srcId;dst=Owner Warehouse dstId
    addStorage src(Storage 2000000 Nothing colony)
    addStorage dst(Storage 2000000 Nothing colony)
    void(mintLot tx InitialGrant Nothing Ration 20000 src(SimTick 0)(Just(SimTick 576000))"vehicle-food")
    ports<-addTransportPort src a(emptyTransport{transportTopology=topology}) >>= addTransportPort dst c
    (_,vehicles)<-addTransportVehicle CarrierCart colony src src a(SimTick 100)ports
    planDelivery(SimTick 100)src dst Ration 20000 2 vehicles) (emptyInventory content)
  let reserved=(initialWorld content){simTick=SimTick 100,worldInventory=inventory,worldTransport=transport}
  must(validateWorld reserved)
  carrying<-step True[]reserved
  assert "real shipment entered road edge"(any((==ShipmentCarrying).shipmentStatus)(M.elems(transportShipments(worldTransport carrying))))
  delivered<-suffix 25 carrying
  assert "real shipment delivered"(requestStatus(transportRequests(worldTransport delivered)M.!request)==RequestCompleted)
  pure[("transport-reserved",reserved),("transport-carrying-food",carrying),("transport-delivered",delivered)]
  where tx=TxId 1 1(BoundarySeq 0)P0 0

preserved :: World -> World -> Bool
preserved before after=assetTotals(worldInventory before)==assetTotals(worldInventory after)
  &&invStorage(worldInventory before)==invStorage(worldInventory after)
  &&invNatural(worldInventory before)==invNatural(worldInventory after)
  &&invDeposits(worldInventory before)==invDeposits(worldInventory after)
  &&invLedger(worldInventory before)==invLedger(worldInventory after)
  &&invRecentLedger(worldInventory before)==invRecentLedger(worldInventory after)
  &&invLoad(worldInventory before)==invLoad(worldInventory after)
  &&invShelf(worldInventory before)==invShelf(worldInventory after)
  &&worldJobs before==worldJobs after&&worldSites before==worldSites after
  &&worldJobSites before==worldJobSites after&&worldNeeds before==worldNeeds after
  &&worldPowerGrids before==worldPowerGrids after&&worldSiteGrids before==worldSiteGrids after
  &&worldPoweredSites before==worldPoweredSites after&&worldRng before==worldRng after
  &&worldReceipts before==worldReceipts after&&worldHighWater before==worldHighWater after
  &&worldParticipants before==worldParticipants after&&worldRecentEvents before==worldRecentEvents after
  &&worldWeather before==worldWeather after&&worldContent before==worldContent after
  &&worldMaintenance before==worldMaintenance after
  &&worldMaintenanceCrews before==worldMaintenanceCrews after
  &&worldOperatingFacilities before==worldOperatingFacilities after
  &&worldMaintenanceAttempts before==worldMaintenanceAttempts after
  &&worldMode before==worldMode after&&simTick before==simTick after&&boundarySeq before==boundarySeq after
  &&worldRevision before==worldRevision after&&worldId before==worldId after
  &&worldAuthority before==worldAuthority after&&worldRuleset before==worldRuleset after
  &&transportToLegacy(worldTransport before)==transportToLegacy(worldTransport after)

fixtureContinuation :: (String,World) -> IO ()
fixtureContinuation(label,world)=do
  old1<-must(legacyV1Fixture world)
  bytes1<-must(encodeLegacyV1 old1)
  decoded1<-must(decodeLegacyV1 bytes1)
  assert(label++" V1 actual old schema roundtrip")(decoded1==old1)
  v2<-must(migrateV1ToV2 decoded1)
  bytes2<-must(encodeLegacyV2 v2)
  decoded2<-must(decodeLegacyV2 bytes2)
  assert(label++" V2 actual old schema roundtrip")(decoded2==v2)
  (new,report)<-must(migrateV2ToV3 2 decoded2)
  assert(label++" full unchanged state and owner/asset preservation")(preserved world new)
  assert(label++" preservation receipt")(migrationAssetsBefore report==migrationAssetsAfter report&&migrationTargetBranch report==2&&migrationSourceBranch report==1)
  again<-must(migrateV2ToV3 2 decoded2)
  assert(label++" deterministic allocation and receipt")(again==(new,report))
  result<-must(migrateLegacyBytes 2 bytes1)
  assert(label++" source bytes immutable and sequential wrapper identical")(migrationSourceBytes result==bytes1&&migrationSourceHash result==sha256 bytes1&&migrationWorld result==new&&migrationSourceSchema(migrationReport result)==1)
  let SimTick saved=simTick world
      originalNext=legacyNextId(v1Meta old1)
      newLots=M.elems(v2Lots v2)
  assert(label++" deterministic consecutive fresh lot IDs")(map lotId newLots==take(length newLots)(map EntityId[originalNext..]))
  assert(label++" saved tick grace and expiry catalog")(all(\lot->lotBorn lot==SimTick saved&&lotExpires lot==fmap(\life->SimTick(saved+fromInteger life))(resourceShelfLife(contentResources(worldContent world)M.!lotResource lot)))newLots)
  -- Independent native V2 and native V3 fixture imports also continue; V1
  -- refreshes freshness, so future V1/V2 hashes are deliberately not equated.
  native2<-must(legacyV2Fixture world >>= encodeLegacyV2)
  imported2<-must(migrateLegacyBytes 3 native2)
  bytes3<-must(encodeCheckpoint defaultCheckpointMeta world)
  (_,native3)<-must(decodeCheckpoint bytes3)
  let base="evidence/migration-fixtures/"++label
  BS.writeFile(base++"-v1.cbor")bytes1
  BS.writeFile(base++"-v2.cbor")native2
  BS.writeFile(base++"-v3.cbor")bytes3
  forM_[("sequential-v1-v2-v3",new),("native-v2-v3",migrationWorld imported2),("native-v3",native3)]$ \(route,start)->do
    end<-suffix 10000 start
    let SimTick startTick=simTick start
    assert(label++" "++route++" actual 10000-tick suffix")(simTick end==SimTick(startTick+10000)&&worldMode end==Active)
    _<-must(canonicalStateHash end)
    pure()
  putStrLn("Migration fixture "++label++": V1/V2/V3 canonical decode, preserved state, 3 x 10000 actual pureStep ticks PASS")

invalidLegacyTests :: Content -> World -> IO ()
invalidLegacyTests _content world=do
  old<-must(legacyV1Fixture world)
  let corrupt label value=do
        bytes<-must(encodeLegacyEnvelope 1 value)
        assert(label++" decode rejects without source mutation")(rejects(decodeLegacyV1 bytes)&&rejects(migrateLegacyBytes 2 bytes))
        assert(label++" original still valid")(not(rejects(encodeLegacyV1 old)))
  corrupt "negative stock" old{v1Stock=M.map(negate.abs)(v1Stock old)}
  corrupt "zero allocator" old{v1Meta=(v1Meta old){legacyNextId=0}}
  let highResident=maximum(M.keys(needsResidents(legacyNeeds(v1Core old))))
      EntityId high=highResident
  corrupt "allocator below resident/grid/device high water" old{v1Meta=(v1Meta old){legacyNextId=high}}
  corrupt "unknown prototype" old{v1Core=(v1Core old){legacyJobs=M.map(\job->job{jobRecipe="retired-without-alias"})(legacyJobs(v1Core old))}}
  future<-must(encodeLegacyEnvelope 99 old)
  assert "future schema rejected"(rejects(migrateLegacyBytes 2 future))
  validBytes<-must(encodeLegacyV1 old)
  assert "truncated old save rejected"(rejects(migrateLegacyBytes 2(BS.init validBytes)))
  assert "same branch cannot be migration destination"(rejects(migrateLegacyBytes 1 validBytes))
  let tickOverflow=old{v1Core=(v1Core old){legacyTick=SimTick maxBound}}
  corrupt "expiry counter overflow" tickOverflow
  putStrLn "Migration negative inputs: quantity, ID counters, unknown prototype, future schema, truncation, same branch and grace overflow reject PASS"

reservationTests :: Content -> World -> IO ()
reservationTests _content carrying=do
  old<-must(legacyV1Fixture carrying)
  let claims=v1Reservations old
      shipped=head[r|r<-M.elems claims,legacyShipped r]
      source=maybe(error "source")id(legacySource shipped)
      shipment=v1Transport old `oldShipmentAt` legacyReservationJob shipped
      vehicle=Owner Vehicle(oldShipmentVehicle shipment)
      stockAt owner=sum[n|((o,r),n)<-M.toList(v1Stock old),o==owner,r==Ration]
  assert "carried food is absent from source and physically in vehicle"(stockAt source==0&&stockAt vehicle==20000)
  bytes<-must(encodeLegacyV1 old)
  result<-must(migrateLegacyBytes 2 bytes)
  let inv=worldInventory(migrationWorld result)
      physical owner=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots inv),lotOwner lot==owner,lotResource lot==Ration]
      sourceClaims=[claim|claim<-M.elems(invQuantity inv),Just lot<-[M.lookup(quantityLot claim)(invLots inv)],lotOwner lot==source]
  assert "no recreated source stock or source reservation after shipping"(physical source==0&&physical vehicle==20000&&null sourceClaims)
  let over=old{v1Reservations=M.adjust(\r->r{legacyQuantity=legacyQuantity r+1})(legacyReservationId shipped)claims}
      negative=old{v1Reservations=M.adjust(\r->r{legacyQuantity= -1})(legacyReservationId shipped)claims}
      cap=head[r|r<-M.elems claims,legacyCapacity r>0]
      capacityMismatch=old{v1Reservations=M.insert(legacyReservationId shipped)(shipped{legacyDestination=legacyDestination cap,legacyCapacity=legacyCapacity cap+1})(M.delete(legacyReservationId cap)claims)}
      capOver=old{v1Reservations=M.adjust(\r->r{legacyCapacity=quantityMax})(legacyReservationId cap)claims}
  forM_[("overreservation",over),("negative reservation",negative),("contradictory combined quantity/capacity",capacityMismatch),("capacity overreservation",capOver)]$ \(label,value)->do
    invalid<-must(encodeLegacyEnvelope 1 value)
    assert label(rejects(decodeLegacyV1 invalid))
  -- An actual combined historical shipped reservation, converted to two
  -- current claims, proves this is not just re-encoding independent claims.
  let combined=old{v1Reservations=M.insert(legacyReservationId shipped)(shipped{legacyDestination=legacyDestination cap,legacyCapacity=legacyCapacity cap})(M.delete(legacyReservationId cap)claims)}
  accepted<-must(encodeLegacyV1 combined >>= migrateLegacyBytes 2)
  assert "combined shipped reservation splits, without source duplication"(quantityFor(legacyReservationJob shipped)(worldInventory(migrationWorld accepted))==20000)
  putStrLn "Migration reservations: actual carried food, no source duplication, combined source/capacity split and contradictory reservations rejected PASS"
  where oldShipmentAt t ident=oldShipments t M.!ident

allocationOrderTests :: World -> IO ()
allocationOrderTests reserved=do
  old<-must(legacyV2Fixture reserved)
  let original=head[r|r<-M.elems(v2Reservations old),legacyQuantity r>0]
      stock=head[lot|lot<-M.elems(v2Lots old),lotResource lot==Ration]
      next=legacyNextId(v2Meta old)
      extraClaimId=EntityId next
      extraLotId=EntityId(next+1)
      first=original{legacyQuantity=12000}
      second=original{legacyReservationId=extraClaimId,legacyQuantity=8000}
  six<-must(mkQty 6000);fourteen<-must(mkQty 14000)
  let modified=old{v2Meta=(v2Meta old){legacyNextId=next+2}
        ,v2Lots=M.insert extraLotId(stock{lotId=extraLotId,lotQty=fourteen})(M.insert(lotId stock)(stock{lotQty=six})(v2Lots old))
        ,v2Reservations=M.insert extraClaimId second(M.insert(legacyReservationId first)first(v2Reservations old))}
  encoded<-must(encodeLegacyV2 modified)
  result<-must(migrateLegacyBytes 2 encoded)
  let inventory=worldInventory(migrationWorld result)
      claims=M.elems(invQuantity inventory)
      allocation ident=[(quantityLot r,qtyValue(quantityAmount r))|r<-claims,quantityReservationId r==ident]
  assert "reservation-ID ascending allocation consumes first lot before second"
    (allocation(legacyReservationId first)==[(lotId stock,6000)]&&allocation extraClaimId==[(extraLotId,8000)]
      &&allocation(EntityId(next+2))==[(extraLotId,6000)])
  assert "split allocator exceeds globally allocated objects"(invNextId inventory==next+3)
  must(validateGlobalIds(migrationWorld result))
  _<-suffix 10000(migrationWorld result)
  putStrLn "Migration allocation: reservationId order, multi-lot split, original-ID retention, fresh-ID high water and 10000 actual transport ticks PASS"


maintenanceSnapshots :: Content -> IO [(String,World)]
maintenanceSnapshots content=do
  (sid,base)<-kitchenFixture content False
  let site=worldSites base M.!sid
      source=siteInput site
      tx=TxId 1 1(BoundarySeq 0)P0 1
  (_,inventory)<-must(runInventory(void(mintLot tx InitialGrant Nothing Parts 10 source(SimTick 100)Nothing "maintenance-parts"))(worldInventory base))
  facility<-must(newFacility content sid "kitchen")
  let initial=base{worldInventory=inventory,worldMaintenance=emptyMaintenance{maintenanceFacilities=M.singleton sid facility},worldMaintenanceCrews=M.singleton sid 1}
  planned<-step False[RequestMaintenance sid source source]initial
  running<-step True[]planned >>= suffix 37
  let job=head(M.elems(maintenanceJobs(worldMaintenance running)))
  completed<-suffix 600 running
  cancelled<-step False[CancelFacilityMaintenance(maintenanceJobId job)]running
  assert "actual kernel-generated maintenance phases"
    (map(maintenancePhase.head.M.elems.maintenanceJobs.worldMaintenance)[planned,running,completed,cancelled]==[MaintenancePlanned,MaintenanceRunning,MaintenanceCompleted,MaintenanceCancelled])
  pure[("maintenance-planned",planned),("maintenance-running",running),("maintenance-completed",completed),("maintenance-cancelled",cancelled)]

balanceUpdateTests :: Content -> World -> World -> IO ()
balanceUpdateTests content planned running=do
  let oldCook=contentRecipes content M.!"cook"
      newCook=oldCook{recipeInputs=M.insert Fuel 800(recipeInputs oldCook),recipeOutputs=M.insert Ration 19000(recipeOutputs oldCook)}
      proposed=content{contentRecipes=M.insert "cook" newCook(contentRecipes content)}
      importOld world=must(legacyV1Fixture world >>= encodeLegacyV1 >>= migrateLegacyBytes 2)
  importedRunning<-importOld running
  let oldWorld=migrationWorld importedRunning
  patchedRunning<-must(applyCookBalanceV2 3 proposed oldWorld)
  oldDigest<-must(contentHash content)
  newDigest<-must(contentHash proposed)
  assert "migration/balance preserves start-time snapshot and content ID"
    (worldJobs oldWorld==worldJobs patchedRunning&&all((==Just oldDigest).jobSnapshotContentId)(M.elems(worldJobs patchedRunning))
      &&assetTotals(worldInventory oldWorld)==assetTotals(worldInventory patchedRunning)&&worldRuleset patchedRunning=="red-dune-reference-1"&&branchId patchedRunning==3)
  oldCompleted<-suffix 10000 patchedRunning
  let oldLedger=invLedger(worldInventory oldCompleted)
  assert "migrated old WIP cannot multiply new balance output"
    (M.lookup(Fuel,RecipeInput)oldLedger==Just 1000&&M.lookup(Ration,RecipeOutput)oldLedger==Just 18000)
  importedPlanned<-importOld planned
  patchedPlanned<-must(applyCookBalanceV2 3 proposed(migrationWorld importedPlanned))
  newCompleted<-suffix 10000 patchedPlanned
  let newLedger=invLedger(worldInventory newCompleted)
  assert "migrated not-yet-started job gets only new balance and content ID"
    (M.lookup(Fuel,RecipeInput)newLedger==Just 800&&M.lookup(Ration,RecipeOutput)newLedger==Just 19000
      &&all((==Just newDigest).jobSnapshotContentId)(M.elems(worldJobs newCompleted)))
  forM_[proposed{contentStatus="unrequested metadata change"},proposed{contentRecipes=M.insert "cook" (newCook{recipeWorkTicks=recipeWorkTicks newCook+1})(contentRecipes proposed)},content]$ \invalid->
    assert "balance catalog allows exactly two requested quantity changes"(rejects(applyCookBalanceV2 3 invalid oldWorld))
  assert "balance update cannot reuse original branch"(rejects(applyCookBalanceV2 2 proposed oldWorld))
  assert "balance update cannot be applied twice"(rejects(applyCookBalanceV2 4 proposed patchedRunning))
  bytes<-must(encodeCheckpoint defaultCheckpointMeta patchedRunning)
  (_,loaded)<-must(decodeCheckpoint bytes)
  assert "new ruleset checkpoint roundtrip retains old content snapshot"(loaded==patchedRunning)
  BS.writeFile "evidence/migration-fixtures/cook-balance-v2-running-v3.cbor" bytes
  putStrLn "Migration balance exercise: distinct ruleset/branch, exact two-diff gate, immutable old snapshot/content-ID, old 1000/18000 vs new 800/19000 and 20000 actual ticks PASS"


migrationTests :: Content -> IO ()
migrationTests content=do
  createDirectoryIfMissing True "evidence/migration-fixtures"
  jobs<-jobSnapshots content
  transports<-transportSnapshots content
  maintenance<-maintenanceSnapshots content
  invalidLegacyTests content(snd(head jobs))
  reservationTests content(snd(transports!!1))
  allocationOrderTests(snd(head transports))
  balanceUpdateTests content(snd(head jobs))(snd(jobs!!2))
  let fixtures=jobs++transports++maintenance
  mapM_ fixtureContinuation fixtures
  putStrLn("MigrationTests PASS: "++show(length fixtures*3+1)++" legacy/current fixture files; "++show(length fixtures*30000+30000)++" actual pureStep suffix ticks; honest pending gates recorded in evidence/migration-scope.md")
