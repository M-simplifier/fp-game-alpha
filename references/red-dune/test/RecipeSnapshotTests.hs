module RecipeSnapshotTests(recipeSnapshotTests) where
import Colony.Content
import Colony.Codec(contentHash)
import Colony.Inventory
import Colony.Jobs
import Colony.Types
import Colony.Units
import Control.Monad(unless)
import qualified Data.Map.Strict as M

recipeSnapshotTests :: Content -> IO()
recipeSnapshotTests content=do
  let oldRecipe=contentRecipes content M.! "cook"
      newRecipe=oldRecipe {recipeInputs=M.insert Fuel 800(recipeInputs oldRecipe),recipeOutputs=M.insert Ration 19000(recipeOutputs oldRecipe)}
      patched=content {contentRecipes=M.insert "cook" newRecipe(contentRecipes content)}
      input=Owner MachineInput(EntityId 1);output=Owner MachineOutput(EntityId 1)
      tx=TxId 1 1(BoundarySeq 1)P5 0
      fixture=do
        addStorage input(Storage 400000 Nothing(EntityId 2))
        addStorage output(Storage 400000 Nothing(EntityId 2))
        mapM_(\(r,n)->mintLot tx InitialGrant Nothing r n input(SimTick 0)(if r==Crops then Just(SimTick 144000) else Nothing)"fixture" >> pure())[(Crops,20000),(Water,10000),(Fuel,1000)]
        planJob content "cook" input output M.empty
  (planned,inventory)<-right(runInventory fixture(emptyInventory content))
  (started,wip)<-right(runInventory(startJob content(SimTick 1)planned)inventory)
  oldHash<-right(contentHash content)
  newHash<-right(contentHash patched)
  assert "start snapshot uses canonical content ID"(jobSnapshotContentId started==Just oldHash&&oldHash/=newHash)
  (completed,after)<-right(runInventory(completeJob patched tx(SimTick 1200)(started {jobProgress=jobRequired started}))wip)
  assert "running recipe completes original snapshot after content patch"(jobPhase completed==Completed&&M.lookup(Ration,RecipeOutput)(invLedger after)==Just 18000&&M.lookup(Fuel,RecipeInput)(invLedger after)==Just 1000)
  (newStarted,newWip)<-right(runInventory(startJob patched(SimTick 1)planned)inventory)
  assert "new start captures changed content ID"(jobSnapshotContentId newStarted==Just newHash)
  (_,newAfter)<-right(runInventory(completeJob patched tx(SimTick 1200)(newStarted {jobProgress=jobRequired newStarted}))newWip)
  assert "planned recipe starts using new content"(M.lookup(Ration,RecipeOutput)(invLedger newAfter)==Just 19000&&M.lookup(Fuel,RecipeInput)(invLedger newAfter)==Just 800)
  let naturalFixture=do
        addStorage input(Storage 400000 Nothing(EntityId 2))
        addStorage output(Storage 400000 Nothing(EntityId 2))
        wrong<-addDeposit "ore_deposit" Ore 500000
        planJob content "hand_water" input output(M.singleton "aquifer" wrong)
  (natural,stock)<-right(runInventory naturalFixture(emptyInventory content))
  assert "mismatched deposit kind cannot reserve or extract"(case runInventory(startJob content(SimTick 1)natural)stock of Left(InvalidReference _)->True;_->False)
  putStrLn "RecipeSnapshotTests PASS: in-flight recipe preserved across balance patch, planned recipe picks new version, wrong deposit kind rejected atomically"
  where
    assert label condition=unless condition(ioError(userError label))
    right :: Show e => Either e a -> IO a
    right=either(ioError.userError.show)pure
