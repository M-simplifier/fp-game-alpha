module ReturnPlacementTests(returnPlacementTests) where

import Colony.Arena
import Colony.Codec
import Colony.Content
import Colony.ContentCodec
import Colony.Inventory
import Colony.Jobs
import Colony.JSON
import Colony.Migrate(applyCookBalanceV2,applyReturnPlacementCorrection)
import Colony.Presentation(productionCancellation,obj,str,num,arr)
import Colony.Ruleset
import Colony.Scheduler
import Colony.Types
import Colony.Units
import Colony.World
import Control.Monad(forM_,unless,foldM)
import Data.Either(isLeft)
import Data.List(sortOn)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Game.Arena(play,singleton)

check :: String -> Bool -> IO()
check label condition=unless condition(fail("Return placement: "++label))
right :: Show e => Either e a -> IO a
right=either(fail.show)pure
transaction :: TxId
transaction=TxId 1 1(BoundarySeq 0)P1 0
oldProfile,newProfile :: String
oldProfile="red-dune-reference-2"
newProfile="red-dune-reference-4"

-- Independent bounded reference: enumerate integer allocations, largest first
-- at each destination, and backtrack only if the remaining resources cannot be
-- placed. This deliberately does not use the production feasibility formula,
-- binary search, Inventory freeWeight, transfer logic or FEFO helper.
reference :: [(Resource,Integer)] -> [(Owner,Maybe Resource,Integer)] -> Maybe [(Resource,Owner,Integer)]
reference [] _=Just []
reference ((resource,quantity):resources) stores=place quantity stores []
  where
    load=if resource==Parts then 250 else 1
    place remaining [] reversed
      | remaining/=0=Nothing
      | otherwise=do
          let assignments=reverse reversed
              updated=[(owner,kind,capacity-n*load)|(owner,kind,capacity,n)<-assignments]
          suffix<-reference resources updated
          pure([(resource,owner,n)|(owner,_,_,n)<-assignments,n>0]++suffix)
    place remaining ((owner,kind,capacity):rest) reversed=first
      [place(remaining-n)rest((owner,kind,capacity,n):reversed)|n<-[maximumHere,maximumHere-1..0]]
      where maximumHere=if maybe True(==resource)kind then min remaining(capacity `div` load)else 0
    first []=Nothing
    first(Nothing:rest)=first rest
    first(Just result:_)=Just result

modelInventory :: Content -> [(Maybe Resource,Integer)] -> (Inventory,[(Owner,Maybe Resource,Integer)])
modelInventory content stores=(inventory,owners)
  where
    owners=[(Owner Warehouse(EntityId ident),kind,capacity)|(ident,(kind,capacity))<-zip[2..]stores]
    inventory=(emptyInventory content){invNextId=fromIntegral(length stores)+2,invStorage=M.fromList[(owner,Storage capacity kind(EntityId 1))|(owner,kind,capacity)<-owners]}

checkModel :: Content -> [(Resource,Integer)] -> [(Maybe Resource,Integer)] -> IO()
checkModel content quantities stores=do
  let (inventory,owners)=modelInventory content stores
      expected=reference(sortOn fst quantities)owners
      actual=planReturnPlacement inventory[owner|(owner,_,_)<-owners](M.fromList quantities)
      label="model disagreement: demand="++show quantities++" stores="++show stores++" reference="++show expected++" actual="++show actual
  check label(case expected of Nothing->actual==Left ReturnCapacityFull;Just plan->actual==Right plan)

