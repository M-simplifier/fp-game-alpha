{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module FpGame.Create.Filesystem
  ( SourceSnapshot,
    checkedSourceRoot,
    checkedDestination,
    readSelection,
    snapshotFiles,
    verifySnapshot,
    publishFiles,
  )
where

import Control.Exception (IOException, bracket, catch, mask_, throwIO)
#ifndef mingw32_HOST_OS
import Control.Exception (bracketOnError)
#endif
import Control.Monad (forM, forM_, unless, when)
import Data.ByteString qualified as BS
import Data.Char (isControl)
import Data.List (sort)
import Data.Map.Strict qualified as Map
#ifdef mingw32_HOST_OS
import FpGame.Create.Options (windowsDeviceName)
#endif
import FpGame.Error (ErrorCode (..), failTool)
import System.Directory
  ( canonicalizePath,
    createDirectory,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    makeAbsolute,
    pathIsSymbolicLink,
    removeFile,
  )
import System.FilePath
  ( isAbsolute,
    isDrive,
    joinPath,
    makeRelative,
    normalise,
    splitDirectories,
    takeDirectory,
    (</>),
  )
#ifdef mingw32_HOST_OS
import System.FilePath (dropTrailingPathSeparator)
import System.Win32.File qualified as Win32
#else
import System.IO (hClose)
import System.Posix.IO qualified as Posix
import System.Posix.Files qualified as Posix
#endif
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)

type Files = Map.Map FilePath BS.ByteString

data SourceSnapshot = SourceSnapshot FilePath Files

snapshotFiles :: SourceSnapshot -> Files
snapshotFiles (SourceSnapshot _ files) = files

-- Reserve a nonexistent root before publishing exclusively created leaves.
-- Failure retains any partial tree and its marker for the caller to inspect.
publishFiles :: FilePath -> Files -> IO ()
publishFiles destination files = do
  let marker = destination </> ".scaffold-incomplete"
  ensureDirectory (takeDirectory destination)
  rejectLinks destination
  mask_ $ do
    createDirectory destination `catch` destinationCreationError destination
    writeExclusive marker "Scaffolding has not completed.\n"
  forM_ (Map.toAscList files) $ \(relative, content) -> do
    checkRelativeName relative
    let path = destination </> relative
    unless (within destination path) $
      failTool UnsafePath "Generated path escaped the new project."
    ensureDirectory (takeDirectory path)
    rejectLinks path
    writeExclusive path content
  rejectLinks marker
  removeFile marker

checkedSourceRoot :: FilePath -> IO FilePath
checkedSourceRoot source = do
  path <- checkedAbsolute source
  rejectLinks path
  exists <- doesDirectoryExist path
  unless exists $ failTool InvalidProject "The explicit foundation source directory does not exist."
  canonicalizePath path

checkedDestination :: FilePath -> FilePath -> IO FilePath
checkedDestination source requested = do
  validateDestinationSpelling requested
  destination <- checkedAbsolute requested
  rejectLinks destination
  exists <- doesPathExist destination
  when exists $ failTool DestinationExists "Scaffold refuses every existing destination, including empty directories."
  when (within source destination && not (within (source </> "generated-games") destination || within (source </> ".build") destination)) $
    failTool UnsafePath "Choose an independent directory outside the foundation checkout, or generated-games/."
  pure destination

validateDestinationSpelling :: FilePath -> IO ()
#ifdef mingw32_HOST_OS
validateDestinationSpelling path = forM_ (splitDirectories path) $ \part -> do
  let component = dropTrailingPathSeparator part
  unless (isDrive part || component `elem` [".", ".."]) $ do
    let reversed = reverse component
        badEnding = case reversed of
          character : _ -> character == '.' || character == ' '
          [] -> False
        basename = reverse (dropWhile (== ' ') (reverse (takeWhile (/= '.') component)))
    when (badEnding || windowsDeviceName basename || any (`elem` ("<>:\"|?*" :: String)) component) $
      failTool UnsafePath "Windows destination components must not use device names, reserved characters, or trailing dots/spaces."
#else
validateDestinationSpelling _ = pure ()
#endif

checkedAbsolute :: FilePath -> IO FilePath
checkedAbsolute path = do
  when (null path || any isControl path) $
    failTool UnsafePath "Paths must be nonempty and must not contain control characters."
  -- Top-level roots are chosen by the caller, so ../My Game is legitimate.
  -- Inspect the raw spelling before resolving it: alias/../ must not hide a
  -- symbolic-link ancestor. On Windows even makeAbsolute removes parent
  -- components, so this check must precede it. Relative ancestor prefixes are
  -- checked against the same current directory used by makeAbsolute below.
  -- Generated relative file names remain stricter.
  rejectLinks path
  absolute <- makeAbsolute path
  rejectLinks absolute
  -- canonicalizePath can retain ../ beneath a nonexistent directory. Collapse
  -- that spelling only after checking its raw ancestors, and check the new
  -- spelling too before canonicalization could follow a previously hidden link.
  let normalized = collapseParents absolute
  rejectLinks normalized
  resolved <- canonicalizePath normalized
  rejectLinks resolved
  pure resolved

collapseParents :: FilePath -> FilePath
collapseParents = joinPath . reverse . foldl step [] . splitDirectories
  where
    step ancestors' "." = ancestors'
    step [] ".." = []
    step ancestors'@(parent : rest) ".."
      | isDrive parent = ancestors'
      | otherwise = rest
    step ancestors' component = component : ancestors'

