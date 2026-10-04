{-# LANGUAGE BangPatterns #-}
module SupplyChainTests (supplyChainTests) where

import Colony.Arena
import Colony.Codec
import Colony.Content
import Colony.Jobs
import Colony.Inventory (reservedWeight)
import Colony.Needs
import Colony.Power
import Colony.Scheduler
import Colony.SupplyChainFixture
import Colony.Topology
import Colony.Transport
import Colony.Types
import Colony.Units
import Colony.World
import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (foldM,unless)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import qualified Data.Set as S
import Game.Arena (observe,play,singleton)
import Numeric (showHex)
import System.IO (hFlush,stdout)

assert :: String -> Bool -> IO ()
assert label passed=unless passed(ioError(userError("Supply chain assertion: "++label)))
must :: Show e => String -> Either e a -> IO a
must label=either(ioError.userError.((label++": ")++).show)pure

physical :: World -> Owner -> Resource -> Integer
physical world owner resource=sum[qtyValue(lotQty lot)|lot<-M.elems(invLots(worldInventory world)),lotOwner lot==owner,lotResource lot==resource]

-- All descriptor identities and initial road coordinates are intentionally
-- frozen: callers do not regenerate a random map for each benchmark run.
frozenDescriptor :: SupplyChainDescriptor
frozenDescriptor=SupplyChainDescriptor "four-colony-road-v1"
  (map EntityId[1,15,29,43])(map(Owner Pantry . EntityId)[2,16,30,44])
  (map RoadNode[0,10,20,30])(EntityId 56)(EntityId 57)(EntityId 58)
  (EntityId 55)(EntityId 60)(EntityId 62)(map EntityId[63..66])(map RoadNode[0..30])

supplyChainTests :: Content -> IO ()
supplyChainTests content=do
  (descriptor,initial)<-must "construct frozen fixture"(fourColonySupplyChain content)
  assert "frozen descriptor and allocation IDs"(descriptor==frozenDescriptor)
  (_,duplicate)<-must "reconstruct deterministic fixture"(fourColonySupplyChain content)
  assert "same initial world every run"(initial==duplicate)
  let topology=transportTopology(worldTransport initial)
      destination=last(supplyPantries descriptor)
  assert "31 actual road nodes, 30 adjacent edges at cost20"
    (roadNodes topology==S.fromList(map RoadNode[0..30])&&M.keys(roadEdges topology)==[(RoadNode n,RoadNode(n+1))|n<-[0..29]]
      &&all(\edge->roadCost edge==20&&roadOpen edge)(M.elems(roadEdges topology)))
  assert "four colonies, ten actual residents each"
    (M.fromListWith(+)[(residentColony r,1::Integer)|r<-M.elems(needsResidents(worldNeeds initial))]==M.fromList[(cid,10)|cid<-supplyColonies descriptor])
  assert "four real carts and normal capacity"(M.size(transportVehicles(worldTransport initial))==4&&all((==CarrierCart).vehicleKind)(M.elems(transportVehicles(worldTransport initial))))
  assert "no prepared water/crops/rations in machine inputs or outputs"
    (all(\site->all(\resource->physical initial(siteInput site)resource==0&&physical initial(siteOutput site)resource==0)[Water,Crops,Ration])(M.elems(worldSites initial)))
  assert "fourth colony starts with zero water and ration"
    (physical initial destination Water==0&&physical initial destination Ration==0)
  initialHash<-must "initial canonical hash"(canonicalStateHash initial)
  putStrLn("SupplyChain initial SHA256="++hex initialHash++" descriptor="++show descriptor)
  (final,policy,checkpoint,frames,foodConsumed,waterConsumed,entries,completed)<-
    runTrace descriptor initial initialSupplyChainPolicy Nothing [] 0 0 0 []
  assert "all observation-policy stages issued"(supplyStage policy==SupplyOrdered&&supplyNextSequence policy==10)
  assert "four completed production jobs: two pump, grow, cook"
    (M.fromListWith(+)[(jobRecipe job,1::Integer)|job<-M.elems(worldJobs final),jobPhase job==Completed]==M.fromList[("hand_water",2),("grow",1),("cook",1)]&&M.size(worldJobs final)==4)
  let inventory=worldInventory final
      ledger resource reason=M.findWithDefault 0(resource,reason)(invLedger inventory)
      requests=M.elems(transportRequests(worldTransport final))
      shipments=M.elems(transportShipments(worldTransport final))
      farmWater=[request|request<-requests,requestDestination request==Owner MachineInput(supplyFarm descriptor)]
      energy=M.unionsWith(+)(map gridEnergyLedger(M.elems(worldPowerGrids final)))
  assert "five actual parent deliveries completed"(length requests==5&&all((==RequestCompleted).requestStatus)requests)
  assert "six physical child shipments, each <=50000 capacity"(length shipments==6&&all(\shipment->shipmentStatus shipment==ShipmentDelivered&&shipmentQuantity shipment<=50000)shipments)
  assert "60000 farm water split across two real trips"
    (case farmWater of [request]->length(requestChildren request)==2&&requestQuantity request==60000;_->False)
  assert "all children use source-colony cart"(all(\shipment->case(M.lookup(shipmentSource shipment)(invStorage inventory),M.lookup(shipmentVehicle shipment)(transportVehicles(worldTransport final)))of
    (Just store,Just vehicle)->storageColony store==vehicleColony vehicle;_->False)shipments)
  assert "no grants or externally minted stock after initial setup"
    (M.filterWithKey(\(_,reason) _->reason==InitialGrant)(invLedger inventory)==M.filterWithKey(\(_,reason) _->reason==InitialGrant)(invLedger(worldInventory initial)))
  assert "exact four production completion ticks"
    ([(tick,label)|(tick,label)<-reverse completed,label `elem` ["hand_water","grow","cook"]]==[(SimTick 1200,"hand_water"),(SimTick 2400,"hand_water"),(SimTick 9601,"grow"),(SimTick 11002,"cook")])
  assert "two complete extractions and recipe conservation totals"
    (ledger Water Extraction==120000&&ledger Water RecipeInput==70000&&ledger Crops RecipeOutput==60000
      &&ledger Crops RecipeInput==20000&&ledger Ration RecipeOutput==18000&&ledger Biomass RecipeOutput==10000&&ledger Waste RecipeOutput==3000)
  assert "real P6 generator powers all1200 cook ticks"
    (ledger Fuel RecipeInput==1000&&ledger Fuel FuelBurned==24000
      &&M.lookup FuelGenerated energy==Just 144000000&&M.lookup ConsumerServed energy==Just 14400000
      &&M.lookup Curtailment energy==Just 129600000)
  assert "newly cooked ration actually consumed in fourth colony"
    (foodConsumed>0&&foodConsumed+physical final destination Ration==18000
      &&all((=="recipe:cook").lotProvenance)[lot|lot<-M.elems(invLots inventory),lotOwner lot==destination,lotResource lot==Ration])
  assert "frozen fixture exact fourth-colony consumption totals"(foodConsumed==5000&&waterConsumed==25420)
  assert "newly extracted water actually consumed in fourth colony"
    (waterConsumed>0&&waterConsumed+physical final destination Water==50000)
  assert "exact real edge-entry count including all return journeys"(entries==180)
  assert "completed scenario has no quantity/natural/capacity reservations"
    (M.null(invQuantity inventory)&&M.null(invCapacity inventory)&&M.null(invNatural inventory))
  assert "all four carts physically home after deliveries"
    (all(\vehicle->vehiclePosition vehicle==AtRoadNode(M.findWithDefault(RoadNode 999)(vehicleHome vehicle)(transportPorts(worldTransport final))))(M.elems(transportVehicles(worldTransport final))))
  (saved,bytes)<-case checkpoint of Nothing->ioError(userError "Missing in-transit checkpoint");Just value->pure value
  assert "checkpoint contains actual in-flight cargo"
    (any(\vehicle->case vehiclePosition vehicle of Traversing _ _ _ _->True;_->False)(M.elems(transportVehicles(worldTransport saved)))
      &&any((==ShipmentCarrying).shipmentStatus)(M.elems(transportShipments(worldTransport saved))))
  let savedInventory=worldInventory saved
      savedTransport=worldTransport saved
      savedFarm=Owner MachineInput(supplyFarm descriptor)
      waterOnCarts=sum[physical saved(vehicleOwner vehicle)Water|vehicle<-M.elems(transportVehicles savedTransport)]
  assert "in-transit cargo is physical, source retained10k, destination still empty"
    (physical saved(Owner MachineOutput(supplyPump descriptor))Water==10000
      &&physical saved savedFarm Water==0&&waterOnCarts==50000)
  assert "parent plus child retain exactly60k source/destination claims in transit"
    (sum[qtyValue(quantityAmount reservation)|reservation<-M.elems(invQuantity savedInventory)]==60000
      &&reservedWeight savedInventory savedFarm==60000)
  (_,restored)<-must "canonical checkpoint reload"(decodeCheckpoint bytes)
  assert "full world survives in-transit checkpoint"(restored==saved)
  contentDigest<-must "content hash"(contentHash content)
  let replay=Replay(ReplayHeader 1 1(sha256 bytes)(worldRuleset saved)contentDigest "RDF-RNG-1" 1 "four-colony-road-v1" 1)(reverse frames)
  replayBytes<-must "encode full canonical suffix"(encodeReplay replay)
  replayed<-must "decode full canonical suffix"(decodeReplay replayBytes)
  assert "all suffix NativeInput/output/hash frames roundtrip"(replayed==replay&&length frames==fromIntegral(supplyChainTicks-1220))
  finalReplay<-foldM replayOne restored(replayFrames replayed)
  assert "full suffix replay exact final authoritative state"(finalReplay==final)
  finalHash<-must "final canonical hash"(canonicalStateHash final)
  putStrLn("SupplyChain milestones="++show(reverse completed))
  putStrLn("SupplyChain result ticks="++show(simTick final)++" fourth-colony newly-cooked ration consumed="++show foodConsumed
    ++" extracted water consumed="++show waterConsumed++" real edge entries="++show entries++" finalSHA256="++hex finalHash)
  putStrLn("SupplyChainTests PASS: 16000 NativeInput boundaries; full pureStep/Arena.play parity; 4 colonies/40 residents/4 carts; 6 real child trips; P6 fuel power; P8 new-food consumption; in-flight canonical checkpoint +14780-frame suffix replay ("++show(BS.length replayBytes)++" bytes)")

runTrace :: SupplyChainDescriptor -> World -> SupplyChainPolicy -> Maybe(World,BS.ByteString)
  -> [ReplayFrame] -> Integer -> Integer -> Integer -> [(SimTick,String)]
  -> IO(World,SupplyChainPolicy,Maybe(World,BS.ByteString),[ReplayFrame],Integer,Integer,Integer,[(SimTick,String)])
runTrace descriptor !world !policy checkpoint frames !food !water !entries milestones
  | simTick world>=SimTick supplyChainTicks=pure(world,policy,checkpoint,frames,food,water,entries,milestones)
  | otherwise=do
      let (nextPolicy,commands)=supplyChainCommands descriptor(observe Colony 1 world)policy
          input@(Boundary header _ management)=supplyChainBoundary world commands
      (next,out)<-evaluate(force(pureStep input world))
      let SimTick progressTick=simTick next
      if progressTick `mod` 2000==0 then putStrLn("SupplyChain native/Arena tick="++show progressTick)>>hFlush stdout else pure()
      throughArena<-must "Arena.play admission"(play Colony(RecordedBoundary header(map commandId commands)management)(singleton 1(OrderedBatch commands))world)
      assert("pure/Arena parity at "++show(simTick world))(throughArena==(next,out))
      must "validateWorld at every boundary"(validateWorld next)
      assert("active and no diagnostic at "++show(simTick world))(worldMode next==Active&&null(outputDiagnostics out))
      assert "every planned command applied"(all(\receipt->case receiptOutcome receipt of Applied _->True;_->False)(outputReceipts out))
      entered<-motionCheck world next
      let target=last(supplyPantries descriptor)
          consumed resource=sum[ledgerQuantity entry|entry<-invRecentLedger(worldInventory next),ledgerResource entry==resource
            ,ledgerReason entry==LivingConsumed,ledgerFrom entry==Just target
            ,let TxId _ _ boundary phase _=ledgerTx entry,boundary==boundarySeq world,phase==P8]
          finished=[(simTick next,jobRecipe job)|JobCompleted _ ident<-outputEvents out,Just job<-[M.lookup ident(worldJobs next)]]
          commandsAt=[(simTick next,show(commandBody command))|command<-commands]
          delivered=[(simTick next,"delivered "++show(requestResource request)++" "++show(requestQuantity request)++" to "++show(requestDestination request))
            |request<-M.elems(transportRequests(worldTransport next)),requestStatus request==RequestCompleted
            ,maybe True((/=RequestCompleted).requestStatus)(M.lookup(requestId request)(transportRequests(worldTransport world)))]
          firstFood=[(simTick next,"fourth colony first freshly cooked ration consumption")|food==0&&consumed Ration>0]
      checkpoint'<-if simTick next==SimTick 1220 then do
        bytes<-must "encode in-flight checkpoint"(encodeCheckpoint defaultCheckpointMeta next)
        pure(Just(next,bytes))else pure checkpoint
      frames'<-if simTick next>SimTick 1220 then do
        digest<-must "canonical suffix boundary hash"(canonicalStateHash next) >>= evaluate . force
        forcedInput<-evaluate(force input)
        pure(ReplayFrame forcedInput out digest:frames)else pure frames
      milestones'<-evaluate(force(reverse(commandsAt++delivered++finished++firstFood)++milestones))
      runTrace descriptor next nextPolicy checkpoint' frames'(food+consumed Ration)(water+consumed Water)(entries+entered)milestones'

motionCheck :: World -> World -> IO Integer
motionCheck before after=foldM check 0(M.toList(transportVehicles(worldTransport before)))
  where
    check count(ident,old)=do
      next<-maybe(ioError(userError "Vehicle vanished"))pure(M.lookup ident(transportVehicles(worldTransport after)))
      let previous=vehiclePosition old;current=vehiclePosition next
          entered=case current of Traversing _ _ 20 _->previous/=current;_->False
          legal=case(previous,current)of
            (AtRoadNode a,AtRoadNode b)->a==b
            (AtRoadNode a,Traversing from to 20 _)->a==from&&nodeDistance from to==1
            (Traversing a b n rev,Traversing a' b' n' rev')->
              (n>1&&a==a'&&b==b'&&n'==n-1&&rev==rev')||(n==1&&b==a'&&n'==20&&nodeDistance a' b'==1)
            (Traversing _ b 1 _,AtRoadNode node)->b==node
            _->False
      assert("no teleport; integer edge progress "++show ident++" at "++show(simTick before))(legal)
      pure(count+if entered then 1 else 0)

replayOne :: World -> ReplayFrame -> IO World
replayOne world frame=do
  (next,out)<-evaluate(force(pureStep(replayInput frame)world))
  assert "suffix exact domain events and receipts"(out==replayOutput frame)
  must "suffix validateWorld"(validateWorld next)
  digest<-must "suffix canonical state hash"(canonicalStateHash next)
  assert("suffix exact canonical state hash at "++show(simTick next))(digest==replayStateHash frame)
  let SimTick replayTick=simTick next
  if replayTick `mod` 2000==0 then putStrLn("SupplyChain canonical replay tick="++show replayTick)>>hFlush stdout else pure()
  pure next

hex :: BS.ByteString -> String
hex=concatMap(\byte->let text=showHex byte "" in if length text==1 then '0':text else text).BS.unpack
