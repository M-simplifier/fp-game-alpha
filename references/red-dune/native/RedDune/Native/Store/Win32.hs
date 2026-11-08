{-# LANGUAGE ForeignFunctionInterface #-}

module RedDune.Native.Store.Win32
  ( PinnedStore,
    withPinnedStore,
    pinnedRoot,
    listLeaves,
    writeLeaf,
    readCheckpoint,
    readPreferences,
    commitCheckpoint,
    replacePreferences,
    showError,
  )
where

import Control.Concurrent (runInBoundThread)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (bracket, finally, onException, uninterruptibleMask_)
import Control.Monad (unless, void, when)
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Internal qualified as BSI
import Data.Int (Int32, Int64)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf16LE, encodeUtf16LE)
import Data.Word (Word16, Word32, Word8)
import Foreign
  ( Ptr,
    alloca,
    allocaArray,
    allocaBytesAligned,
    castPtr,
    intPtrToPtr,
    nullPtr,
    peek,
    peekByteOff,
    plusPtr,
  )
import System.Directory (listDirectory)
import System.FilePath (dropTrailingPathSeparator, splitDirectories, splitDrive, (</>))

type Handle = Ptr ()

type Wide = Ptr Word16

type Dword = Word32

type Bool32 = Int32

data PinnedStore = PinnedStore !FilePath !(MVar Bool)

pinnedRoot :: PinnedStore -> FilePath
pinnedRoot (PinnedStore root _) = root

foreign import ccall safe "GetFullPathNameW"
  getFullPathName :: Wide -> Dword -> Wide -> Ptr Wide -> IO Dword

foreign import ccall safe "CreateFileW"
  createFile :: Wide -> Dword -> Dword -> Ptr () -> Dword -> Dword -> Handle -> IO Handle

foreign import ccall safe "CreateDirectoryW"
  createDirectory :: Wide -> Ptr () -> IO Bool32

foreign import ccall unsafe "CloseHandle"
  closeHandle :: Handle -> IO Bool32

foreign import ccall safe "GetFileInformationByHandle"
  fileInformation :: Handle -> Ptr () -> IO Bool32

foreign import ccall safe "GetFileAttributesW"
  fileAttributes :: Wide -> IO Dword

foreign import ccall safe "GetFileSizeEx"
  fileSize :: Handle -> Ptr Int64 -> IO Bool32

foreign import ccall safe "ReadFile"
  readFileBytes :: Handle -> Ptr Word8 -> Dword -> Ptr Dword -> Ptr () -> IO Bool32

foreign import ccall safe "WriteFile"
  writeFileBytes :: Handle -> Ptr Word8 -> Dword -> Ptr Dword -> Ptr () -> IO Bool32

foreign import ccall safe "FlushFileBuffers"
  flushFile :: Handle -> IO Bool32

foreign import ccall safe "MoveFileExW"
  moveFile :: Wide -> Wide -> Dword -> IO Bool32

foreign import ccall unsafe "GetLastError"
  lastError :: IO Dword

foreign import ccall safe "MessageBoxW"
  messageBox :: Handle -> Wide -> Wide -> Dword -> IO Int32

invalidHandle :: Handle
invalidHandle = intPtrToPtr (-1)

readAttributes, genericRead, genericWrite, shareRead, shareWrite :: Dword
readAttributes = 0x0080
genericRead = 0x80000000
genericWrite = 0x40000000
shareRead = 1
shareWrite = 2

createNew, openExisting, openAlways, openReparse, backupSemantics, writeThrough :: Dword
createNew = 1
openExisting = 3
openAlways = 4
openReparse = 0x00200000
backupSemantics = 0x02000000
writeThrough = 0x80000000

directoryAttribute, reparseAttribute, renameWriteThrough, replaceExisting :: Dword
directoryAttribute = 0x0010
reparseAttribute = 0x0400
renameWriteThrough = 0x0008
replaceExisting = 0x0001

withWide :: String -> (Wide -> IO a) -> IO a
withWide value action =
  let bytes = encodeUtf16LE (Text.pack value) <> BS.pack [0, 0]
   in BS.useAsCString bytes (action . castPtr)

