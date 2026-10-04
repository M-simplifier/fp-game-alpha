{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Concurrent (forkIO, myThreadId, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception, IOException, bracket, catch, onException, throwIO, throwTo, try)
import Control.Monad (filterM, unless, when)
import Data.Aeson (FromJSON(..), eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (isPrefixOf)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import System.Directory
import System.Environment (getArgs, lookupEnv)
import System.Exit
import System.FilePath
import System.IO
import System.IO.Temp (withTempDirectory)
import System.IO.Error (ioeGetErrorString, isUserError)
import System.Posix.Signals (Handler(Catch), installHandler, signalProcessGroup, sigKILL, sigTERM)
import System.Process hiding (runCommand)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data Command = Build | Check (Maybe FilePath) deriving Show
data Options = Options Command (Maybe FilePath) Bool deriving Show
newtype ProjectRoot = ProjectRoot FilePath
newtype Sources = Sources [FilePath]
instance FromJSON Sources where
  parseJSON = withObject "fp-game.json" $ \o -> Sources <$> o .: "source_dirs"
data Terminated = Terminated deriving Show
instance Exception Terminated

data Result = Executed [String] Int T.Text T.Text | Failed T.Text

usage :: String
usage = "Usage: fp-game-probe (build | check [FILE.hs]) [--project DIR] [--json]"
parseArgs :: [String] -> Either String Options
parseArgs (action:rest) | action `elem` ["build", "check"] = go Nothing False Nothing rest
 where
  go project json file [] = Right (Options (if action == "build" then Build else Check file) project json)
  go Nothing json file ("--project":p:xs) = go (Just p) json file xs
  go project False file ("--json":xs) = go project True file xs
  go project json Nothing (f:xs) | action == "check", not ("-" `isPrefixOf` f) = go project json (Just f) xs
  go _ _ _ _ = Left usage
parseArgs _ = Left usage

failWith :: String -> IO a
failWith = ioError . userError
inside :: FilePath -> FilePath -> Bool
inside root path = path == root || addTrailingPathSeparator root `isPrefixOf` path
resolveIn :: FilePath -> FilePath -> IO FilePath
resolveIn root name = canonicalizePath (if isAbsolute name then name else root </> name)
requireTool :: String -> String -> IO FilePath
requireTool name message = findExecutable name >>= maybe (failWith message) pure
stateDir :: ProjectRoot -> IO FilePath
stateDir (ProjectRoot root) = do
  let state = root </> ".build"
  resolved <- canonicalizePath state
  unless (inside root resolved) (failWith "Build state must remain inside this project.")
  createDirectoryIfMissing False state
  pure state
sourceDirs :: ProjectRoot -> IO [FilePath]
sourceDirs (ProjectRoot root) = do
  let config = root </> "fp-game.json"
  exists <- doesFileExist config
  names <- if exists then do
    bytes <- BS.readFile config
    case eitherDecodeStrict' bytes of
      Left e -> failWith ("Invalid fp-game.json: " ++ e)
      Right (Sources paths) -> pure paths
    else pure ["libraries/game-transition/src", "libraries/game-arena/src", "references/lantern/src", "references/garden/src", "references/tapline/src", "references/river/src", "references/station/src", "src"]
  paths <- mapM (resolveIn root) names
  unless (all (inside root) paths) (failWith "Declared source directories must remain inside this project.")
  filterM doesDirectoryExist paths
checkedSource :: ProjectRoot -> FilePath -> IO FilePath
checkedSource (ProjectRoot root) filename = do
  path <- resolveIn root filename
  exists <- doesFileExist path
  unless (inside root path && exists && takeExtension path == ".hs")
    (failWith "Choose an existing .hs source inside the selected project.")
  pure path

-- Pipes are binary, decoded as UTF-8 with replacement just like Python errors=replace.
-- POSIX process group cleanup also covers compiler/linker descendants on timeout.
execute :: ProjectRoot -> [String] -> IO Result
execute root command = executeCaptured root command `catch` (\(e :: IOException) -> pure (Executed command 1 "" (T.pack (show e))))

executeCaptured :: ProjectRoot -> [String] -> IO Result
executeCaptured (ProjectRoot root) command@(exe:args) = do
  seconds <- lookupEnv "FP_GAME_PROBE_TIMEOUT_SECONDS" >>= \v -> case v of
    Nothing -> pure 180
    Just s -> case readMaybe s of
      Just n | n > 0 && n <= (180 :: Int) -> pure n
      _ -> failWith "FP_GAME_PROBE_TIMEOUT_SECONDS must be 1..180."
  let cp = (proc exe args) {cwd=Just root, std_in=NoStream, std_out=CreatePipe, std_err=CreatePipe, create_group=True}
      ignoreIO action = action `catch` (\(_ :: IOException) -> pure ())
      close (_, out, err, _) = mapM_ (maybe (pure ()) (ignoreIO . hClose)) [out, err]
  bracket (createProcess cp) close $ \(_, out, err, ph) -> do
    pid <- getPid ph
    let stop = do
          maybe (ignoreIO (terminateProcess ph)) (\p -> ignoreIO (signalProcessGroup sigKILL p)) pid
          _ <- waitForProcess ph
          pure ()
        reader h = do
          box <- newEmptyMVar
          _ <- forkIO $ (try (BS.hGetContents h) :: IO (Either IOException BS.ByteString)) >>= putMVar box
          pure box
    case (out, err) of
      (Just oh, Just eh) -> do
        ob <- reader oh
        eb <- reader eh
        completed <- (timeout (seconds * 1000000) $ do
          ec <- waitForProcess ph
          o <- takeMVar ob >>= either throwIO pure
          e <- takeMVar eb >>= either throwIO pure
          pure (ec,o,e)) `onException` stop
        case completed of
          Nothing -> stop >> pure (Executed command 1 "" "Command timed out; process group terminated.")
          Just (ec,o,e) -> pure (Executed command (case ec of ExitSuccess -> 0; ExitFailure n -> n) (TE.decodeUtf8With lenientDecode o) (TE.decodeUtf8With lenientDecode e))
      _ -> stop >> failWith "Could not create process capture pipes."
executeCaptured _ [] = failWith "Empty command."

runCommand :: ProjectRoot -> Command -> IO Result
runCommand root (Check (Just filename)) = do
  source <- checkedSource root filename
  ghc <- requireTool "ghc" "GHC is missing. Run doctor."
  state <- stateDir root
  dirs <- sourceDirs root
  withTempDirectory state "check-" $ \output ->
    execute root ([ghc,"-fno-code","-fforce-recomp","-XGHC2021","-Wall","-fdiagnostics-color=never","-outputdir",output] ++ map ("-i" ++) dirs ++ [source])
runCommand root@(ProjectRoot path) _ = do
  state <- stateDir root
  -- Cabal config is line-oriented: refuse control characters rather than injecting fields.
  when (any (`elem` ['\n','\r','\0']) path) (failWith "Project path contains unsupported control characters.")
  let config = state </> "cabal.config"
  linked <- pathIsSymbolicLink config `catch` (\(_ :: IOException) -> pure False)
  when linked (failWith "Cabal configuration must not be a symbolic link.")
  BS.writeFile config (TE.encodeUtf8 (T.pack ("active-repositories: :none\nstore-dir: " ++ state </> "store" ++ "\nremote-repo-cache: " ++ state </> "package-cache" ++ "\n")))
  cabal <- requireTool "cabal" "Cabal is missing. Run doctor and follow docs/setup.md."
  execute root [cabal,"--config-file=" ++ config,"build","all","--offline","--builddir=" ++ state </> "dist"]

resultCode :: Result -> Int
resultCode (Failed _) = 1
resultCode (Executed _ n _ _) = n
render :: Bool -> Result -> IO ()
render json result = if json then BL.hPutStr stdout (encode value <> "\n") else do
  BS.hPut stdout (TE.encodeUtf8 out)
  BS.hPut stderr (TE.encodeUtf8 err)
 where
  (out,err) = case result of Failed e -> ("",e); Executed _ _ o e -> (o,e)
  value = case result of
    Failed e -> object ["status" .= ("error" :: T.Text),"exit_code" .= (1 :: Int),"stdout" .= ("" :: T.Text),"stderr" .= e]
    Executed cmd n o e -> object ["command" .= cmd,"exit_code" .= n,"stdout" .= o,"stderr" .= e]
main :: IO ()
main = (do
  thread <- myThreadId
  _ <- installHandler sigTERM (Catch (throwTo thread Terminated)) Nothing
  mainBody) `catch` (\Terminated -> exitWith (ExitFailure 143))

mainBody :: IO ()
mainBody = do
  args <- getArgs
  case parseArgs args of
    Left e -> hPutStrLn stderr e >> exitWith (ExitFailure 2)
    Right (Options command project json) -> do
      result <- (do
        -- Standalone install root has no project/template role. Default is caller cwd.
        root <- maybe getCurrentDirectory makeAbsolute project >>= canonicalizePath
        exists <- doesDirectoryExist root
        unless exists (failWith "Project directory does not exist.")
        runCommand (ProjectRoot root) command) `catch` (\(e :: IOException) -> pure (Failed (T.pack (ioeText e))))
      render json result
      exitWith (if resultCode result == 0 then ExitSuccess else ExitFailure (resultCode result))
 where
  ioeText e = if isUserError e then ioeGetErrorString e else show e
