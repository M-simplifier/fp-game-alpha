module BranchWriteTests(branchWriteTests) where
import Colony.CheckpointLibrary
import Colony.Codec
import Colony.Content
import Colony.Fixture
import Colony.Save
import Colony.Types
import Colony.World
import Control.Exception(bracket)
import Control.Monad(unless,void)
import qualified Data.ByteString as BS
import Data.Either(isLeft)
import System.Directory(createDirectory,listDirectory,removeFile,removePathForcibly,renameDirectory,makeAbsolute)
import System.FilePath((</>))
import System.IO(hClose,openBinaryTempFile)
import System.Posix.Files(createSymbolicLink)

assert :: String -> Bool -> IO()
assert label condition=unless condition(fail("BranchWrite: "++label))
right :: Show e=>Either e a->IO a
right=either(fail.show)pure

branchWriteTests :: Content -> IO()
branchWriteTests content=bracket fresh removePathForcibly $ \root->do
  initial<-right(fourColonyFixture content)
  let config=LibraryConfig(root </> "controlled")Nothing Nothing
      wid=worldId initial
      saveIn directory branch=do
        let world=initial{branchId=branch};identity=identityFor(Epoch "branch-writer-fixture" 1)world
        snapshot<-right(captureSnapshot(SaveTicket identity 1 ManualSave)(CheckpointMeta 1 Nothing "branch-writer-fixture")world)
        adapter<-nativeAdapter
        result<-nativeSave adapter directory(pure identity)snapshot
        void(right(saveCompletion result))
      outside=root </> "outside";untouched=outside </> "existing-user-like-file"
  createDirectory outside
  BS.writeFile untouched(BS.pack[1,2,3,4])
  (first,path)<-reserveBranch config wid 0 >>= right
  void(withBranchDirectory config wid first(\p->saveIn p first) >>= right)
  recovered<-recoverCheckpoints path
  assert "real native commit through pinned writer"(length(recoveryCommitted recovered)==1)
  let original=path++"-original"
  renameDirectory path original
  createSymbolicLink outside path
  refused<-withBranchDirectory config wid first(\p->saveIn p first)
  assert "branch symlink rejected before any callback write"(isLeft refused)
  names<-listDirectory outside
  assert "branch rejection leaves external target untouched"(names==["existing-user-like-file"])
  removeFile path
  renameDirectory original path
  let worldPath=libraryRoot config </> ("world-"++show wid);moved=worldPath++"-original"
  renameDirectory worldPath moved
  createSymbolicLink outside worldPath
  refusedParent<-withBranchDirectory config wid first(\p->saveIn p first)
  assert "parent symlink rejected before callback"(isLeft refusedParent)
  removeFile worldPath
  renameDirectory moved worldPath
  (second,path2)<-reserveBranch config wid first >>= right
  let held=path2++"-held"
  pinned<-withBranchDirectory config wid second $ \p->do
    renameDirectory path2 held
    createSymbolicLink outside path2
    saveIn p second
  void(right pinned)
  pinnedRecovery<-recoverCheckpoints held
  assert "concurrent path replacement cannot redirect pinned writer"(length(recoveryCommitted pinnedRecovery)==1)
  after<-BS.readFile untouched
  finalNames<-listDirectory outside
  assert "pinned writer did not mutate replacement target"(after==BS.pack[1,2,3,4]&&finalNames==["existing-user-like-file"])
  removeFile path2
  renameDirectory held path2
  traversal<-withBranchDirectory config{libraryRoot=libraryRoot config </> ".."}wid first(\_ -> fail "traversal callback ran")
  assert "writer refuses traversal config"(isLeft traversal)
  putStrLn "BranchWriteTests PASS: actual native commit/readback; branch/parent symlink rejection; post-pin rename/replacement stays on original inode; external fixture bytes untouched; traversal rejected"
  where
    fresh=do
      (path,handle)<-openBinaryTempFile "." ".branch-writer-fixture-"
      hClose handle;removeFile path;createDirectory path;makeAbsolute path
