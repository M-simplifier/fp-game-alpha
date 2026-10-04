module PresentationTests(presentationTests) where
import Colony.Arena
import Colony.Codec
import Colony.Content
import Colony.Jobs
import Colony.Inventory
import Colony.Maintenance
import Colony.Types
import Colony.Units
import Colony.JSON
import Colony.Presentation
import Colony.RNG
import Colony.UIFixture
import Colony.UIShell(decodeUICommand)
import Colony.World
import Control.Monad (unless,forM_)
import qualified Data.Map.Strict as M
import Game.Arena(play,singleton)

presentationTests :: Content -> IO ()
presentationTests content=do
  (_,w)<-either(fail.show)pure(uiFixture content)
  let streams=initialRng 67890
      hidden=w {worldRng=streams {weatherRng=(weatherRng streams){rngDrawCount=12345}}}
  check "two-world projection ignores RNG state/seed/drawCount" (presentation w==presentation hidden)
  let encoded=encodeJSON(presentation w)
  check "projection JSON roundtrip" (parseJSON encoded==Right(presentation w))
  root<-either fail pure(object(presentation w))
  check "strict public top-level allowlist" (M.keys root==M.keys(M.fromList[(k,())|k<-["schema","world","branch","tick","boundary","revision","mode","weather","controller","epoch","nextSequence","scope","resources","colonies","sites","owners","roads","vehicles","jobs","deliveries","maintenance","receipts","events","consumed"]]))
  check "reject future target" (case decodeUICommand w(obj[("kind",str "produce"),("site",str "18446744073709551615")])of Left _->True;_->False)
  let input=RecordedBoundary(BoundaryHeader(worldId w)(branchId w)(boundarySeq w)False(worldAuthority w)(worldRuleset w))[][ResumeWorld]
  (start,_)<-either(fail.show)pure(play Colony input(singleton 1(OrderedBatch []))w)
  let go n current|n==0=Right current
                  |otherwise=do
                      let boundary=RecordedBoundary(BoundaryHeader(worldId current)(branchId current)(boundarySeq current)True(worldAuthority current)(worldRuleset current))[][]
                      (next,_)<-play Colony boundary(singleton 1(OrderedBatch []))current
                      go(n-1)next
      withProjection n current|n==0=Right current
                               |otherwise=length(encodeJSON(presentation current)) `seq` do
                                  let boundary=RecordedBoundary(BoundaryHeader(worldId current)(branchId current)(boundarySeq current)True(worldAuthority current)(worldRuleset current))[][]
                                  (next,_)<-play Colony boundary(singleton 1(OrderedBatch []))current
                                  withProjection(n-1)next
  a<-either(fail.show)pure(go(80::Integer)start)
  b<-either(fail.show)pure(withProjection(80::Integer)start)
  check "camera/renderer projection cannot change 80-boundary kernel hash" (canonicalStateHash a==canonicalStateHash b)
  -- Projected maintenance costs must match the exact core transaction, including
  -- integer rounding, rather than a hard-coded 50 percent explanation.
  let target=head[f|f<-M.elems(maintenanceFacilities(worldMaintenance w)),facilityPeriod f>0,M.member(facilityId f)(worldSites w)]
      site=worldSites w M.! facilityId target
      colony=storageColony(invStorage(worldInventory w) M.! siteInput site)
      source=head[o|o@(Owner Warehouse _)<-M.keys(invStorage(worldInventory w)),storageColony(invStorage(worldInventory w) M.! o)==colony]
  ((jobIdValue,planned),plannedInv)<-either(fail.show)pure(runInventory(planMaintenance content(simTick w)(facilityId target)source source(worldMaintenance w))(worldInventory w))
  (running,runningInv)<-either(fail.show)pure(runInventory(startMaintenance jobIdValue 1 planned)plannedInv)
  let runningJob=maintenanceJobs running M.! jobIdValue
      required=maintenanceRequired runningJob
      actual=sum[qtyValue(lotQty l)|l<-M.elems(invLots runningInv),lotOwner l==maintenanceWipOwner runningJob]
  forM_ [0,required `div` 4,required-1] $ \progress->do
    let currentJob=runningJob {maintenanceProgress=progress}
        currentState=running {maintenanceJobs=M.insert jobIdValue currentJob(maintenanceJobs running)}
        current=w {worldInventory=runningInv,worldMaintenance=currentState}
        projected=M.fromList(maintenanceCancellation current currentJob)
        expectedLoss=actual*progress `div` required
    check ("maintenance cancel projection progress "++show progress) (M.lookup "cancelLoss" projected==Just(num expectedLoss)&&M.lookup "cancelReturn" projected==Just(num(actual-expectedLoss)))
    (_,cancelledInv)<-either(fail.show)pure(runInventory(cancelMaintenance(TxId 1 1(BoundarySeq 0)P1 0)jobIdValue currentState)runningInv)
    let realLoss=M.findWithDefault 0(Parts,CancelledProcessLoss)(invLedger cancelledInv)-M.findWithDefault 0(Parts,CancelledProcessLoss)(invLedger runningInv)
    check "projected cost equals committed kernel cancellation loss" (M.lookup "cancelLoss" projected==Just(num realLoss))
  -- Legacy red-dune-reference-0 counterexample: this is compatibility evidence,
  -- not an assertion that per-lot rounding is the normative resource rule.
  let farm=head[s|s<-M.elems(worldSites w),siteRecipe s=="grow"]
      tx=TxId 1 1(BoundarySeq 0)P1 0
  (batch,batchInventory)<-either(fail.show)pure(runInventory (do
    _<-mintLot tx InitialGrant Nothing Water 1(siteInput farm)(SimTick 0)Nothing"rounding-test-small-lot"
    _<-mintLot tx InitialGrant Nothing Water 59999(siteInput farm)(SimTick 0)Nothing"rounding-test-large-lot"
    plannedBatch<-planJob content "grow"(siteInput farm)(siteOutput farm)M.empty
    startJob content(SimTick 0)plannedBatch) (worldInventory w))
  let progressed=batch {jobProgress=jobRequired batch `div` 4}
      batchWorld=w {worldInventory=batchInventory,worldJobs=M.insert(jobId batch)progressed(worldJobs w),worldJobSites=M.insert(jobId batch)(siteId farm)(worldJobSites w)}
      costs=M.fromList(productionCancellation batchWorld progressed)
  (_,afterBatchCancel)<-either(fail.show)pure(runInventory(cancelJob(worldRuleset batchWorld) tx progressed)batchInventory)
  let actualLoss=M.findWithDefault 0(Water,CancelledProcessLoss)(invLedger afterBatchCancel)-M.findWithDefault 0(Water,CancelledProcessLoss)(invLedger batchInventory)
  check "legacy profile split-lot compatibility counterexample" (worldRuleset batchWorld/="red-dune-reference-0" || actualLoss==14999)
  check "corrected profile split-lot resource aggregate" (worldRuleset batchWorld `notElem` ["red-dune-reference-2","red-dune-reference-4"] || actualLoss==15000)
  check "production cost equals selected-profile core cancellation" (M.lookup "cancelLoss" costs==Just(arr[obj[("resource",str "water"),("quantity",num actualLoss)]]))
  putStrLn("presentation: PASS exact production cancellation matches selected profile "++worldRuleset batchWorld++"; split-lot loss="++show actualLoss++"; resource aggregate oracle=15000 (normative corrected profile)")
  uiSource<-readFile "ui/app.js"
  shellSource<-readFile "src/Colony/UIShell.hs"
  check "fixed-50-percent maintenance message is prohibited" (not(any (`contains` (uiSource++shellSource))["部品50%","部品の50%","部品50％","部品の50％"]))
  putStrLn "presentation: PASS maintenance exact cancel loss/return at0%,25%,near-complete; same-core comparison; stale50-percent copy guard"
  putStrLn "presentation: PASS public allowlist; RNG two-world; JSON lossless; future target rejected; renderer-independent replay"
  where
    check label condition=unless condition(fail label)
    contains needle haystack=any(\suffix->take(length needle)suffix==needle)(tails haystack)
    tails []=[[]]
    tails xs@(_:rest)=xs:tails rest
