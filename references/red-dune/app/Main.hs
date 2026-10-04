module Main(main) where
import Colony.UIShell (runUIShell)
import Colony.Arena
import Colony.Codec
import Colony.Content
import Colony.Fixture
import Colony.Jobs
import Colony.Needs
import Colony.Scheduler
import Colony.Types
import Colony.Units
import Colony.World
import M1Tests(m1Tests)
import ContentTests
import CancellationProfileTests
import ReturnPlacementTests
import CombinedInterruptionTests
import CodecTests
import InventoryTests
import PowerNeedsTests
import SchedulerTests
import RecipeSnapshotTests
import IntegrityTests
import SaveTests
import MaintenanceTests
import MaintenanceLocationTests
import MaintenanceIntegrationTests
import TransportTests
import PresentationTests
import SnapshotCatalogTests
import SupplyChainTests
import MigrationTests
import SessionTests
import CheckpointLibraryTests
import BranchWriteTests
import Control.DeepSeq(force)
import Control.Exception(evaluate)
import Control.Monad(unless)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as M
import Data.List(sort)
import Data.Word(Word64)
import GHC.Clock(getMonotonicTimeNSec)
import GHC.Stats(getRTSStats,getRTSStatsEnabled)
import Game.Arena(observe)
import System.Environment(getArgs)
import System.Exit(die)
import System.Directory(createDirectoryIfMissing)

main :: IO()
main=do
  args<-getArgs
  content<-loadContent "data/content-v1.json" >>= either die pure
  case args of
    ["ui-shell"]->runUIShell content
    ["test"]->contentTests content >> inventoryTests content >> schedulerTests content >> powerNeedsTests content >> codecTests content >> recipeSnapshotTests content >> integrityTests content >> saveTests content >> maintenanceTests content >> maintenanceIntegrationTests content >> maintenanceLocationTests content >> transportTests content >> migrationTests content >> supplyChainTests content >> snapshotCatalogTests content >> presentationTests content >> cancellationProfileTests content >> returnPlacementTests content >> combinedInterruptionTests content >> sessionTests content >> checkpointLibraryTests content >> branchWriteTests content >> m1Tests content
    ["test-m1"]->m1Tests content
    ["test-session"]->sessionTests content >> checkpointLibraryTests content >> branchWriteTests content
    ["demo"]->runFixture False 10000 content
    ["bench"]->runFixture True 10000 content
    ["bench",n]->case reads n of [(count,"")]|count>0&&count<=1000000->runFixture True count content;_->die "bench count must be 1..1,000,000"
    _->putStrLn "Red Dune Federation reference foundation. Commands: test | test-m1 | demo | bench [ticks] | ui-shell. This is not a completed M1 or campaign build."

header :: World -> BoundaryHeader
header w=BoundaryHeader(worldId w)(branchId w)(boundarySeq w)True(worldAuthority w)(worldRuleset w)

runFixture :: Bool -> Word64 -> Content -> IO()
runFixture benchmark count content=do
  createDirectoryIfMissing True "evidence/generated"
  initial<-either (die.show) pure(fourColonyFixture content)
  (end,timings,events)<-loop initial 0 [] 0
  putStrLn("fixture=explicit-four-colony-subsystems ticks="++show(simTick end)++" events="++show events++" sites="++show(M.size(worldSites end))++" residents="++show(M.size(needsResidents(worldNeeds end))))
  putStrLn("jobs="++show[(jobId j,jobRecipe j,jobPhase j,jobBlocked j)|j<-M.elems(worldJobs end)])
  putStrLn("quantity totals="++show(M.toList(M.fromListWith(+)[(lotResource l,qtyValue(lotQty l))|l<-M.elems(invLots(worldInventory end))])))
  payload<-either (die.show) pure(encodeCheckpoint defaultCheckpointMeta end)
  BS.writeFile "evidence/generated/foundation-checkpoint.cbor" payload
  decoded<-either(die.show)pure(decodeCheckpoint payload)
  unless(snd decoded==end)(die "checkpoint readback differed")
  stateHash<-either(die.show)pure(canonicalStateHash end)
  putStrLn("canonical state SHA256="++hex stateHash++" checkpoint bytes="++show(BS.length payload))
  writeFile "evidence/generated/foundation-view.txt"(show(observe Colony 1 end))
  if benchmark then do
    let ordered=sort timings
        percentile n=ordered!!min(length ordered-1)(length ordered*n `div` 100)
    writeFile "evidence/generated/tick-times-ns.csv"("tick,elapsed_ns\n"++concat[show n++","++show t++"\n"|(n,t)<-zip[1::Integer ..](reverse timings)])
    putStrLn("observed force-included nanoseconds: p50="++show(percentile 50)++" p95="++show(percentile 95)++" p99="++show(percentile 99)++" max="++show(maximum ordered))
    enabled<-getRTSStatsEnabled
    if enabled then getRTSStats >>= print else putStrLn "RTS stats disabled; run +RTS -T -s"
    putStrLn "Scope: 4 colonies/40 residents/12 jobs, synthetic fixed input stores. Not D2, no renderer, no required 10-minute warmup/30-minute measurement x3, not a performance guarantee."
    else pure()
  where
    loop w n samples events
      | n>=count=pure(w,samples,events)
      | otherwise=do
        let commands=if n==0 then fixtureOrders w else []
        started<-getMonotonicTimeNSec
        (next,out)<-evaluate(force(pureStep(Boundary(header w)commands[])w))
        ended<-getMonotonicTimeNSec
        unless(null(outputDiagnostics out))(die(show(outputDiagnostics out)))
        loop next(n+1)((ended-started):samples)(events+toInteger(length(outputEvents out)))
    hex=concatMap(\b->[digits!!fromIntegral(b `div` 16),digits!!fromIntegral(b `mod` 16)]).BS.unpack
    digits="0123456789abcdef"