boundedModel :: Content -> IO()
boundedModel content=do
  let kinds=[Nothing,Just Water,Just Crops,Just Parts]
      capacities=[0,1,2,249,250,251,499,500,501]
      stores=[(kind,capacity)|kind<-kinds,capacity<-capacities]
      demands=[[(Water,water),(Crops,crops),(Parts,partCount)]|water<-[0..2],crops<-[0..2],partCount<-[0..2]]
  forM_ demands$ \demand->forM_ stores$ \a->forM_ stores$ \b->checkModel content demand[a,b]
  let triples=[(kind,capacity)|kind<-kinds,capacity<-[0,1,249,250,251,501]]
      tripleDemand=[(Water,2),(Crops,2),(Parts,2)]
  forM_ triples$ \a->forM_ triples$ \b->forM_ triples$ \c->checkModel content tripleDemand[a,b,c]
  -- Mixed inputs with resource-order changes, and a genuine aggregate-weight
  -- false positive: two Parts cannot occupy free249+251 even though weight=500.
  forM_[ ([(Metal,1),(Parts,1)],[(Nothing,250),(Nothing,1)])
        , ([(Parts,2)],[(Nothing,249),(Nothing,251)])
        , ([(Water,1),(Crops,1)],[(Nothing,1),(Just Water,1)])]$ \(demand,layout)->do
    checkModel content demand layout
    let (inventory,owners)=modelInventory content layout
    putStrLn("Allocator counterexample demand="++show demand++" stores="++show layout++" actual="++show(planReturnPlacement inventory[owner|(owner,_,_)<-owners](M.fromList demand)))
  let largeLayout=replicate 4095(Nothing,1)++[(Nothing,2000)]
      (largeInventory,largeOwners)=modelInventory content largeLayout
  largePlan<-right(planReturnPlacement largeInventory[owner|(owner,_,_)<-largeOwners](M.fromList[(Metal,4095),(Parts,8)]))
  check "4096 owners use bounded cache/search, with integral heavy units"(largePlan==[(Metal,owner,1)|(owner,_,_)<-take 4095 largeOwners]++[(Parts,let(owner,_,_)=last largeOwners in owner,8)])
  let (orderedInventory,orderedOwners)=modelInventory content[(Nothing,1),(Nothing,1)]
      ownerOrder=reverse[owner|(owner,_,_)<-orderedOwners]
  check "explicit owner priority and duplicate candidate stability"(planReturnPlacement orderedInventory(ownerOrder++ownerOrder)(M.singleton Water 1)==Right[(Water,head ownerOrder,1)])
  check "undeclared heterogeneous heavy loads are explicit, never capacity fiction"(case planReturnPlacement largeInventory[owner|(owner,_,_)<-largeOwners](M.fromList[(Parts,1),(Circuit,1)])of Left(InvariantViolation _)->True;_->False)
  putStrLn "Return allocator model PASS: 34,992 exhaustive two-owner states (three demands 0..2; owner types any/Water/Crops/Parts; free weights 0,1,2,249,250,251,499,500,501) + 13,824 three-owner states + 3 counterexamples; exact first feasible plan equals independent exhaustive allocation"

