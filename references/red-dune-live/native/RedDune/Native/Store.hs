{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- Immutable native checkpoints use the existing framed GameSave codec.
-- Windows owns the ancestor pins, exclusive process lock and write-through
-- rename. Nothing becomes visible before exact readback and game validation.
module RedDune.Native.Store
  ( Store,
    Checkpoint (..),
    Catalog (..),
    Preview,
    previewGame,
    previewName,
    withStore,
    storeRoot,
    saveGame,
    checkpoints,
    checkpointCatalog,
    latestCheckpointCatalog,
    checkpointPage,
    previewCheckpoint,
    confirmCheckpoint,
    prepareGame,
    activateGame,
    showNativeError,
  )
where

import Colony.Session
import Colony.World
import Control.Exception (IOException, bracket, finally, try)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List (sortOn, stripPrefix)
import Data.Word (Word64, Word8)
import Foreign (Ptr, alloca, castPtr, nullPtr, peek)
import Foreign.C
import RedDune.Campaign
import RedDune.ContentPack
import RedDune.Game hiding (previewGame)
import RedDune.GameSave
import System.Directory (listDirectory, makeAbsolute)
import System.FilePath (dropExtension, splitDirectories, takeExtension)
import Text.Read (readMaybe)

data Store = Store {storeRoot :: !FilePath, storeHandle :: !(Ptr ()), storeFactory :: !AuthorityFactory}

data Checkpoint = Checkpoint {checkpointName :: !String, checkpointBranch :: !Word64, checkpointSequence :: !Word64, checkpointHour :: !Integer, checkpointScenario :: !String} deriving (Eq, Show)

data Catalog = Catalog {catalogEntries :: ![Checkpoint], catalogUnreadable :: !Int, catalogTotal :: !Int} deriving (Eq, Show)

data Preview = Preview {previewName :: !String, previewBytes :: !BS.ByteString, previewGame :: !GameState}

foreign import ccall unsafe "rd_store_open" openStore :: CWString -> IO (Ptr ())

foreign import ccall unsafe "rd_store_close" closeStore :: Ptr () -> IO ()

foreign import ccall unsafe "rd_store_write" writeStore :: Ptr () -> CString -> Ptr Word8 -> CULong -> IO CInt

foreign import ccall unsafe "rd_store_read" readStore :: Ptr () -> CString -> Ptr (Ptr Word8) -> Ptr CULong -> IO CInt

foreign import ccall unsafe "rd_store_commit" commitStore :: Ptr () -> CString -> CString -> IO CInt

foreign import ccall unsafe "rd_store_error" storeError :: IO CULong

foreign import ccall unsafe "rd_store_free" freeStore :: Ptr a -> IO ()

foreign import ccall safe "rd_native_error" nativeError :: CWString -> IO ()

showNativeError :: String -> IO ()
showNativeError message = withCWString message nativeError

must :: Either String a -> IO a
must = either (ioError . userError) pure

require :: Bool -> String -> IO ()
require ok label = unless ok (ioError (userError label))

checkResult :: CInt -> String -> IO ()
checkResult result label = unless (result /= 0) $ do
  code <- storeError
  ioError (userError (label ++ " (Windows " ++ show code ++ ")"))

withStore :: FilePath -> (Store -> IO a) -> IO a
withStore path action = do
  require (not (null path) && '\0' `notElem` path && ".." `notElem` splitDirectories path) "Invalid save directory"
  absolute <- makeAbsolute path
  bracket
    (withCWString absolute openStore >>= \p -> if p == nullPtr then storeError >>= \e -> ioError (userError ("Cannot lock save directory (Windows " ++ show e ++ ")")) else pure p)
    closeStore
    $ \pointer -> do
      factory <- newAuthorityFactory
      action (Store absolute pointer factory)

readBytes :: Store -> String -> IO BS.ByteString
readBytes store name = withCString name $ \filename -> alloca $ \bytes -> alloca $ \size -> do
  readStore (storeHandle store) filename bytes size >>= (`checkResult` "Checkpoint read failed")
  pointer <- peek bytes
  count <- peek size
  BS.packCStringLen (castPtr pointer, fromIntegral count) `finally` freeStore pointer

writeBytes :: Store -> String -> BS.ByteString -> IO ()
writeBytes store name bytes = withCString name $ \filename -> BS.useAsCStringLen bytes $ \(pointer, count) ->
  writeStore (storeHandle store) filename (castPtr pointer) (fromIntegral count) >>= (`checkResult` "Checkpoint write failed")

reserveBranch :: Store -> Word64 -> IO Word64
reserveBranch store sourceBranch = do
  names <- listDirectory (storeRoot store)
  let found =
        ( [n | name <- names, Just tailName <- [stripPrefix "branch-" name], Just n <- [readMaybe (takeWhile (/= '.') tailName)]]
            ++ [n | name <- names, Just tailName <- [stripPrefix "b-" name], Just n <- [readMaybe (takeWhile (/= '-') tailName)]]
        ) ::
          [Word64]
      highest = maximum (sourceBranch : found)
  require (highest < maxBound) "Save branch counter exhausted"
  let branch = highest + 1
  writeBytes store ("branch-" ++ show branch ++ ".reserve") (BS.pack [82, 68, 66, 82, 65, 78, 67, 72])
  pure branch

prepareGame :: Store -> GameState -> IO GameState
prepareGame store game = do
  branch <- reserveBranch store (branchId (gameWorld game))
  session <- newSession (storeFactory store) (worldAuthorities (gameWorld game)) >>= either (ioError . userError . show) pure
  candidate <- must (reidentifyGameToBranch (sessionAuthority session) branch game)
  pure candidate

activateGame :: Store -> GameState -> IO GameState
activateGame store game = do
  candidate <- prepareGame store game
  _ <- saveGame store candidate
  pure candidate

saveGame :: Store -> GameState -> IO String
saveGame store game = do
  bytes <- must (encodeGame game)
  names <- listDirectory (storeRoot store)
  let prefix = "b-" ++ show (branchId (gameWorld game)) ++ "-s-"
      found = [n | name <- names, Just suffix <- [stripPrefix prefix name], Just n <- [readMaybe (takeWhile (/= '.') suffix)]] :: [Word64]
      highest = maximum (0 : found)
  require (highest < maxBound) "Checkpoint sequence exhausted"
  let basename = prefix ++ show (highest + 1)
      temporary = basename ++ ".pending"
      final = basename ++ ".rdlive"
  writeBytes store temporary bytes
  readback <- readBytes store temporary
  require (readback == bytes) "Checkpoint readback differs"
  decoded <- must (decodeGame readback)
  require (decoded == game) "Checkpoint state differs"
  withCString temporary $ \a -> withCString final $ \b -> commitStore (storeHandle store) a b >>= (`checkResult` "Checkpoint commit failed")
  committed <- readBytes store final
  require (committed == bytes) "Committed checkpoint differs"
  _ <- must (decodeGame committed)
  pure final

checkpoints :: Store -> IO [Checkpoint]
checkpoints store = catalogEntries <$> checkpointCatalog store

checkpointCatalog :: Store -> IO Catalog
checkpointCatalog store = checkpointNames store >>= \names -> readCatalog store (length names) names

-- Ordinary startup validates only the latest healthy save. The library
-- validates seven selected candidates per page, so every old save remains
-- accessible without decoding the entire immutable history on each launch.
latestCheckpointCatalog :: Store -> IO Catalog
latestCheckpointCatalog store = do
  names <- checkpointNames store
  let findHealthy skipped [] = pure (Catalog [] skipped (length names))
      findHealthy skipped (name : rest) = do
        result <- try (checkpointEntry store name) :: IO (Either IOException Checkpoint)
        case result of
          Right checkpoint -> pure (Catalog [checkpoint] skipped (length names))
          Left _ -> findHealthy (skipped + 1) rest
  findHealthy 0 names

checkpointPage :: Store -> Int -> IO Catalog
checkpointPage store page = do
  names <- checkpointNames store
  readCatalog store (length names) (take 7 (drop (max 0 page * 7) names))

checkpointNames :: Store -> IO [String]
checkpointNames store = reverse . sortOn filenameOrder . filter ((== ".rdlive") . takeExtension) <$> listDirectory (storeRoot store)

readCatalog :: Store -> Int -> [String] -> IO Catalog
readCatalog store total names = do
  results <- mapM (try . checkpointEntry store) names :: IO [Either IOException Checkpoint]
  pure (Catalog [checkpoint | Right checkpoint <- results] (length [() | Left _ <- results]) total)

checkpointEntry :: Store -> String -> IO Checkpoint
checkpointEntry store name = do
  game <- readBytes store name >>= must . decodeGame
  let (namedBranch, sequenceNumber, _) = filenameOrder name
  require (namedBranch == 0 || namedBranch == branchId (gameWorld game)) "Checkpoint branch and filename differ"
  pure (Checkpoint name (branchId (gameWorld game)) sequenceNumber (elapsedTicks (gameWorld game) (gameCampaign game) `div` 1200) (scenarioId (campaignScenario (gameCampaign game))))

filenameOrder :: String -> (Word64, Word64, String)
filenameOrder name = case stripPrefix "b-" (dropExtension name) of
  Just rest ->
    let (branchText, suffix) = break (== '-') rest
     in case (readMaybe branchText, stripPrefix "-s-" suffix >>= readMaybe) of
          (Just branch, Just sequenceNumber) -> (branch, sequenceNumber, name)
          _ -> (0, 0, name)
  Nothing -> (0, 0, name)

previewCheckpoint :: Store -> String -> IO Preview
previewCheckpoint store name = do
  require (takeExtension name == ".rdlive") "Select a live checkpoint"
  bytes <- readBytes store name
  game <- must (decodeGame bytes)
  pure (Preview name bytes game)

confirmCheckpoint :: Store -> Preview -> IO GameState
confirmCheckpoint store preview = do
  current <- readBytes store (previewName preview)
  require (current == previewBytes preview) "Checkpoint changed after preview; select it again"
  _ <- must (decodeGame current)
  activateGame store (previewGame preview)
