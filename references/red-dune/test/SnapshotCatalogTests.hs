module SnapshotCatalogTests(snapshotCatalogTests) where
import Colony.Codec
import Colony.Content
import Colony.ContentCodec
import Colony.Fixture
import Colony.Inventory
import Colony.Jobs
import Colony.Migrate
import Colony.Scheduler
import Colony.Types
import Colony.Units
import Colony.World
import Control.DeepSeq(force)
import Control.Exception(evaluate)
import Control.Monad(unless,foldM)
import qualified Data.ByteString as BS
import Data.Either(isLeft)
import qualified Data.Map.Strict as M

snapshotCatalogTests :: Content -> IO()
snapshotCatalogTests content=do
  digest<-right(contentIdentity content)
  assert "baseline catalog fingerprint is pinned"(digest==knownV1ContentId)
  base<-right(fourColonyFixture content)
  let kitchens=[siteId site|site<-M.elems(worldSites base),siteRecipe site=="cook"]
  running<-step[OrderProduction(head kitchens)]base
  let job=head(M.elems(worldJobs running));jid=jobId job
      snapshot=case jobRecipeSnapshot job of Just x->x;Nothing->error"test expected started snapshot"
      inv=worldInventory running
      fakeOutput=snapshot {recipeOutputs=M.adjust(+1)Ration(recipeOutputs snapshot)}
      capacity=head[r|r<-M.elems(invCapacity inv),capacityJob r==jid]
      enlarged=inv {invCapacity=M.adjust(\r->r {capacityWeight=capacityWeight r+1})(capacityReservationId capacity)(invCapacity inv)}
      forgedJob=job {jobRecipeSnapshot=Just fakeOutput}
      forged=running {worldInventory=enlarged,worldJobs=M.insert jid forgedJob(worldJobs running)}
  assert "self-consistent forged output passes old local checks"(validateInventory enlarged==Right()&&validateRunningJob forgedJob enlarged==Right())
  assert "same-ID forged output rejected by World/checkpoint"(isLeft(validateWorld forged)&&isLeft(encodeCheckpoint defaultCheckpointMeta forged))
  assert "direct complete rejects same-ID forged output"(isLeft(runInventory(completeJob content(TxId 1 1(BoundarySeq 9)P7 0)(SimTick 1200)(forgedJob {jobProgress=jobRequired forgedJob}))enlarged))
  (_,lessFuel)<-right(runInventory(moveFree(simTick running)(wipOwner job)(jobOutput job)Fuel 1)inv)
  let fakeInput=snapshot {recipeInputs=M.adjust(subtract 1)Fuel(recipeInputs snapshot)}
      forgedInput=job {jobRecipeSnapshot=Just fakeInput}
      tamperedInput=running {worldInventory=lessFuel,worldJobs=M.insert jid forgedInput(worldJobs running)}
  assert "self-consistent forged input passes old local checks"(validateInventory lessFuel==Right()&&validateRunningJob forgedInput lessFuel==Right())
  assert "catalog binding rejects forged input despite matching WIP"(isLeft(validateWorld tamperedInput)&&isLeft(encodeCheckpoint defaultCheckpointMeta tamperedInput))
  let unknown=running {worldJobs=M.adjust(\j->j {jobSnapshotContentId=Just(BS.replicate 32 0)})jid(worldJobs running)}
  assert "unknown32byte fingerprint is rejected"(isLeft(validateWorld unknown)&&isLeft(encodeCheckpoint defaultCheckpointMeta unknown))
  let native=boundary[SetSiteEnabled(head kitchens)False]forged
      (rolled,out)=pureStep native forged
  assert "P10 publishes no side effect on snapshot mismatch"(case worldMode rolled of Faulted _->rolled==forged {worldMode=worldMode rolled}&&null(outputEvents out)&&null(outputReceipts out);_->False)
  let changedGrow=(contentRecipes content M.!"grow"){recipeOutputs=M.adjust(+1)Crops(recipeOutputs(contentRecipes content M.!"grow"))}
      unsupported=content {contentRecipes=M.insert "grow" changedGrow(contentRecipes content)}
  assert "arbitrary self-consistent content is not an allowed catalog"(validateContent unsupported==Right()&&isLeft(validateWorld(base {worldContent=unsupported})))
  let cook=contentRecipes content M.!"cook"
      cookV2=cook {recipeInputs=M.insert Fuel 800(recipeInputs cook),recipeOutputs=M.insert Ration 19000(recipeOutputs cook)}
      v2=content {contentRecipes=M.insert "cook" cookV2(contentRecipes content)}
  v2digest<-right(contentIdentity v2)
  assert "declared v2 catalog fingerprint is pinned"(v2digest==knownV2ContentId)
  updated<-right(applyCookBalanceV2 2 v2 running)
  bytes<-right(encodeCheckpoint defaultCheckpointMeta updated)
  (_,restored)<-right(decodeCheckpoint bytes)
  assert "legitimate in-flight v1 snapshot survives ruleset1 checkpoint"(restored==updated&&jobSnapshotContentId(head(M.elems(worldJobs restored)))==Just knownV1ContentId)
  both<-step[OrderProduction(kitchens!!1)]restored
  end<-foldM(\w _->step[]w)both[1..1199::Integer]
  assert "both actual old/new batches complete"(all((==Completed).jobPhase)(M.elems(worldJobs end)))
  assert "actual old18000+new19000 outputs and1000+800 fuel"(M.lookup(Ration,RecipeOutput)(invLedger(worldInventory end))==Just 37000&&M.lookup(Fuel,RecipeInput)(invLedger(worldInventory end))==Just 1800)
  assert "both started content IDs retained"(map jobSnapshotContentId(M.elems(worldJobs end))==[Just knownV1ContentId,Just knownV2ContentId])
  assert "unknown ruleset is rejected"(isLeft(encodeCheckpoint defaultCheckpointMeta(end {worldRuleset="red-dune-reference-999"})))
  putStrLn "SnapshotCatalogTests PASS: pinned v1/v2 catalogs; self-consistent forged inputs/outputs, unknown hashes/catalogs/rulesets rejected; P10 rollback; legitimate old/new batches and checkpoint preserve both content IDs over1200 actual boundaries"
  where
    assert label condition=unless condition(ioError(userError label))
    right :: Show e => Either e a -> IO a
    right=either(ioError.userError.show)pure
    boundary bodies world=let epoch=participantEpoch(worldParticipants world M.!1);next=M.findWithDefault 0(1,epoch)(worldHighWater world)+1 in
      Boundary(BoundaryHeader(worldId world)(branchId world)(boundarySeq world)True(worldAuthority world)(worldRuleset world))
        [OrderedCommand ordinal(CommandId(worldId world)1 epoch(next+ordinal))body|(ordinal,body)<-zip[0..]bodies][]
    step bodies world=do
      (next,out)<-evaluate(force(pureStep(boundary bodies world)world))
      assert("unexpected snapshot diagnostic "++show(outputDiagnostics out))(null(outputDiagnostics out))
      pure next
