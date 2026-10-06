{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Colony.Types
import Colony.World
import Control.Exception (IOException, try)
import Control.Monad (foldM, unless)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as M
import RedDune.Game
import RedDune.GameSave
import RedDune.Native.Play
import RedDune.Native.Store qualified as Store
import RedDune.ContentPack
import System.Directory
import System.Environment
import System.FilePath

must :: Either String a -> IO a
must=either (ioError.userError) pure
check :: String -> Bool -> IO ()
check label ok=unless ok (ioError (userError label))

main :: IO ()
main=do
  args<-getArgs
  root<-case args of [path]->makeAbsolute path; _->ioError (userError "Pass a fresh test directory")
  exists<-doesPathExist root
  check "test directory must be fresh" (not exists)
  original<-must (startGame "settlement" defaultPack)
  setup<-foldM (\game dept->must (decide (Commission dept) game)) original [WaterWorks,FoodWorks,ServiceWorks]
  check "commissioning does not create resources" (invLots (worldInventory (gameWorld original))==invLots (worldInventory (gameWorld setup)))
  check "commissioning does not advance time" (simTick (gameWorld original)==simTick (gameWorld setup))
  active<-must (decide ToggleTime setup)
  played<-must (advanceGame 1200 active)
  Store.withStore root $ \store->do
    collision<-try (Store.withStore root (const (pure ()))) :: IO (Either IOException ())
    check "exclusive process lock" (case collision of Left _->True; _->False)
    activated<-Store.activateGame store played
    check "fresh paused authority" (worldAuthority (gameWorld activated)/=worldAuthority (gameWorld played) && worldMode (gameWorld activated)==Paused)
    first<-Store.saveGame store activated
    preview<-Store.previewCheckpoint store first
    check "exact preview" (Store.previewGame preview==activated)
    restored<-Store.confirmCheckpoint store preview
    check "fresh branch on confirmation" (branchId (gameWorld restored)>branchId (gameWorld activated))
    source<-BS.readFile (root </> first)
    check "source survives confirmation" (decodeGame source==Right activated)
    a<-must (decide ToggleTime activated) >>= must.advanceGame 200
    b<-must (decide ToggleTime restored) >>= must.advanceGame 200
    let stockView world=M.map (\lot->(lotOwner lot,lotResource lot,lotQty lot,lotBorn lot,lotExpires lot,lotProvenance lot)) (invLots (worldInventory world))
    check "restored physical suffix" (stockView (gameWorld a)==stockView (gameWorld b) && invLedger (worldInventory (gameWorld a))==invLedger (worldInventory (gameWorld b)) && worldJobs (gameWorld a)==worldJobs (gameWorld b) && worldNeeds (gameWorld a)==worldNeeds (gameWorld b) && simTick (gameWorld a)==simTick (gameWorld b))
    originalBytes<-BS.readFile (root </> first)
    BS.writeFile (root </> first) (BS.take 80 originalBytes)
    rejected<-try (Store.confirmCheckpoint store preview) :: IO (Either IOException GameState)
    check "changed preview rejected" (case rejected of Left _->True; _->False)
    BS.writeFile (root </> first) originalBytes
    catalog<-Store.checkpoints store
    check "immutable saves listed" (length catalog>=3)
    traversal<-try (Store.previewCheckpoint store "../escape.rdlive") :: IO (Either IOException Store.Preview)
    check "traversal rejected" (case traversal of Left _->True; _->False)
    renamed<-try (renameDirectory root (root++"-moved")) :: IO (Either IOException ())
    check "directory identity pinned" (case renamed of Left _->True; _->False)
  -- A process restart reacquires the lock and reads already committed saves.
  Store.withStore root $ \store->Store.checkpoints store >>= check "restart catalog" . (>=3).length
  putStrLn "PASS native: physical commissioning, paused activation, exact readback, immutable branch restore, stale-preview rejection, locking, traversal, directory pinning, restart"