winError :: String -> Dword -> IO a
winError label code = ioError (userError (label ++ " (Windows " ++ show code ++ ")"))

check :: String -> IO Bool32 -> IO ()
check label action = do
  result <- action
  when (result == 0) (lastError >>= winError label)

require :: Bool -> String -> IO ()
require valid label = unless valid (ioError (userError label))

normalizedPath :: FilePath -> IO FilePath
normalizedPath path = withWide path $ \name -> allocaArray 32768 $ \buffer -> do
  size <- getFullPathName name 32768 buffer nullPtr
  when (size == 0) (lastError >>= winError "Cannot resolve save directory")
  require (size >= 3 && size < 32700) "Invalid save directory length"
  bytes <- BS.packCStringLen (castPtr buffer, fromIntegral size * 2)
  let full = Text.unpack (decodeUtf16LE bytes)
  case full of
    _ : ':' : '\\' : _ -> pure (dropTrailingPathSeparator full)
    _ -> ioError (userError "Save directory must begin with a drive letter")

withPinnedStore :: FilePath -> (PinnedStore -> IO a) -> IO a
withPinnedStore path action = runInBoundThread $ do
  root <- normalizedPath path
  let (drive, relative) = splitDrive root
      ancestors = scanl (</>) drive (splitDirectories relative)
  require (length ancestors <= 129) "Too many save directory ancestors"
  withAncestors ancestors $ do
    lockPath <- leafPath root "session.lock"
    bracket (openRegular lockPath (genericRead .|. genericWrite) 0 openAlways (openReparse .|. writeThrough)) release $ \_ -> do
      active <- newMVar True
      -- A closing scope waits for in-flight reads or writes before it releases
      -- the pins. An escaped handle cannot operate on the now-unpinned path.
      action (PinnedStore root active) `finally` uninterruptibleMask_ (modifyMVar_ active (const (pure False)))
  where
    withAncestors [] use = use
    withAncestors (dir : remaining) use = bracket (pinDirectory dir) release (\_ -> withAncestors remaining use)

pinDirectory :: FilePath -> IO Handle
pinDirectory path = withWide path $ \name -> do
  let open = createFile name readAttributes (shareRead .|. shareWrite) nullPtr openExisting (backupSemantics .|. openReparse) nullPtr
  initial <- open
  directory <-
    if initial /= invalidHandle
      then pure initial
      else do
        errorCode <- lastError
        if errorCode /= 2 && errorCode /= 3
          then winError "Cannot pin save directory" errorCode
          else do
            created <- createDirectory name nullPtr
            when (created == 0) $ do
              failure <- lastError
              when (failure /= 183) (winError "Cannot create save directory" failure)
            open >>= checkedHandle "Cannot pin newly created save directory"
  ( do
      attributes <- checkedAttributes directory
      require
        (hasAttribute directoryAttribute attributes && not (hasAttribute reparseAttribute attributes))
        "Save directory ancestor is not a plain directory"
      pure directory
    )
    `onException` release directory

checkedAttributes :: Handle -> IO Dword
checkedAttributes handle =
  -- BY_HANDLE_FILE_INFORMATION is thirteen DWORDs. Only its first field is used.
  allocaBytesAligned 52 4 $ \information -> do
    check "Cannot inspect save file handle" (fileInformation handle information)
    peekByteOff information 0

hasAttribute :: Dword -> Dword -> Bool
hasAttribute flag attributes = attributes .&. flag /= 0

checkedHandle :: String -> Handle -> IO Handle
checkedHandle label handle
  | handle == invalidHandle = lastError >>= winError label
  | otherwise = pure handle

release :: Handle -> IO ()
release = void . closeHandle

openRegular :: FilePath -> Dword -> Dword -> Dword -> Dword -> IO Handle
openRegular path access sharing creation flags = withWide path $ \name -> do
  handle <- createFile name access sharing nullPtr creation flags nullPtr >>= checkedHandle "Cannot open save leaf"
  ( do
      attributes <- checkedAttributes handle
      require (not (hasAttribute (directoryAttribute .|. reparseAttribute) attributes)) "Save leaf is not a regular file"
      pure handle
    )
    `onException` release handle