fixture :: Content -> String -> (Integer->[Integer]) -> Integer -> [(Maybe Resource,Integer)] -> IO(World,Job)
fixture content recipeId' partition outputCapacity stores=do
  recipe<-right(lookupRecipe content recipeId')
  ((site,job),inventory)<-right$runInventory(do
    colony<-freshId;sid<-freshId
    let source=Owner MachineInput sid;destination=Owner MachineOutput sid
    addStorage source(Storage 400000 Nothing colony)
    addStorage destination(Storage outputCapacity Nothing colony)
    forM_ stores$ \(kind,capacity)->do
      ident<-freshId
      addStorage(Owner Warehouse ident)(Storage capacity kind colony)
    forM_(M.toAscList(recipeInputs recipe))$ \(resource,quantity)->forM_(zip[0..](partition quantity))$ \(ordinal,n)->do
      _<-mintLot transaction InitialGrant Nothing resource n source(SimTick 0)Nothing("origin:"++show resource++":"++show(ordinal::Integer))
      pure()
    planned<-planJob content recipeId' source destination M.empty
    started<-startJob content(SimTick 0)planned
    pure(Site sid recipeId' source destination M.empty 0 False,started))(emptyInventory content)
  digest<-right(contentIdentity content)
  let profile=if digest==knownV2ContentId then "red-dune-reference-5" else newProfile
      world=(initialWorld content){worldMode=Paused,worldRuleset=profile,worldInventory=inventory,worldSites=M.singleton(siteId site)site,worldJobs=M.singleton(jobId job)job,worldJobSites=M.singleton(jobId job)(siteId site)}
  right(validateWorld world)
  pure(world,job)

setJob :: Job -> World -> World
setJob job world=world{worldJobs=M.insert(jobId job)job(worldJobs world)}
physical :: Resource -> Inventory -> Integer
physical resource inventory=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots inventory),lotResource lot==resource]
loss :: Resource -> Inventory -> Integer
loss resource inventory=M.findWithDefault 0(resource,CancelledProcessLoss)(invLedger inventory)

parts :: Integer -> Integer -> [Integer]
parts count quantity=filter(>0)[quantity `div` count+if n<quantity `mod` count then 1 else 0|n<-[0..count-1]]

counterexample :: Content -> IO(World,Job)
counterexample content=do
  (single,singleJob)<-fixture content "cook"(:[])21000[(Nothing,3000)]
  (eight,eightJob)<-fixture content "cook"(\q->if q==20000 then parts 8 q else[q])21000[(Nothing,3000)]
  let quarter job=job{jobProgress=jobRequired job `div` 4}
      result profile world job=runInventory(cancelJob profile transaction(quarter job))(worldInventory world)
  check "original single crop counterexample is pinned"(result oldProfile single singleJob==Left ReturnCapacityFull)
  (newSingle,oneInventory)<-right(result newProfile single singleJob)
  (oldEight,eightInventory)<-right(result oldProfile eight eightJob)
  check "previously accepted eight-lot result is exact, including IDs and ledger order"(result newProfile eight eightJob==Right(oldEight,eightInventory))
  forM_[(Water,7500,2500),(Crops,15000,5000),(Fuel,750,250)]$ \(resource,remaining,lost)->do
    check "single/eight survivors and loss agree"(physical resource oneInventory==remaining&&physical resource eightInventory==remaining&&loss resource oneInventory==lost&&loss resource eightInventory==lost)
  check "new single-lot result splits an original provenance across owners"(length[lot|lot<-M.elems(invLots oneInventory),lotResource lot==Crops]==2)
  check "terminal cancel repeats refuse"(runInventory(cancelJob newProfile transaction newSingle)oneInventory==Left AlreadyTerminal)
  putStrLn "Production counterexample PASS: profile2 singleCrops20000 refuses; eight2500 succeeds. Profile4 both succeed, returning Water7500+Crops15000+Fuel750 in output21000+warehouse3000; accepted eight-lot transaction remains exactly equal"
  pure(setJob(quarter singleJob)single,quarter singleJob)

-- Compare every finite shipped input combination at useful progress boundaries
-- under six lot partitions. Capacity profiles include split generic stores and
-- a typed warehouse. Old successful transactions must remain exactly equal.
catalogPartitions :: Content -> IO()
catalogPartitions content=do
  forM_[recipe|recipe<-M.elems(contentRecipes content),not(M.null(recipeInputs recipe))]$ \recipe->do
    let outputWeight=sum[n*resourceLoad(contentResources content M.!resource)|(resource,n)<-M.toList(recipeOutputs recipe)]
        partitioners=[(:[]),parts 2,parts 3,parts 8,\n->if n>1 then[1,n-1]else[n],\n->if n>2 then[n-2,1,1]else[n]]
    forM_[[],[(Nothing,1000),(Nothing,3000)],[(Just Metal,10000),(Just Water,4000),(Nothing,5000)]]$ \stores->do
      fixtures<-mapM(\partition->fixture content(recipeId recipe)partition outputWeight stores)partitioners
      let required=jobRequired(snd(head fixtures))
      forM_[0,1,required `div` 4,required `div` 2,required-1,required]$ \credit->do
        outcomes<-mapM(\(world,job)->do
          let current=job{jobProgress=credit}
              old=runInventory(cancelJob oldProfile transaction current)(worldInventory world)
              new=runInventory(cancelJob newProfile transaction current)(worldInventory world)
          case old of Right accepted->check "old accepted inventory, metadata, IDs and loss order retained"(new==Right accepted);Left _->pure()
          case new of
            Left failure->do
              check "valid shipped input fails only with genuine capacity refusal"(failure==ReturnCapacityFull)
              pure Nothing
            Right(ended,inventory)->do
              forM_(M.toList(recipeInputs recipe))$ \(resource,n)->check "resource-floor and conservation in all shipped recipes"(loss resource inventory==n*credit `div` required&&physical resource inventory+loss resource inventory==n)
              check "terminal no reservations"(jobPhase ended==Cancelled&&null(invCapacity inventory)&&null(invQuantity inventory)&&null(invNatural inventory))
              pure(Just[(resource,physical resource inventory,loss resource inventory)|resource<-allResources]))fixtures
        check("lot-partition outcome invariant for "++recipeId recipe++" credit="++show credit++" stores="++show stores)(all(==head outcomes)(tail outcomes))
  putStrLn "Shipped-catalog metamorphic PASS: all 12 non-extraction input recipes x 3 capacity/type layouts x 6 progress values x 6 partitions; feasibility, resource totals, terminal state and legacy-success identity"

metadataAndReservations :: Content -> IO()
metadataAndReservations content=do
  (raw,job)<-fixture content "cook"(\q->if q==20000 then replicate 5 4000 else[q])21000[(Nothing,4000)]
  let inventory=worldInventory raw
      crops=[lot|lot<-M.elems(invLots inventory),lotResource lot==Crops]
      metadata=[(Just(SimTick 300),SimTick 1),(Just(SimTick 200),SimTick 2),(Just(SimTick 200),SimTick 1),(Nothing,SimTick 0),(Just(SimTick 200),SimTick 1)]
      changed=[lot{lotExpires=expiry,lotBorn=born}|(lot,(expiry,born))<-zip crops metadata]
      varied=inventory{invLots=foldr(\lot->M.insert(lotId lot)lot)(invLots inventory)changed}
      current=job{jobProgress=jobRequired job `div` 4}
      warehouse=head[owner|owner@(Owner Warehouse _)<-M.keys(invStorage inventory)]
  ((other,claim),reserved)<-right$runInventory(do
    other<-planJob content "cook"(jobInput job)(jobOutput job)M.empty
    reserveCapacity(jobId other)warehouse Water 750
    claim<-pure [c|c<-M.elems(invCapacity varied),capacityJob c/=jobId job]
    pure(other,claim))varied
  check "original no-other-claims fixture"(null claim)
  let world=(setJob current raw){worldInventory=reserved,worldJobs=M.fromList[(jobId current,current),(jobId other,other)]}
      ownClaim=M.filter((/=jobId job).capacityJob)(invCapacity reserved)
  right(validateWorld world)
  check "metadata case actually exercises fallback"(runInventory(cancelJob oldProfile transaction current)reserved==Left ReturnCapacityFull)
  (_,result)<-right(runInventory(cancelJob newProfile transaction current)reserved)
  let order lot=(maybe(1::Integer,0)(\(SimTick tick)->(0,toInteger tick))(lotExpires lot),lotBorn lot,lotId lot)
      consume _ []=[]
      consume remaining(lot:rest)=let n=min remaining(qtyValue(lotQty lot));back=qtyValue(lotQty lot)-n in[(lot,back)|back>0]++consume(remaining-n)rest
      expected=M.fromListWith(+)[((lotResource lot,lotBorn lot,lotExpires lot,lotProvenance lot),quantity)|(resource,group)<-M.toList(M.fromListWith(++)[(lotResource lot,[lot])|lot<-M.elems(invLots reserved),lotOwner lot==wipOwner job]),(lot,quantity)<-consume(sum(map(qtyValue.lotQty)group)*jobProgress current `div` jobRequired current)(sortOn order group),resource==lotResource lot]
      actual=M.fromListWith(+)[((lotResource lot,lotBorn lot,lotExpires lot,lotProvenance lot),qtyValue(lotQty lot))|lot<-M.elems(invLots result)]
  check "expiry, born, provenance and FEFO loss exact across physical splits"(actual==expected)
  let takePhysical _ []=[]
      takePhysical remaining((lot,quantity):rest)=let n=min remaining quantity in[(lotProvenance lot,n)|n>0]++takePhysical(remaining-n)rest
      expectedOutput=M.fromList(takePhysical 13500(consume 5000(sortOn order changed)))
      actualOutput=M.fromListWith(+)[(lotProvenance lot,qtyValue(lotQty lot))|lot<-M.elems(invLots result),lotResource lot==Crops,lotOwner lot==jobOutput job]
  check "survivor destination assignment follows expiry/born/ID order"(actualOutput==expectedOutput)
  check "non-owned reservations preserved exactly"(invCapacity result==ownClaim&&reservedWeight result warehouse==750)
  check "other job unchanged and no reserved capacity overrun"(all(>=0)[freeWeight result owner|owner<-M.keys(invStorage result)])
  -- Reduce usable warehouse space to one gram below the return requirement.
  let blocked=reserved{invStorage=M.adjust(\storage->storage{storageCapacity=2999})warehouse(invStorage reserved)}
      before=world{worldInventory=blocked}
      (after,out)=pureStep(cancelBoundary before current)before
  right(validateWorld before)
  check "genuine failure rolls back loss, IDs, movements and both jobs' reservations"(worldInventory after==blocked&&worldJobs after==worldJobs before&&null(outputEvents out)&&null(outputDiagnostics out)&&map receiptOutcome(outputReceipts out)==[CommandFailed ReturnCapacityFull])
  let preview=M.fromList(productionCancellation before current)
  check "failed UI preview matches atomic command"(M.lookup "cancelAllowed" preview==Just(JBool False))
  -- A remote warehouse is not an eligible escape hatch for a local failure.
  (_,remoteInventory)<-right$runInventory(do
    remoteColony<-freshId;remoteId<-freshId
    addStorage(Owner Warehouse remoteId)(Storage 2000000 Nothing remoteColony))blocked
  check "cross-colony free capacity cannot authorize cancellation"(runInventory(cancelJob newProfile transaction current)remoteInventory==Left ReturnCapacityFull)
  -- Physical occupancy and a foreign quantity claim consume real capacity; the
  -- claim itself is neither released nor moved by this production cancellation.
  (_,occupied)<-right$runInventory(do
    _<-mintLot transaction InitialGrant Nothing Water 1000 warehouse(SimTick 0)Nothing "foreign-stock"
    reserveQuantity(SimTick 0)(jobId other)warehouse Water 1000)reserved
  (_,occupiedResult)<-right(runInventory(cancelJob newProfile transaction current)occupied)
  check "held stock plus both kinds of foreign claim survive exactly"(invQuantity occupiedResult==invQuantity occupied&&invCapacity occupiedResult==ownClaim&&[lot|lot<-M.elems(invLots occupiedResult),lotProvenance lot=="foreign-stock"]==[lot|lot<-M.elems(invLots occupied),lotProvenance lot=="foreign-stock"])
  putStrLn "Metadata/reservation PASS: finite/no-expiry, born/ID ties, provenance, FEFO, foreign capacity claim750, split physical movement and atomic failure at23249 available weight"

cancelBoundary :: World -> Job -> NativeInput
cancelBoundary world job=Boundary(BoundaryHeader(worldId world)(branchId world)(boundarySeq world)False(worldAuthority world)(worldRuleset world))
  [OrderedCommand 0(CommandId(worldId world)1(participantEpoch(worldParticipants world M.!1))1)(CancelProduction(jobId job))][]

profilesAndNative :: Content -> World -> Job -> IO()
profilesAndNative content newWorld job=do
  let original=newWorld{worldRuleset=oldProfile}
  source<-right(encodeCheckpoint defaultCheckpointMeta original)
  migrated<-right(applyReturnPlacementCorrection 2 original)
  check "pure correction preserves all other World fields"(migrated{branchId=branchId original,worldRuleset=oldProfile}==original)
  check "distinct nonzero branch, one-time ordered correction"(isLeft(applyReturnPlacementCorrection 0 original)&&isLeft(applyReturnPlacementCorrection(branchId original)original)&&isLeft(applyReturnPlacementCorrection 3 migrated)&&isLeft(applyReturnPlacementCorrection 3 original{worldRuleset="red-dune-reference-0"})&&isLeft(applyReturnPlacementCorrection 3 original{worldRuleset="unknown"}))
  let cook=contentRecipes content M.!"cook"
      v2=content{contentRecipes=M.insert "cook" cook{recipeInputs=M.insert Fuel 800(recipeInputs cook),recipeOutputs=M.insert Ration 19000(recipeOutputs cook)}(contentRecipes content)}
  oldV2<-right(applyCookBalanceV2 3 v2 original)
  correctedV2<-right(applyReturnPlacementCorrection 4 oldV2)
  correctionThenBalance<-right(applyCookBalanceV2 4 v2 migrated)
  check "balance4to5 and return3to5 commute preserving old recipe snapshot"(correctedV2==correctionThenBalance&&worldRuleset correctedV2=="red-dune-reference-5"&&jobSnapshotContentId(worldJobs correctedV2 M.!jobId job)==Just knownV1ContentId)
  check "profiles4/5 remain bound to exact catalog"(isLeft(encodeCheckpoint defaultCheckpointMeta migrated{worldContent=v2})&&isLeft(encodeCheckpoint defaultCheckpointMeta correctedV2{worldContent=content}))
  check "all six legacy profiles registered; legacy initialization still selects4"(filter(not . isM1Ruleset)allRulesets==map("red-dune-reference-"++ )["0","1","2","3","4","5"]&&currentV1Ruleset==newProfile)
  (freshV2,freshJob)<-fixture v2 "cook"(:[])22000[(Nothing,2000)]
  let freshCurrent=freshJob{jobProgress=jobRequired freshJob `div` 4}
  check "new v2 batch binds the new catalog"(jobSnapshotContentId freshCurrent==Just knownV2ContentId)
  forM_[(migrated,job),(correctedV2,job),(setJob freshCurrent freshV2,freshCurrent)]$ \(world,active)->do
    bytes<-right(encodeCheckpoint defaultCheckpointMeta world)
    (_,saved)<-right(decodeCheckpoint bytes)
    let input@(Boundary header commands management)=cancelBoundary saved active
        (after,out)=pureStep input saved
    check "native cancellation uses split placement"(null(outputDiagnostics out)&&map receiptOutcome(outputReceipts out)==[Applied(Just(jobId active))]&&jobPhase(worldJobs after M.!jobId active)==Cancelled)
    (arena,arenaOut)<-right(play Colony(RecordedBoundary header(map commandId commands)management)(singleton 1(OrderedBatch commands))saved)
    check "Arena performs same real native command"(arena==after&&arenaOut==out)
    let preview=M.fromList(productionCancellation saved active)
        entries values=arr[obj[("resource",str(resourceKey resource)),("quantity",num quantity)]|(resource,quantity)<-values,quantity>0]
        expectedLoss=entries[(resource,loss resource(worldInventory after))|resource<-allResources]
        expectedReturn=entries[(resource,physical resource(worldInventory after))|resource<-allResources]
    check "UI cost preview equals actual split transaction"(M.lookup "cancelAllowed" preview==Just(JBool True)&&M.lookup "cancelLoss" preview==Just expectedLoss&&M.lookup "cancelReturn" preview==Just expectedReturn)
    hash<-right(canonicalStateHash after)
    catalog<-right(contentHash(worldContent saved))
    let replay=Replay(ReplayHeader(worldId saved)(branchId saved)(sha256 bytes)(worldRuleset saved)catalog "RDF-RNG-1" 1 "return-placement-fixture" 1)[ReplayFrame input out hash]
    wire<-right(encodeReplay replay)
    parsed<-right(decodeReplay wire)
    final<-foldM(\start frame->do
      let(end,result)=pureStep(replayInput frame)start
      digest<-right(canonicalStateHash end)
      check "canonical replay receipts/events/hash exact"(result==replayOutput frame&&digest==replayStateHash frame)
      pure end)saved(replayFrames parsed)
    check "full native replay equality"(final==after)
    let(wrong,rejected)=pureStep(cancelBoundary original job)saved
    check "old-profile replay cannot enter migrated branch"(wrong==saved&&not(null(outputDiagnostics rejected))&&null(outputReceipts rejected))
  check "original checkpoint unchanged"(encodeCheckpoint defaultCheckpointMeta original==Right source)
  putStrLn "Profiles/migration PASS: explicit2to4/3to5, cook4to5, commuting migrations, exact old snapshot/progress preservation, pinned catalogs, native/Arena/UI, checkpoint and replay"

frozenProfiles :: IO()
frozenProfiles=forM_[0..3::Integer]$ \profile->forM_[1,8::Integer]$ \pieces->do
  let prefix="evidence/return-placement/frozen-0.3/profile"++show profile++"-lots"++show pieces
  before<-BS.readFile(prefix++".before.cbor")
  input<-BS.readFile(prefix++".input.cbor")
  expected<-BS.readFile(prefix++".after.cbor")
  output<-readFile(prefix++".output.txt")
  (_,world)<-right(decodeCheckpoint before)
  command<-right(decodeNativeInput input)
  let(after,out)=pureStep command world
  actual<-right(encodeCheckpoint defaultCheckpointMeta after)
  check("frozen0.3 profile"++show profile++" transaction byte-compatible")(actual==expected&&show out++"\n"==output)

returnPlacementTests :: Content -> IO()
returnPlacementTests content=do
  frozenProfiles
  boundedModel content
  (world,job)<-counterexample content
  catalogPartitions content
  metadataAndReservations content
  profilesAndNative content world job
  putStrLn "ReturnPlacementTests PASS: finite model and metamorphic regression evidence, not a proof or complete M1 acceptance; GroundCache spatial planning remains unfinished"