within :: FilePath -> FilePath -> Bool
within root path =
  let relative = makeRelative (normalise root) (normalise path)
   in not (isAbsolute relative) && ".." `notElem` splitDirectories relative

-- Check the final entry as well as every ancestor, including dangling links.
-- Repeated at the read/write boundary rather than trusting an earlier plan.
rejectLinks :: FilePath -> IO ()
rejectLinks path = forM_ (ancestors path) $ \entry -> do
  linked <- pathIsSymbolicLink entry `catch` absentLink
  when linked $ failTool UnsafePath ("Refusing a linked path: " <> entry)
  where
    absentLink :: IOException -> IO Bool
    absentLink problem
      | isDoesNotExistError problem = pure False
      | otherwise = throwIO problem

ancestors :: FilePath -> [FilePath]
ancestors path
  | takeDirectory path == path = [path]
  | otherwise = ancestors (takeDirectory path) <> [path]

checkRelativeName :: FilePath -> IO ()
checkRelativeName path =
  unless (not (null path) && not (isAbsolute path) && all safePart (splitDirectories path) && not (any (`elem` ['\\', ':']) path)) $
    failTool UnsafePath ("Invalid distributed file path: " <> path)
  where
    safePart part = part /= ".." && part /= "." && not (null part) && not (any isControl part)

readSelection :: FilePath -> [FilePath] -> IO SourceSnapshot
readSelection root names = do
  when (length names /= Map.size (Map.fromList [(name, ()) | name <- names])) $
    failTool InvalidConfig "The reviewed source distribution contains duplicate entries."
  SourceSnapshot root . Map.fromList
    <$> forM
      (sort names)
      ( \name -> do
          checkRelativeName name
          content <- readSource root name
          pure (name, content)
      )

readSource :: FilePath -> FilePath -> IO BS.ByteString
readSource root name = do
  let path = root </> name
  rejectLinks path
  exists <- doesFileExist path
  unless exists $ failTool InvalidProject ("Missing reviewed source file: " <> name)
  content <- readSourceBytes path
  rejectLinks path
  pure content

readSourceBytes :: FilePath -> IO BS.ByteString
#ifdef mingw32_HOST_OS
readSourceBytes = BS.readFile
#else
readSourceBytes path = bracket
  (bracketOnError
    (Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True})
    Posix.closeFd
    (\descriptor -> do
      status <- Posix.getFdStatus descriptor
      unless (Posix.isRegularFile status) $ failTool UnsafePath ("Reviewed source is not a regular file: " <> path)
      Posix.fdToHandle descriptor))
  hClose
  BS.hGetContents
#endif

verifySnapshot :: SourceSnapshot -> IO ()
verifySnapshot (SourceSnapshot root inputs) = forM_ (Map.toAscList inputs) $ \(name, expected) -> do
  current <- readSource root name
  unless (current == expected) $
    failTool SourceChanged ("Source changed while preparing the scaffold: " <> name)

ensureDirectory :: FilePath -> IO ()
ensureDirectory directory = do
  rejectLinks directory
  exists <- doesDirectoryExist directory
  unless exists $ do
    when (takeDirectory directory /= directory) (ensureDirectory (takeDirectory directory))
    createDirectory directory `catch` alreadyDirectory
    rejectLinks directory
  where
    alreadyDirectory :: IOException -> IO ()
    alreadyDirectory problem
      | isAlreadyExistsError problem = do
          rejectLinks directory
          exists <- doesDirectoryExist directory
          unless exists (throwIO problem)
      | otherwise = throwIO problem

destinationCreationError :: FilePath -> IOException -> IO a
destinationCreationError destination problem
  | isAlreadyExistsError problem = failTool DestinationExists ("Destination already exists: " <> destination)
  | otherwise = throwIO problem

-- Leaf creation is an OS-level exclusive operation, including concurrent file
-- or symlink creation. Ancestors are checked before use. As with most portable
-- path APIs, callers must not let another process rename the directory tree
-- during the operation; this is not a sandbox for an adversarial filesystem.
writeExclusive :: FilePath -> BS.ByteString -> IO ()
writeExclusive path content = do
  rejectLinks path
  writeNewBytes path content

writeNewBytes :: FilePath -> BS.ByteString -> IO ()
#ifdef mingw32_HOST_OS
writeNewBytes path content =
  bracket
    (Win32.createFile path Win32.gENERIC_WRITE 0 Nothing Win32.cREATE_NEW Win32.fILE_ATTRIBUTE_NORMAL Nothing)
    Win32.closeHandle
    (\handle -> writeChunks handle content)
  where
    writeChunks handle remaining = unless (BS.null remaining) $ do
      let chunk = BS.take (1024 * 1024) remaining
      written <- BS.useAsCStringLen chunk $ \(buffer, size) -> Win32.win32_WriteFile handle buffer (fromIntegral size) Nothing
      when (written == 0) $ failTool ToolIO ("Could not make progress writing: " <> path)
      writeChunks handle (BS.drop (fromIntegral written) remaining)
#else
writeNewBytes path content =
  bracket
    (bracketOnError
      (Posix.openFd path Posix.WriteOnly Posix.defaultFileFlags {Posix.creat = Just 0o600, Posix.exclusive = True, Posix.nofollow = True, Posix.cloexec = True})
      Posix.closeFd
      Posix.fdToHandle)
    hClose
    (\handle -> BS.hPut handle content)
#endif
