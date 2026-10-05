-- | Filesystem validation is performed again at each effect boundary.
-- These checks protect against accidental links and traversal, not an attacker
-- concurrently replacing parent directories or an untrusted Cabal build hook.
module FpGame.Path
  ( ProjectRoot,
    projectPath,
    selectProject,
    inside,
    resolveIn,
    requireUnlinked,
    buildState,
    checkedSource,
  )
where

import Control.Exception (IOException, catch)
import Control.Monad (unless, when)
import Data.Char (isControl)
import FpGame.Error
import System.Directory
import System.FilePath
import System.IO.Error (isDoesNotExistError)

newtype ProjectRoot = ProjectRoot FilePath deriving (Eq, Show)

projectPath :: ProjectRoot -> FilePath
projectPath (ProjectRoot path) = path

selectProject :: Maybe FilePath -> IO ProjectRoot
selectProject requested = do
  path <- maybe getCurrentDirectory makeAbsolute requested >>= canonicalizePath
  exists <- doesDirectoryExist path
  unless exists (failTool InvalidProject "Project directory does not exist.")
  when (any isControl path) (failTool UnsafePath "Project path contains unsupported control characters.")
  pure (ProjectRoot path)

inside :: FilePath -> FilePath -> Bool
inside root path = equalFilePath root path || withinParts (splitDirectories root) (splitDirectories path)
  where
    withinParts expected actual = length expected <= length actual && and (zipWith equalFilePath expected actual)

resolveIn :: ProjectRoot -> FilePath -> IO FilePath
resolveIn (ProjectRoot root) name = do
  let path = if isAbsolute name then name else root </> name
  resolved <- canonicalizePath path
  unless (inside root resolved) (failTool UnsafePath "Selected path must remain inside this project.")
  pure resolved

-- Refuse symbolic links before following them, including dangling links.
requireUnlinked :: FilePath -> FilePath -> IO ()
requireUnlinked root path = do
  unless (inside root path && not (".." `elem` splitDirectories (makeRelative root path))) $
    failTool UnsafePath "Selected path must remain inside this project."
  mapM_ check (parents path)
  where
    parents current
      | equalFilePath current root = [root]
      | otherwise = current : parents (takeDirectory current)
    check current = do
      linked <- pathIsSymbolicLink current `catch` missing
      when linked (failTool UnsafePath ("Refusing symbolic link: " ++ current))
    missing :: IOException -> IO Bool
    missing errorValue
      | isDoesNotExistError errorValue = pure False
      | otherwise = ioError errorValue

buildState :: ProjectRoot -> IO FilePath
buildState (ProjectRoot root) = do
  let state = root </> ".build"
  requireUnlinked root state
  createDirectoryIfMissing False state
  -- Cabal may write beneath each of these paths, so check existing trees too.
  mapM_ (checkTree . (state </>)) ["store", "package-cache", "logs", "dist"]
  pure state
  where
    checkTree path = do
      requireUnlinked root path
      directory <- doesDirectoryExist path
      when directory $ listDirectory path >>= mapM_ (checkTree . (path </>))

checkedSource :: ProjectRoot -> FilePath -> IO FilePath
checkedSource root filename = do
  path <- resolveIn root filename
  exists <- doesFileExist path
  unless (exists && takeExtension path == ".hs") $
    failTool InvalidArguments "Choose an existing .hs source inside the selected project."
  pure path