leafPath :: FilePath -> String -> IO FilePath
leafPath root leaf = do
  require (not (null leaf) && length leaf <= 120 && all allowed leaf && not (isInfixOf ".." leaf)) "Invalid save leaf name"
  let path = root </> leaf
  require (BS.length (encodeUtf16LE (Text.pack path)) < 65534) "Save leaf path too long"
  pure path
  where
    allowed c = ('a' <= c && c <= 'z') || ('0' <= c && c <= '9') || c == '-' || c == '.'

withOperation :: PinnedStore -> (FilePath -> IO a) -> IO a
withOperation (PinnedStore root active) use =
  withMVar active $ \open -> do
    require open "Save store is closed"
    runInBoundThread (use root)

listLeaves :: PinnedStore -> IO [FilePath]
listLeaves store = withOperation store listDirectory

writeLeaf :: PinnedStore -> String -> BS.ByteString -> IO ()
writeLeaf store name bytes = withOperation store $ \root -> do
  path <- leafPath root name
  require (toInteger (BS.length bytes) <= toInteger (maxBound :: Dword)) "Save leaf is too large"
  bracket (openRegular path genericWrite 0 createNew (openReparse .|. writeThrough)) release $ \handle ->
    BS.useAsCStringLen bytes $ \(source, size) -> do
      transfer "Checkpoint write failed" size (writeFileBytes handle) (castPtr source)
      check "Checkpoint flush failed" (flushFile handle)

transfer :: String -> Int -> (Ptr Word8 -> Dword -> Ptr Dword -> Ptr () -> IO Bool32) -> Ptr Word8 -> IO ()
transfer label lengthBytes call buffer = alloca $ \count -> loop count 0
  where
    loop count offset
      | offset == lengthBytes = pure ()
      | otherwise = do
          let remaining = lengthBytes - offset
          check label (call (plusPtr buffer offset) (fromIntegral remaining) count nullPtr)
          copied <- fromIntegral <$> peek count
          require (copied > 0 && copied <= remaining) (label ++ " (unexpected byte count)")
          loop count (offset + copied)

readCheckpoint :: PinnedStore -> String -> IO BS.ByteString
readCheckpoint store = readLeaf store 40 33554472

readPreferences :: PinnedStore -> String -> IO BS.ByteString
readPreferences store name = do
  require (name == "ui-preferences.rdui" || isPrefixOf "ui-preferences-" name) "Invalid preference leaf name"
  readLeaf store 1 1024 name

readLeaf :: PinnedStore -> Int64 -> Int64 -> String -> IO BS.ByteString
readLeaf store least most name = withOperation store $ \root -> do
  path <- leafPath root name
  bracket (openRegular path genericRead shareRead openExisting openReparse) release $ \handle -> alloca $ \size -> do
    check "Cannot determine save leaf size" (fileSize handle size)
    bytes <- peek size
    require (least <= bytes && bytes <= most) "Invalid save leaf size"
    BSI.create (fromIntegral bytes) (transfer "Store read failed" (fromIntegral bytes) (readFileBytes handle))

commitCheckpoint :: PinnedStore -> String -> String -> IO ()
commitCheckpoint store temporary final = withOperation store $ \root -> do
  source <- leafPath root temporary
  target <- leafPath root final
  rename source target renameWriteThrough

replacePreferences :: PinnedStore -> String -> IO ()
replacePreferences store temporary = withOperation store $ \root -> do
  require (isPrefixOf "ui-preferences-" temporary) "Invalid temporary preference name"
  source <- leafPath root temporary
  target <- leafPath root "ui-preferences.rdui"
  attributes <- withWide target fileAttributes
  require
    (attributes == maxBound || not (hasAttribute (directoryAttribute .|. reparseAttribute) attributes))
    "Preference destination is not a regular file"
  rename source target (replaceExisting .|. renameWriteThrough)

rename :: FilePath -> FilePath -> Dword -> IO ()
rename source target flags = withWide source $ \from -> withWide target $ \to ->
  check "Store commit failed" (moveFile from to flags)

showError :: String -> IO ()
showError message = withWide message $ \body -> withWide "Red Dune" $ \title ->
  void (messageBox nullPtr body title 0x10)
