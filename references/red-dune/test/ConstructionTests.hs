{-# LANGUAGE BangPatterns #-}
module ConstructionTests (main, constructionTests) where

import Colony.Construction
import Colony.Content
import Colony.ContentCodec (knownV1ContentId, knownV2ContentId)
import qualified Colony.Inventory as I
import qualified Colony.Space as S
import Colony.Types
import Colony.Units
import Control.DeepSeq (force)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (foldM, forM_, unless)
import qualified Data.ByteString as BS
import Data.IORef
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Ratio ((%))
import qualified Data.Set as Set
import Data.Word (Word64)
import System.Exit (exitFailure)
import Text.Read (readMaybe)

-- Deliberately independent of Construction.constructionRefund, Inventory.fefo,
-- Jobs.planReturnPlacement and the World scheduler. Rational division avoids
-- any floating point and computes the two normative floors separately.
refundOracle :: Integer -> Integer -> Integer -> Integer
refundOracle quantity progress required =
  let consumedBps = floor ((progress % required) * 5000) :: Integer
  in floor ((quantity % 1) * ((10000-consumedBps) % 10000))

fefoOracle :: Lot -> (Maybe (Integer,Integer), Integer, Word64)
fefoOracle lot = (Just expiry, born, ident)
  where
    expiry = case lotExpires lot of Nothing -> (1,0); Just (SimTick tick) -> (0,toInteger tick)
    SimTick birth = lotBorn lot
    born = toInteger birth
    EntityId ident = lotId lot

-- Cut loss once from the resource-total FEFO stream, retaining metadata. This
-- oracle never allocates production lots and compares provenance+age totals.
type LotView = (Resource,String,SimTick,Maybe SimTick)
lotView :: Lot -> LotView
lotView lot = (lotResource lot,lotProvenance lot,lotBorn lot,lotExpires lot)
lotSummary :: [Lot] -> M.Map LotView Integer
lotSummary lots = M.fromListWith (+) [(lotView lot,qtyValue (lotQty lot)) | lot <- lots]
survivorOracle :: Integer -> [Lot] -> M.Map LotView Integer
survivorOracle loss lots = M.fromListWith (+) (cut loss (sortOn fefoOracle lots))
  where
    cut _ [] = []
    cut n (lot:rest) = let q=qtyValue (lotQty lot);gone=min n q
                       in [(lotView lot,q-gone) | q>gone] ++ cut (n-gone) rest

left :: Either a b -> Bool
left (Left _) = True
left _ = False
must :: Show e => String -> Either e a -> IO a
must label = either (ioError . userError . ((label++": ")++) . show) pure

data Check = Check !(IORef Integer) !(IORef [String])
check :: Check -> String -> Bool -> IO ()
check (Check counter failures) label ok = do
  modifyIORef' counter (+1)
  unless ok $ do
    modifyIORef' failures (label:)
    putStrLn ("FAIL "++label)

data Base = Base
  { baseColony :: !EntityId, baseForeign :: !EntityId
  , baseWarehouse :: !Owner, baseSecond :: !Owner, baseForeignWarehouse :: !Owner
  , baseVehicle :: !Owner, baseSource :: !EntityId
  , baseInventory :: !Inventory, baseSpace :: !S.SpatialState }
  deriving (Eq,Show,Read)

data Bundle = Bundle !ConstructionJob !S.SpatialState !Inventory
  deriving (Eq,Show,Read)
jobOf :: Bundle -> ConstructionJob
jobOf (Bundle job _ _) = job
spaceOf :: Bundle -> S.SpatialState
spaceOf (Bundle _ space _) = space
invOf :: Bundle -> Inventory
invOf (Bundle _ _ inventory) = inventory

fixture :: Content -> IO Base
fixture content = do
  ((colony,foreignColony,first,second,foreignOwner,vehicle,source),inventory) <- must "fixture inventory" $ I.runInventory (do
    colony <- I.freshId
    foreignColony <- I.freshId
    firstId <- I.freshId
    secondId <- I.freshId
    foreignId <- I.freshId
    vehicleId <- I.freshId
    let first=Owner Warehouse firstId;second=Owner Warehouse secondId
        foreignOwner=Owner Warehouse foreignId;vehicle=Owner Vehicle vehicleId
    I.addStorage first (Storage 2000000 Nothing colony)
    I.addStorage second (Storage 2000000 Nothing colony)
    I.addStorage foreignOwner (Storage 2000000 Nothing foreignColony)
    I.addStorage vehicle (Storage 200000 Nothing colony)
    source <- I.addDeposit "aquifer" Water 1000000
    pure (colony,foreignColony,first,second,foreignOwner,vehicle,source)) (I.emptyInventory content)
  let spatial=(S.emptySpatial (S.MapSpec "construction-oracle-64" 1 (S.Rect (S.Tile 0 0) 64 64) (S.Tile 0 0) M.empty))
        {S.spatialSources=M.singleton source (S.SourceRegion source "aquifer" Water (S.Rect (S.Tile 10 10) 8 8))
        ,S.spatialRoads=Set.fromList [S.Tile 30 31,S.Tile 10 20]
        ,S.spatialOwnerLocations=M.fromList [(first,S.OwnerLocation (S.Tile 1 1) (Just (S.Tile 1 2))),(second,S.OwnerLocation (S.Tile 2 1) (Just (S.Tile 2 2))) ]}
  _ <- must "fixture spatial validation" (S.validateSpatial content inventory spatial)
  pure (Base colony foreignColony first second foreignOwner vehicle source inventory spatial)

roadShape, pumpShape :: S.PlacementShape
roadShape=S.RoadShape (S.Tile 30 30)
pumpShape=S.BuildingShape "hand_pump" (S.Tile 10 18) S.R0

tx :: Phase -> Word64 -> TxId
tx phase serial = TxId 606 1 (BoundarySeq 1) phase serial
place :: Content -> Base -> S.PlacementShape -> IO Bundle
place content base shape = do
  ((job,spatial),inventory) <- must "place" $ I.runInventory
    (placeConstruction content (SimTick 0) (baseColony base) shape 1 Nothing (baseSpace base)) (baseInventory base)
  pure (Bundle job spatial inventory)

step :: Bundle -> (ConstructionJob -> S.SpatialState -> I.InventoryTx (ConstructionJob,S.SpatialState)) -> Either Failure Bundle
step (Bundle job spatial inventory) action = do
  ((nextJob,nextSpace),nextInventory) <- I.runInventory (action job spatial) inventory
  pure (Bundle nextJob nextSpace nextInventory)
start :: Content -> Bundle -> Either Failure Bundle
start content bundle=step bundle (startConstruction content (SimTick 0) True)
cancel :: Content -> Bundle -> Either Failure Bundle
cancel content bundle=step bundle (\job -> cancelConstruction content (tx P1 2) (constructionRevision job) job)
advance :: Content -> Integer -> Bundle -> Either Failure (Bundle,Maybe ConstructionCompletion)
advance content credit (Bundle job spatial inventory)=do
  ((nextJob,nextSpace,completion),nextInventory)<-I.runInventory (advanceConstruction content (tx P7 3) credit job spatial) inventory
  pure (Bundle nextJob nextSpace nextInventory,completion)

-- All materials are physical, ledger-backed fixture grants. Production P5 must
-- move those lots; it is never allowed to mint the recipe's missing cost.
give :: Owner -> [(Resource,Integer,Word64,Maybe Word64,String)] -> Bundle -> IO Bundle
give owner lots (Bundle job spatial inventory)=do
  (_,next)<-must "fixture grant" $ I.runInventory (forM_ lots $ \(resource,quantity,born,expires,tag)->do
    _<-I.mintLot (tx P0 1) InitialGrant Nothing resource quantity owner (SimTick born) (SimTick <$> expires) tag
    pure ()) inventory
  pure (Bundle job spatial next)
fund :: Bundle -> IO Bundle
fund bundle = give (constructionInput (jobOf bundle))
  [(resource,quantity,0,Nothing,"cost:"++show resource) | (resource,quantity)<-M.toAscList (constructionCost (constructionSnapshot (jobOf bundle)))] bundle
physical :: Owner -> Resource -> Inventory -> Integer
physical owner resource inventory=sum [qtyValue (lotQty lot) | lot<-M.elems (invLots inventory),lotOwner lot==owner,lotResource lot==resource]
stock :: Resource -> Inventory -> Integer
stock resource inventory=sum [qtyValue (lotQty lot) | lot<-M.elems (invLots inventory),lotResource lot==resource]
ledger :: Reason -> Resource -> Inventory -> Integer
ledger reason resource inventory=M.findWithDefault 0 (resource,reason) (invLedger inventory)

valid :: Check -> Content -> String -> Bundle -> IO ()
valid checks content label (Bundle job spatial inventory)=do
  check checks (label++" inventory valid") (I.validateInventory inventory==Right ())
  check checks (label++" spatial valid") (S.validateSpatial content inventory spatial==Right ())
  check checks (label++" construction valid") (validateConstructionJob content inventory spatial job==Right ())
  let accounted=if constructionPhase job==ConstructionCompleted then M.singleton (constructionSiteId job) (constructionCost (constructionSnapshot job)) else M.empty
  check checks (label++" state-map valid") (validateConstruction content inventory spatial (ConstructionState (M.singleton (constructionSiteId job) job) accounted)==Right ())

snapshotTests :: Check -> Content -> IO ()
snapshotTests checks content=do
  pump<-must "pump snapshot" (snapshotFor content pumpShape)
  road<-must "road snapshot" (snapshotFor content roadShape)
  check checks "pump exact content cost 20kg" (constructionCost pump==M.fromList [(Stone,10000),(Metal,10000)] && constructionRequired pump==120000 && constructionCrewRequired pump==2)
  check checks "road exact 2kg/20ticks/crew2" (constructionCost road==M.singleton Stone 2000 && constructionRequired road==2000 && constructionCrewRequired road==2)
  check checks "known v1 catalog bound" (constructionContentId pump==knownV1ContentId && constructionRuleVersion pump==1)
  forM_ ["pump","warehouse","brine_pump","unknown"] $ \prototype->check checks ("unsupported prototype "++prototype) (left (snapshotFor content (S.BuildingShape prototype (S.Tile 30 30) S.R0)))
  let mutations=[("wrong cost",pump {constructionCost=M.singleton Stone 1}),("wrong kind",pump {constructionKind=BuildRoad}),("wrong work",pump {constructionRequired=119999}),("wrong crew",pump {constructionCrewRequired=1}),("wrong rule",pump {constructionRuleVersion=2}),("unknown catalog",pump {constructionContentId=BS.replicate 32 0}),("future catalog",pump {constructionContentId=knownV2ContentId})]
  forM_ mutations $ \(label,bad)->check checks ("snapshot rejects "++label) (left (validateConstructionSnapshot content pumpShape bad))
  let modified=content {contentBuildings=M.adjust (\b->b {buildingBuildWorkTicks=1}) "hand_pump" (contentBuildings content)}
  check checks "self-consistent but unknown catalog rejected" (left (snapshotFor modified pumpShape))
  let contentV2=content {contentRecipes=M.adjust (\r->r {recipeInputs=M.insert Fuel 800 (recipeInputs r),recipeOutputs=M.insert Ration 19000 (recipeOutputs r)}) "cook" (contentRecipes content)}
  next<-must "known v2 construction snapshot" (snapshotFor contentV2 pumpShape)
  check checks "v2 construction catalog is canonical" (constructionContentId next==knownV2ContentId)
  check checks "known predecessor construction snapshot valid under v2" (validateConstructionSnapshot contentV2 pumpShape pump==Right ())
  putStrLn "TRANSITION snapshot supported=hand_pump,road pumpCost=20000 roadCost=2000 crew=2 exactCatalog PASS-CHECKED"

refundTests :: Check -> IO ()
refundTests checks=do
  let small=[(q,p,r) | q<-[0..64],r<-[1..24],p<-[0..r]]
      large=[(q,p,r) | q<-[1,1999,2000,10000,quantityMax],r<-[2000,120000,quantityMax],p<-[0,1,r `div` 2,r-1,r]]
      vectors=small++large
  check checks ("Rational refund oracle "++show (length vectors)++" vectors")
    (all (\(q,p,r)->constructionRefund q p r==Right (refundOracle q p r)) vectors)
  forM_ [(-1,0,1),(1,-1,1),(1,2,1),(1,0,0),(1,0,-1)] $ \(q,p,r)->check checks ("invalid refund domain "++show (q,p,r)) (constructionRefund q p r==Left InvalidQuantity)
  check checks "resource-total single floor discriminates per-lot floor" (refundOracle 2000 1 2000==1999 && sum [refundOracle 1 1 2000 | _<-[1..2000::Integer]]==0)
  putStrLn ("TRANSITION refund independentRationalVectors="++show (length vectors)++" singleResourceFloor=1999 versusPerUnitFloor=0")

admissionTests :: Check -> Content -> IO ()
admissionTests checks content=do
  base<-fixture content
  planned<-place content base pumpShape
  valid checks content "planned" planned
  check checks "place does not mint stock or consume anything" (M.null (invLots (invOf planned)) && M.null (invLedger (invOf planned)))
  check checks "place reserves footprint but never starts" (constructionPhase (jobOf planned)==ConstructionPlanned && S.placementStage (S.spatialPlacements (spaceOf planned) M.! constructionSiteId (jobOf planned))==S.PlanReserved)
  check checks "P5 absent site stock fails" (start content planned==Left MissingStock)
  warehouseStock<-give (baseWarehouse base) [(Stone,10000,0,Nothing,"offsite-stone"),(Metal,10000,0,Nothing,"offsite-metal")] planned
  check checks "offsite stock and reservation are not siteInput" (start content warehouseStock==Left MissingStock)
  (_,reserved)<-must "incoming reservation fixture" $ I.runInventory (do
    delivery<-I.freshId
    I.reserveDelivery (SimTick 0) delivery (baseWarehouse base) (constructionInput (jobOf planned)) Stone 10000) (invOf warehouseStock)
  check checks "incoming reservation cannot fabricate material" (start content (Bundle (jobOf planned) (spaceOf planned) reserved)==Left MissingStock)
  partial<-give (constructionInput (jobOf planned)) [(Stone,10000,0,Nothing,"delivered-first-resource")] planned
  check checks "all resources must arrive before any escrow" (start content partial==Left MissingStock && physical (constructionEscrow (jobOf partial)) Stone (invOf partial)==0)
  funded<-fund planned
  check checks "no crew boolean means no start or mutation" (step funded (startConstruction content (SimTick 0) False)==Left (constructionFailure "WaitingWorkers"))
  let job=jobOf partial;inventory=invOf partial
  forM_ [(Stone,1,0),(Metal,10001,0),(Metal,1,10000),(Water,1,0),(Metal,0,0),(Metal,1,-1)] $ \(resource,quantity,incoming)->
    check checks ("reject excessive/unexpected delivery "++show (resource,quantity,incoming)) (left (admitConstructionDelivery job resource quantity incoming inventory))
  check checks "incoming counts exact remaining requirement" (admitConstructionDelivery job Metal 5000 5000 inventory==Right ())
  running<-must "full escrow P5" (start content funded)
  valid checks content "running" running
  check checks "P5 complete exact physical escrow" (all (\(r,q)->physical (constructionInput (jobOf running)) r (invOf running)==0 && physical (constructionEscrow (jobOf running)) r (invOf running)==q) [(Stone,10000),(Metal,10000)])
  check checks "P5 no consumption or source reserve" (M.null (invQuantity (invOf running)) && M.null (invNatural (invOf running)) && ledger ConstructionConsumed Stone (invOf running)==0)
  check checks "running rejects deliveries and second start" (left (admitConstructionDelivery (jobOf running) Stone 1 0 (invOf running)) && start content running==Left AlreadyTerminal)
  (waiting,_)<-must "waiting state" (I.runInventory (setConstructionWaiting False MissingStock (jobOf planned)) (invOf planned))
  (moving,_)<-must "moving state" (I.runInventory (setConstructionWaiting True MissingStock waiting) (invOf planned))
  (same,_)<-must "same waiting does not churn revision" (I.runInventory (setConstructionWaiting True MissingStock moving) (invOf planned))
  check checks "waiting->moving is metadata only and idempotent" (constructionPhase waiting==ConstructionWaitingInputs && constructionPhase moving==ConstructionMovingInputs && same==moving && constructionRevision moving==constructionRevision waiting+1)
  putStrLn "TRANSITION Planned->WaitingInputs->MovingInputs->Running completePhysicalEscrow P5; missing+offsite+partial+noCrew rollback"

completionTests :: Check -> Content -> IO ()
completionTests checks content=do
  forM_ [roadShape,pumpShape] $ \shape->do
    base<-fixture content
    planned<-place content base shape
    funded<-fund planned
    running<-must "start for completion" (start content funded)
    let required=constructionRequired (constructionSnapshot (jobOf running))
    forM_ [-1,131,quantityMax] $ \credit->check checks ("invalid workcredit "++show credit) (advance content credit running==Left InvalidQuantity)
    check checks "zero credit is literal unchanged triple" (advance content 0 running==Right (running,Nothing))
    forM_ [1..130] $ \credit->do
      (progressed,completion)<-must "positive workcredit" (advance content credit running)
      check checks "credit is exact integer, one revision" (constructionProgress (jobOf progressed)==credit && constructionRevision (jobOf progressed)==constructionRevision (jobOf running)+1 && completion==Nothing)
    beforeEnd<-foldM (\state credit->fst <$> must "advance to required-1" (advance content credit state)) running (credits (required-1))
    check checks "precomplete stock remains full physical escrow" (all (\(r,q)->physical (constructionEscrow (jobOf beforeEnd)) r (invOf beforeEnd)==q) (M.toList (constructionCost (constructionSnapshot (jobOf beforeEnd)))))
    (complete,completion)<-must "one credit completes" (advance content 1 beforeEnd)
    valid checks content "complete" complete
    let finished=jobOf complete;finalInv=invOf complete
    check checks "exactly one terminal at required" (constructionPhase finished==ConstructionCompleted && constructionProgress finished==required && constructionTerminalCount finished==1)
    check checks "completion consumes exact cost once" (all (\(r,q)->ledger ConstructionConsumed r finalInv==q && stock r finalInv==0) (M.toList (constructionCost (constructionSnapshot finished))))
    check checks "completed escrow store gone" (M.notMember (constructionEscrow finished) (invStorage finalInv) && M.notMember (constructionEscrow finished) (S.spatialOwnerLocations (spaceOf complete)))
    check checks "double complete and post-complete cancel reject" (advance content 1 complete==Left AlreadyTerminal && cancel content complete==Left AlreadyTerminal)
    let jobMap=M.singleton (constructionSiteId finished) finished
    check checks "completed whole-state requires accounted cost" (left (validateConstruction content finalInv (spaceOf complete) (ConstructionState jobMap M.empty)))
    check checks "completed whole-state cannot forge accounted cost" (left (validateConstruction content finalInv (spaceOf complete) (ConstructionState jobMap (M.singleton (constructionSiteId finished) (M.singleton Stone 1)))))
    check checks "completed delivery admission rejects" (left (admitConstructionDelivery finished Stone 1 0 finalInv))
    case shape of
      S.RoadShape tile->check checks "road activates exact tile and removes input store" (completion==Just (RoadConstructed (constructionSiteId finished) tile) && Set.member tile (S.spatialRoads (spaceOf complete)) && M.notMember (constructionInput finished) (invStorage finalInv))
      _->do
        let output=Owner MachineOutput (constructionSiteId finished)
        check checks "pump creates output and retains same source, no water minted" (completion==Just (PumpConstructed (constructionSiteId finished) (constructionInput finished) output (baseSource base)) && stock Water finalInv==0 && M.member output (invStorage finalInv))
        forM_ [("input",constructionInput finished),("output",output)] $ \(label,owner)->do
          let removed=finalInv {invStorage=M.delete owner (invStorage finalInv)}
              wrong=finalInv {invStorage=M.adjust (\s->s {storageColony=baseForeign base}) owner (invStorage finalInv)}
          check checks ("completed pump rejects missing "++label++" storage") (left (validateConstructionJob content removed (spaceOf complete) finished))
          check checks ("completed pump rejects foreign "++label++" storage") (left (validateConstructionJob content wrong (spaceOf complete) finished))
    (overshoot,_)<-must "bounded completion overshoot" (advance content 130 beforeEnd)
    check checks "overshoot clamps progress to required and never overconsumes" (constructionProgress (jobOf overshoot)==required && invLedger (invOf overshoot)==invLedger finalInv)
    putStrLn ("TRANSITION "++show shape++" 0->"++show (required-1)++"->"++show required++" completeOnce ledger=exactCost")
  where
    credits n=replicate (fromInteger (n `div` 130)) 130 ++ [n `mod` 130 | n `mod` 130>0]

cancellationTests :: Check -> Content -> IO ()
cancellationTests checks content=do
  base<-fixture content
  planned<-place content base roadShape
  emptyCancelled<-must "empty cancel" (cancel content planned)
  valid checks content "empty cancelled" emptyCancelled
  let impossibleCancel=(jobOf emptyCancelled) {constructionProgress=constructionRequired (constructionSnapshot (jobOf emptyCancelled))}
  check checks "cancelled job cannot encode completed progress" (left (validateConstructionJob content (invOf emptyCancelled) (spaceOf emptyCancelled) impossibleCancel))
  check checks "empty cancellation no loss/refund/allocation" (invNextId (invOf emptyCancelled)==invNextId (invOf planned) && M.null (invLedger (invOf emptyCancelled)))
  forM_ [ConstructionPlanned,ConstructionWaitingInputs,ConstructionMovingInputs,ConstructionReady] $ \phase->do
    let prior=Bundle ((jobOf planned) {constructionPhase=phase}) (spaceOf planned) (invOf planned)
    partial<-give (constructionInput (jobOf prior)) [(Stone,773,0,Nothing,"arrived-773")] prior
    inVehicle<-give (baseVehicle base) [(Stone,1227,0,Nothing,"in-transit-1227")] partial
    cancelled<-must "pre-escrow cancel" (cancel content inVehicle)
    valid checks content ("cancel "++show phase) cancelled
    check checks "only actual delivered stock returned, no loss before escrow" (physical (baseWarehouse base) Stone (invOf cancelled)==773 && physical (baseVehicle base) Stone (invOf cancelled)==1227 && ledger ConstructionLoss Stone (invOf cancelled)==0)
    check checks "cancel terminal unique and releases placement" (constructionTerminalCount (jobOf cancelled)==1 && M.notMember (constructionSiteId (jobOf cancelled)) (S.spatialPlacements (spaceOf cancelled)) && cancel content cancelled==Left AlreadyTerminal)
  let partitions=[[2000],[1,1999],[999,1,1000],[333,333,333,333,333,335],replicate 20 100]
      progressCases=[0,1,2,3,399,400,999,1000,1001,1998,1999]
  forM_ (zip [0::Integer ..] partitions) $ \(partitionId,parts)->do
    physicalInput<-give (constructionInput (jobOf planned)) [(Stone,q,fromInteger index,if even index then Just (1000+fromInteger index) else Nothing,"part:"++show index) | (index,q)<-zip [0::Integer ..] parts] planned
    running<-must "partition escrow" (start content physicalInput)
    forM_ progressCases $ \progress->do
      let before=Bundle ((jobOf running) {constructionProgress=progress}) (spaceOf running) (invOf running)
          escrowLots=[lot | lot<-M.elems (invLots (invOf before)),lotOwner lot==constructionEscrow (jobOf before)]
          expected=refundOracle 2000 progress 2000
          metadata=survivorOracle (2000-expected) escrowLots
      cancelled<-must "progress cancel" (cancel content before)
      valid checks content "progress-cancel" cancelled
      check checks ("partition invariant "++show (partitionId,progress)) (stock Stone (invOf cancelled)==expected && ledger ConstructionLoss Stone (invOf cancelled)==2000-expected)
      check checks ("FEFO loss preserves remaining age/provenance "++show (partitionId,progress)) (lotSummary (M.elems (invLots (invOf cancelled)))==metadata)
      check checks "cancel preserves progress and never consumes completed cost" (constructionProgress (jobOf cancelled)==progress && ledger ConstructionConsumed Stone (invOf cancelled)==0)
  pumpPlan<-place content base pumpShape
  pumpFunded<-fund pumpPlan
  pumpRunning<-must "pump escrow" (start content pumpFunded)
  forM_ [0,1,60000,119999] $ \progress->do
    let before=Bundle ((jobOf pumpRunning) {constructionProgress=progress}) (spaceOf pumpRunning) (invOf pumpRunning)
    cancelled<-must "pump cancel" (cancel content before)
    check checks "pump per-resource totals independent" (all (\resource->stock resource (invOf cancelled)==refundOracle 10000 progress 120000 && ledger ConstructionLoss resource (invOf cancelled)==10000-refundOracle 10000 progress 120000) [Stone,Metal])
  putStrLn "TRANSITION cancel new/waiting/moving/ready/escrow/progress; 5 partitions x 11 progress cases; loss/refund FEFO metadata checked"

capacityTests :: Check -> Content -> IO ()
capacityTests checks content=do
  base<-fixture content
  planned<-place content base pumpShape
  funded<-fund planned
  running<-must "capacity running" (start content funded)
  -- Constrain real warehouse capacity/typing without sharing the production
  -- allocator. Only stone can occupy warehouse1; all metal must use warehouse2.
  let typedInv=(invOf running) {invStorage=M.adjust (\st->st {storageCapacity=10000,storageResource=Just Stone}) (baseWarehouse base) $ M.adjust (\st->st {storageCapacity=10000}) (baseSecond base) (invStorage (invOf running))}
      typed=Bundle (jobOf running) (spaceOf running) typedInv
  typedReturn<-must "independent typed warehouse assignment" (cancel content typed)
  check checks "typed/lowest-ID return allocation" (physical (baseWarehouse base) Stone (invOf typedReturn)==10000 && physical (baseWarehouse base) Metal (invOf typedReturn)==0 && physical (baseSecond base) Metal (invOf typedReturn)==10000 && M.null (S.spatialCaches (spaceOf typedReturn)))
  -- Reserve almost all warehouse capacity for unrelated delivery. Returns must
  -- honor the existing claims and allocate exactly one real ground cache.
  (_,reservedInv)<-must "capacity reservation" $ I.runInventory (do
    foreignJob<-I.freshId
    I.reserveCapacity foreignJob (baseWarehouse base) Stone 1999700
    I.reserveCapacity foreignJob (baseSecond base) Stone 1999600) (invOf running)
  returned<-must "reserved return" (cancel content (Bundle (jobOf running) (spaceOf running) reservedInv))
  let inv=invOf returned;caches=S.spatialCaches (spaceOf returned)
      warehouseHeld=I.heldWeight inv (baseWarehouse base)+I.heldWeight inv (baseSecond base)
      cacheHeld=sum [I.heldWeight inv (S.cacheOwner cache) | cache<-M.elems caches]
  check checks "return honors incoming capacity reservations" (warehouseHeld==700 && cacheHeld==19300 && M.size caches==1 && invCapacity inv==invCapacity reservedInv)
  check checks "foreign colony warehouse never chosen" (I.heldWeight inv (baseForeignWarehouse base)==0)
  check checks "nearest released pump origin cache chosen" (M.member (S.Tile 10 18) caches)
  valid checks content "capacity return" returned
  -- An unrelated incoming reservation on the site's own input survives until
  -- the caller cancels transport, so deleting the site must fail atomically.
  (_,foreignReservation)<-must "foreign site capacity" $ I.runInventory (do
    foreignJob<-I.freshId
    I.reserveCapacity foreignJob (constructionInput (jobOf running)) Stone 1) (invOf running)
  check checks "cancel cannot orphan foreign capacity reservation" (cancel content (Bundle (jobOf running) (spaceOf running) foreignReservation)==Left ReturnCapacityFull)
  -- One-tile scenario: the removed road tile is the only eligible cache.
  -- A foreign-colony cache on that tile makes full cancellation impossible.
  roadPlan<-place content base roadShape
  roadFunded<-fund roadPlan
  roadRunning<-must "road return capacity" (start content roadFunded)
  let roadInv=(invOf roadRunning) {invStorage=M.adjust (\st->st {storageCapacity=0}) (baseWarehouse base) $ M.adjust (\st->st {storageCapacity=0}) (baseSecond base) (invStorage (invOf roadRunning))}
      spatial=(spaceOf roadRunning) {S.spatialMap=S.MapSpec "blocked-return-one-tile" 1 (S.Rect (S.Tile 30 30) 1 1) (S.Tile 0 0) M.empty,S.spatialSources=M.empty,S.spatialRoads=Set.empty}
      blocked=Bundle (jobOf roadRunning) spatial roadInv
      counterExhausted=Bundle (jobOf blocked) spatial (roadInv {invNextId=maxBound})
  check checks "new-cache allocator overflow rolls back loss and placement" (cancel content counterExhausted==Left CounterOverflow)
  -- Strictly no eligible return cells after cancellation: a road site on a
  -- now-cliff tile is allowed as a corruption/transaction defense fixture.
  let noCells=spatial {S.spatialMap=(S.spatialMap spatial) {S.mapTerrain=M.singleton (S.Tile 30 30) S.Cliff}}
      denied=Bundle ((jobOf roadRunning) {constructionProgress=1000}) noCells roadInv
  check checks "no total return placement means whole cancel failure" (cancel content denied==Left ReturnCapacityFull)
  check checks "failure exposes no modified inventory or spatial state" (stock Stone (invOf denied)==2000 && ledger ConstructionLoss Stone (invOf denied)==0 && constructionPhase (jobOf denied)==ConstructionRunning && M.member (constructionSiteId (jobOf denied)) (S.spatialPlacements (spaceOf denied)))
  putStrLn "TRANSITION returns typed warehouse fit, own-colony ordering, capacity reservation respected, nearest real cache; failure rollback"

-- Exhaustive finite allocation oracle. Enumerate EVERY two-warehouse matrix,
-- retain only complete fits, then select lexicographically greatest quantities
-- in resource/destination order. Add an unlimited third destination only when
-- no complete two-warehouse matrix exists. No feasibility/allocator production
-- helpers are used in either this oracle or the expected destination totals.
allocationOracle :: [(Integer,Maybe Resource)] -> [Integer]
allocationOracle bins = if null withoutCache then maximum withCache else maximum withoutCache
  where
    matrices cache=[ [a,b,3-a-b,c,d,2-c-d]
      | a<-[0..3],b<-[0..3-a],c<-[0..2],d<-[0..2-c]
      , cache || (a+b==3 && c+d==2)
      , and [stone+metal<=capacity && (typed==Nothing || (stone==0 || typed==Just Stone) && (metal==0 || typed==Just Metal))
            | ((capacity,typed),(stone,metal))<-zip bins [(a,c),(b,d)]]]
    withoutCache=matrices False
    withCache=matrices True

returnOracleTests :: Check -> Content -> IO ()
returnOracleTests checks content=do
  base<-fixture content
  planned<-place content base pumpShape
  loaded<-give (constructionInput (jobOf planned)) [(Stone,3,0,Nothing,"finite-stone"),(Metal,2,0,Nothing,"finite-metal")] planned
  let cases=[[(a,t),(b,u)] | a<-[0..5],b<-[0..5],t<-[Nothing,Just Stone,Just Metal],u<-[Nothing,Just Stone,Just Metal]]
  forM_ cases $ \bins->do
    let adjusted=foldr (\(owner,(capacity,typed))->M.adjust (\s->s {storageCapacity=capacity,storageResource=typed}) owner)
          (invStorage (invOf loaded)) (zip [baseWarehouse base,baseSecond base] bins)
        before=Bundle (jobOf loaded) (spaceOf loaded) ((invOf loaded) {invStorage=adjusted})
    returned<-must "finite return oracle transaction" (cancel content before)
    let finalInv=invOf returned
        caches=M.elems (S.spatialCaches (spaceOf returned))
        cacheQuantity resource=sum [physical (S.cacheOwner cache) resource finalInv | cache<-caches]
        actual=[physical (baseWarehouse base) Stone finalInv,physical (baseSecond base) Stone finalInv,cacheQuantity Stone
               ,physical (baseWarehouse base) Metal finalInv,physical (baseSecond base) Metal finalInv,cacheQuantity Metal]
    check checks ("finite independent return assignment "++show bins) (actual==allocationOracle bins)
    check checks "finite return does not duplicate/lose material" (stock Stone finalInv==3 && stock Metal finalInv==2 && ledger ConstructionLoss Stone finalInv==0)
  -- Destination-level FEFO must survive BOTH loss and a split across three
  -- destinations. Token expansion is tiny (2,000 units) and fully independent.
  roadPlan<-place content base roadShape
  roadLoaded<-give (constructionInput (jobOf roadPlan))
    [(Stone,500,2,Nothing,"no-expiry"),(Stone,800,3,Just 500,"expires-later"),(Stone,700,1,Just 400,"expires-first")] roadPlan
  roadRunning<-must "FEFO destination fixture" (start content roadLoaded)
  let adjusted=M.adjust (\s->s {storageCapacity=500}) (baseWarehouse base) $ M.adjust (\s->s {storageCapacity=300}) (baseSecond base) (invStorage (invOf roadRunning))
      prior=Bundle ((jobOf roadRunning) {constructionProgress=1010}) (spaceOf roadRunning) ((invOf roadRunning) {invStorage=adjusted})
      sortedLots=sortOn fefoOracle (M.elems (invLots (invOf prior)))
      tokens=concat [replicate (fromInteger (qtyValue (lotQty lot))) (lotView lot) | lot<-sortedLots]
      survivors=drop (fromInteger (2000-refundOracle 2000 1010 2000)) tokens
      expectedChunks=[take 500 survivors,take 300 (drop 500 survivors),drop 800 survivors]
      counts=M.fromListWith (+) . map (\key->(key,1::Integer))
  final<-must "FEFO split return" (cancel content prior)
  let cacheOwners=map S.cacheOwner (M.elems (S.spatialCaches (spaceOf final)))
      destinations=[baseWarehouse base,baseSecond base]++cacheOwners
  check checks "FEFO split exactly three physical destinations" (length destinations==3)
  forM_ (zip destinations expectedChunks) $ \(owner,expected)->check checks "independent FEFO tokens match each return destination"
    (lotSummary [lot | lot<-M.elems (invLots (invOf final)),lotOwner lot==owner]==counts expected)
  putStrLn ("TRANSITION return oracle exhaustiveMatrices="++show (length cases)++" typed+shared exact fits; loss+refund FEFO split across 3 destinations")

validationTests :: Check -> Content -> IO ()
validationTests checks content=do
  base<-fixture content
  planned<-place content base pumpShape
  funded<-fund planned
  running<-must "validation running" (start content funded)
  let job=jobOf planned;spatial=spaceOf planned;inventory=invOf planned
      invalid label badJob badInventory badSpace=check checks ("validator rejects "++label) (left (validateConstructionJob content badInventory badSpace badJob))
  forM_ [("zero job id",job {constructionJobId=EntityId 0}),("same site/job id",job {constructionJobId=constructionSiteId job}),("unallocated job",job {constructionJobId=EntityId (invNextId inventory)}),("wrong owner tag",job {constructionInput=Owner Warehouse (constructionSiteId job)}),("zero revision",job {constructionRevision=0}),("bad priority",job {constructionPriority=4}),("negative progress",job {constructionProgress= -1}),("too much progress",job {constructionProgress=120001}),("terminal count",job {constructionTerminalCount=1}),("source mismatch",job {constructionSource=Nothing})] $ \(label,bad)->invalid label bad inventory spatial
  invalid "absent placement" job inventory (spatial {S.spatialPlacements=M.empty})
  invalid "absent escrow storage" job (inventory {invStorage=M.delete (constructionEscrow job) (invStorage inventory)}) spatial
  -- These must be enforced by Construction, since Inventory and Space accept
  -- generic stores and cannot infer a construction input's normative type.
  forM_ [("foreign site input colony",constructionInput job,\st->st {storageColony=baseForeign base})
        ,("typed input excludes metal",constructionInput job,\st->st {storageResource=Just Stone})
        ,("wrong input capacity",constructionInput job,\st->st {storageCapacity=400001})
        ,("wrong escrow capacity",constructionEscrow job,\st->st {storageCapacity=20001})
        ,("foreign escrow colony",constructionEscrow job,\st->st {storageColony=baseForeign base})] $ \(label,owner,change)->invalid label job (inventory {invStorage=M.adjust change owner (invStorage inventory)}) spatial
  invented<-give (constructionInput job) [(Water,1,0,Nothing,"unrequested-water")] planned
  invalid "unrequested site material" (jobOf invented) (invOf invented) (spaceOf invented)
  overfull<-give (constructionInput job) [(Stone,10001,0,Nothing,"excess-stone")] planned
  invalid "site material exceeds cost" (jobOf overfull) (invOf overfull) (spaceOf overfull)
  invalid "pre-start progress is nonzero" (job {constructionProgress=1}) inventory spatial
  leftover<-give (constructionInput (jobOf running)) [(Stone,1,0,Nothing,"late-excess-input")] running
  invalid "running input retains material" (jobOf leftover) (invOf leftover) (spaceOf leftover)
  let forgedOrigin=job {constructionOrigin=S.Tile 60 60}
  invalid "return origin differs from authoritative shape" forgedOrigin inventory spatial
  -- Both mutable references forged together must still bind to an existing,
  -- compatible natural source, not simply agree with each other.
  let fake=EntityId 999999
      forgedSource=job {constructionSource=Just fake}
      forgedSpace=spatial {S.spatialPlacements=M.adjust (\p->p {S.placementSource=Just fake}) (constructionSiteId job) (S.spatialPlacements spatial)}
  invalid "job and placement share fictitious source" forgedSource inventory forgedSpace
  invalid "natural source physically removed" job (inventory {invDeposits=M.empty}) spatial
  zero<-must "depleted source quantity" (mkQty 0)
  let depleted=inventory {invDeposits=M.adjust (\deposit->deposit {depositQty=zero}) (baseSource base) (invDeposits inventory)}
  check checks "bound source depletion remains legitimate" (validateConstructionJob content depleted spatial job==Right ())
  let badState=ConstructionState (M.singleton (EntityId 999) job) M.empty
  check checks "construction map key not site rejects" (left (validateConstruction content inventory spatial badState))
  let dup=job {constructionSiteId=EntityId 999,constructionInput=Owner MachineInput (EntityId 999)}
  check checks "duplicate job identity rejects" (left (validateConstruction content inventory spatial (ConstructionState (M.fromList [(constructionSiteId job,job),(EntityId 999,dup)]) M.empty)))
  ((secondJob,secondSpace),secondInventory)<-must "second plan identity fixture" $ I.runInventory
    (placeConstruction content (SimTick 0) (baseColony base) roadShape 1 Nothing spatial) inventory
  let forgedJob=secondJob {constructionJobId=constructionSiteId job,constructionEscrow=Owner ConstructionEscrow (constructionSiteId job)}
      oldEscrow=constructionEscrow secondJob;newEscrow=constructionEscrow forgedJob
      forgedInventory=secondInventory {invStorage=M.insert newEscrow (invStorage secondInventory M.! oldEscrow) (M.delete oldEscrow (invStorage secondInventory))}
      collisionSpace=secondSpace {S.spatialOwnerLocations=M.insert newEscrow (S.spatialOwnerLocations secondSpace M.! oldEscrow) (M.delete oldEscrow (S.spatialOwnerLocations secondSpace))}
      collisionState=ConstructionState (M.fromList [(constructionSiteId job,job),(constructionSiteId forgedJob,forgedJob)]) M.empty
  check checks "cross-site job identity collision fixture passes generic inventory" (I.validateInventory forgedInventory==Right ())
  check checks "construction job cannot reuse another site's global ID" (left (validateConstruction content forgedInventory collisionSpace collisionState))
  putStrLn "TRANSITION adversarial validation IDs, storage schema, site material, source, catalog, placement and return origin checked"

rollbackTests :: Check -> Content -> IO ()
rollbackTests checks content=do
  base<-fixture content
  planned<-place content base roadShape
  funded<-fund planned
  running<-must "rollback running" (start content funded)
  check checks "stale cancel revision fails before state change" (step running (\job->cancelConstruction content (tx P1 1) (constructionRevision job-1) job)==Left (constructionFailure "StaleEntityRevision"))
  let atMax bundle=Bundle ((jobOf bundle) {constructionRevision=maxBound}) (spaceOf bundle) (invOf bundle)
  check checks "start revision overflow after material staging rolls back" (start content (atMax funded)==Left CounterOverflow)
  check checks "progress revision overflow rolls back" (advance content 1 (atMax running)==Left CounterOverflow)
  check checks "cancel revision overflow after losses/returns rolls back" (cancel content (atMax running)==Left CounterOverflow)
  let noIds=Bundle (jobOf funded) (spaceOf funded) ((invOf funded) {invNextId=maxBound})
  check checks "escrow split/reservation allocator overflow rolls back" (start content noIds==Left CounterOverflow)
  forM_ [maxBound,maxBound-1] $ \next->check checks "place site/job allocator overflow atomic" (left (I.runInventory (placeConstruction content (SimTick 0) (baseColony base) roadShape 1 Nothing (baseSpace base)) ((baseInventory base) {invNextId=next})))
  forM_ [-1,4] $ \priority->check checks "invalid priority rejected before allocation" (I.runInventory (placeConstruction content (SimTick 0) (baseColony base) roadShape priority Nothing (baseSpace base)) (baseInventory base)==Left InvalidQuantity)
  let nearComplete=Bundle ((jobOf running) {constructionProgress=1999}) (spaceOf running) ((invOf running) {invLedger=M.insert (Stone,ConstructionConsumed) quantityMax (invLedger (invOf running))})
  check checks "construction ledger overflow cannot partially complete" (advance content 1 nearComplete==Left InvalidQuantity)
  let blockedSpace=(spaceOf running) {S.spatialBlockingRevision=maxBound}
  check checks "completion spatial revision overflow restores consumed stock" (left (advance content 130 (Bundle ((jobOf running) {constructionProgress=1999}) blockedSpace (invOf running))))
  check checks "cancel spatial revision overflow restores loss" (left (cancel content (Bundle ((jobOf running) {constructionProgress=1000}) blockedSpace (invOf running))))
  (_,reservedInv)<-must "foreign quantity reservation" $ I.runInventory (do
    foreignJob<-I.freshId
    I.reserveQuantity (SimTick 0) foreignJob (constructionEscrow (jobOf running)) Stone 1500) (invOf running)
  check checks "foreign escrow claim prevents loss/return and rollback" (left (cancel content (Bundle ((jobOf running) {constructionProgress=1000}) (spaceOf running) reservedInv)))
  putStrLn "TRANSITION rollback staleRevision, job/ID/spatial/ledger overflow, foreign quantity/capacity claims; no partial commit exposed"

roundtripTests :: Check -> Content -> IO ()
roundtripTests checks content=do
  base<-fixture content
  planned<-place content base roadShape
  partial<-give (constructionInput (jobOf planned)) [(Stone,733,0,Nothing,"first-delivery")] planned
  completeInput<-give (constructionInput (jobOf planned)) [(Stone,1267,0,Nothing,"second-delivery")] partial
  running<-must "roundtrip start" (start content completeInput)
  (mid,_)<-must "roundtrip progress" (advance content 127 running)
  forM_ [planned,partial,completeInput,running,mid] $ \state->do
    restored<-maybe (ioError (userError "component Read failed")) pure (readMaybe (show state)::Maybe Bundle)
    check checks "component Show/Read retains exact state" (restored==state)
    check checks "component roundtrip cancel identical" (cancel content restored==cancel content state)
    check checks "component roundtrip next progress identical" (advance content 130 restored==advance content 130 state)
    check checks "component roundtrip start identical" (start content restored==start content state)
  -- Explicit order model only: P1 cancellation terminal makes later P4 arrival,
  -- P5 start and P7 completion illegal. No claim of real scheduler integration.
  cancelled<-must "P1 before arrival" (cancel content partial)
  let j=jobOf cancelled;i=invOf cancelled
  check checks "same boundary cancel->arrival->start->completion" (left (admitConstructionDelivery j Stone 1267 0 i) && start content cancelled==Left AlreadyTerminal && advance content 130 cancelled==Left AlreadyTerminal)
  -- If arrival happens at P4 without cancellation, P5 may transfer to escrow,
  -- and P7 has a strict per-tick work-credit limit.
  afterArrival<-must "P4 arrival then P5 start" (start content completeInput)
  (afterP7,_)<-must "P7 after P5" (advance content 100 afterArrival)
  check checks "arrival->start->progress ordered component composition" (constructionProgress (jobOf afterP7)==100 && physical (constructionEscrow (jobOf afterP7)) Stone (invOf afterP7)==2000)
  _<-evaluate (force (jobOf mid,spaceOf mid,invOf mid))
  putStrLn "TRANSITION component Read/Show resume at plan/partial/full/escrow/progress; ordered cancel-before-arrival/start/completion"
  putStrLn "SCOPE component only: transport World boundary, actual named crew, WorldV4 CBOR, Arena and UI need separate integration acceptance; Read/Show is not save-codec acceptance"

constructionTests :: Content -> IO ()
constructionTests content=do
  checks<-Check <$> newIORef 0 <*> newIORef []
  let groups=[("snapshots",snapshotTests checks content),("refund-oracle",refundTests checks),("admission",admissionTests checks content),("completion",completionTests checks content),("cancellation",cancellationTests checks content),("capacity",capacityTests checks content),("return-oracle",returnOracleTests checks content),("validation",validationTests checks content),("rollback",rollbackTests checks content),("component-roundtrip",roundtripTests checks content)]
  forM_ groups $ \(name,action)->do
    result<-try action :: IO (Either SomeException ())
    case result of Left err->check checks ("GROUP "++name++" aborted: "++show err) False;Right ()->pure ()
  let Check counter failures=checks
  count<-readIORef counter
  failed<-reverse <$> readIORef failures
  putStrLn ("CONSTRUCTION checks="++show count++" failed="++show (length failed))
  unless (null failed) exitFailure
  putStrLn "CONSTRUCTION PASS component/oracle suite; actual World integration is a separate gate"
main :: IO ()
main=loadContent "data/content-v1.json" >>= must "content" >>= constructionTests
