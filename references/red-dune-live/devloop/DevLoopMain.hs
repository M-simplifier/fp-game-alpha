{-# LANGUAGE OverloadedStrings #-}

-- | Native, game-local development supervisor. Cabal selects the package DB;
-- GHCi owns only the editable gameplay/host modules. A reload is a new runtime,
-- never a transfer of heap values or request authority across code versions.
module Main (main) where

import Colony.Codec.SHA256 (sha256Hex)
import Colony.JSON (JSON (..), field, object, parseJSON, string)
import Colony.Presentation (encodeJSON, obj)
import Control.Concurrent (myThreadId, threadDelay, throwTo)
import Control.Exception (AsyncException (UserInterrupt), IOException, bracket, bracketOnError, catch, displayException, finally, mask, mask_, onException, throwIO, uninterruptibleMask_)
import Control.Monad (forM, unless, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as C
import Data.Char (isSpace)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf, nub, sort)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket qualified as N
import Network.Socket.ByteString qualified as N
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getCurrentDirectory, listDirectory, makeAbsolute, removeFile, renameFile)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)
import System.FilePath (isAbsolute, takeDirectory, takeExtension, (</>))
import System.IO qualified as IO
import System.IO.Error (isDoesNotExistError, tryIOError)
import System.Posix.Files qualified as P
import System.Posix.IO qualified as P
import System.Posix.Signals qualified as P
import System.Posix.Types (Fd, ProcessID)
import System.Process qualified as Proc
import System.Timeout (timeout)
import Text.Read (readMaybe)

data Options = Options
  { root :: !FilePath,
    cabal :: !FilePath,
    cabalConfig :: !(Maybe FilePath),
    project :: !FilePath,
    buildDir :: !FilePath,
    distDir :: !(Maybe FilePath),
    port :: !Int,
    pack :: !(Maybe FilePath),
    once :: !Bool
  }

data Source = Source
  { revision :: !String,
    coreRevision :: !String,
    generation :: !String,
    savedNs :: !Integer
  }
  deriving (Eq)

data Repl = Repl
  { process :: !Proc.ProcessHandle,
    groupId :: !(Maybe ProcessID),
    input :: !IO.Handle,
    compilerLogPath :: !FilePath,
    completionPath :: !FilePath,
    outputOffset :: !(IORef Integer),
    hostMayRun :: !(IORef Bool),
    commandCounter :: !(IORef Integer)
  }

data UpdateOutcome = AwaitEdit | SourceSuperseded
  deriving (Eq)

data Session = Session
  { options :: !Options,
    interpreter :: !(IORef (Maybe Repl)),
    loadedCore :: !(IORef (Maybe String)),
    events :: !IO.Handle
  }

main :: IO ()
main = do
  args <- getArgs
  if any (`elem` ["--help", "-h"]) args
    then putStrLn usage
    else do
      repository <- lookupEnv "RED_DUNE_DEV_ROOT"
      repo <- maybe getCurrentDirectory pure repository >>= findRoot
      opts <- either die pure (parseOptions (defaults repo) args) >>= absoluteOptions
      owner <- myThreadId
      interrupted <- newIORef False
      let interrupt = P.Catch $ do
            alreadyStopping <- atomicModifyIORef' interrupted (\sent -> (True, sent))
            unless alreadyStopping (throwTo owner UserInterrupt)
      _ <- P.installHandler P.keyboardSignal interrupt Nothing
      _ <- P.installHandler P.softwareTermination interrupt Nothing
      ( bracket (acquireLock opts) P.closeFd $ \_ ->
          bracket (openSession opts) closeSession $ \session -> do
            refuseOccupiedPort (port opts)
            watch session
        )
        `catch` \exception -> case exception of
          UserInterrupt -> pure ()
          _ -> throwIO exception

usage :: String
usage =
  unlines
    [ "Red Dune native source edit -> checked GHCi reload -> fresh paused host",
      "Usage: references/red-dune-live/tools/dev.sh [OPTIONS]",
      "  --port N             Loopback port, default 8787 (1024..65535)",
      "  --project-file PATH  Cabal project, default cabal.project.red-dune-dev",
      "  --cabal PATH         Cabal executable, default cabal",
      "  --cabal-config PATH  Optional Cabal configuration (e.g. offline store)",
      "  --build-dir PATH     Isolated saves/logs/lock, default .build/red-dune-dev",
      "  --dist-dir PATH      Optional independent Cabal measurement cache",
      "  --pack PATH          Initial content pack; changes restart the host",
      "  --once               Check once, then hold host until Ctrl-C",
      "Source edits use :reload; core/library/project edits replace GHCi via Cabal.",
      "HTTP readiness is measured; browser rendering/input timings remain null."
    ]

defaults :: FilePath -> Options
defaults repo = Options repo "cabal" Nothing (repo </> "cabal.project.red-dune-dev") (repo </> ".build/red-dune-dev") Nothing 8787 Nothing False

parseOptions :: Options -> [String] -> Either String Options
parseOptions opts [] = Right opts
parseOptions opts (argument : rest)
  | "--" `isPrefixOf` argument, (name, '=' : value) <- break (== '=') argument = parseOptions opts (name : value : rest)
parseOptions opts ("--once" : rest) = parseOptions opts {once = True} rest
parseOptions opts (name : value : rest) = case name of
  "--cabal" -> next opts {cabal = value}
  "--cabal-config" -> next opts {cabalConfig = Just value}
  "--project-file" -> next opts {project = value}
  "--build-dir" -> next opts {buildDir = value}
  "--dist-dir" -> next opts {distDir = Just value}
  "--pack" -> next opts {pack = Just value}
  "--port" -> case readMaybe value :: Maybe Integer of
    Just n | n >= 1024 && n <= 65535 -> next opts {port = fromInteger n}
    _ -> Left "--port must be an integer in 1024..65535"
  _ -> Left ("Unknown option: " ++ name ++ "\n" ++ usage)
  where
    next changed = parseOptions changed rest
parseOptions _ [name] = Left ("Missing value or unknown option: " ++ name ++ "\n" ++ usage)

absoluteOptions :: Options -> IO Options
absoluteOptions opts = do
  projectPath <- makeAbsolute (project opts)
  buildPath <- makeAbsolute (buildDir opts)
  configPath <- traverse makeAbsolute (cabalConfig opts)
  distPath <- traverse makeAbsolute (distDir opts)
  packPath <- traverse makeAbsolute (pack opts)
  cabalPath <- if '/' `elem` cabal opts then makeAbsolute (cabal opts) else pure (cabal opts)
  pure opts {project = projectPath, buildDir = buildPath, cabalConfig = configPath, distDir = distPath, pack = packPath, cabal = cabalPath}

findRoot :: FilePath -> IO FilePath
findRoot path = do
  exists <- doesFileExist (path </> "references/red-dune-live/red-dune-live.cabal")
  if exists
    then canonicalizePath path
    else
      if takeDirectory path == path then fail "Run from the repository or use tools/dev.sh" else findRoot (takeDirectory path)

acquireLock :: Options -> IO Fd
acquireLock opts = do
  validateDirectory (buildDir opts)
  createDirectoryIfMissing True (buildDir opts)
  mapM_ (validateArtifact . (buildDir opts </>)) ["supervisor.lock", "events.jsonl", "compiler.log", "status.json", "status.json.tmp", "command.done"]
  fd <- openArtifact (buildDir opts </> "supervisor.lock")
  ( do
      P.setFdOption fd P.CloseOnExec True
      P.setLock fd (P.WriteLock, IO.AbsoluteSeek, 0, 0)
      pure fd
    )
    `onException` P.closeFd fd
    `catch` \(_ :: IOException) -> fail "Another development supervisor owns this build/save folder (or it cannot be locked)"

-- Refuse existing aliases before opening any writable artifact. In particular,
-- two hardlinked paths must not let closing a log release the POSIX lock.
validateArtifact :: FilePath -> IO ()
validateArtifact path = validateExisting path (\info -> P.isRegularFile info && P.linkCount info == 1)

validateDirectory :: FilePath -> IO ()
validateDirectory path = validateExisting path P.isDirectory

validateExisting :: FilePath -> (P.FileStatus -> Bool) -> IO ()
validateExisting path valid = do
  result <- tryIOError (P.getSymbolicLinkStatus path)
  case result of
    Left problem | isDoesNotExistError problem -> pure ()
    Left problem -> throwIO problem
    Right info -> unless (valid info) (fail ("Refusing aliased or unexpected development path: " ++ path))

openArtifact :: FilePath -> IO Fd
openArtifact path = bracketOnError
  (P.openFd path P.ReadWrite P.defaultFileFlags {P.creat = Just 0o600, P.nofollow = True, P.append = True, P.cloexec = True})
  P.closeFd
  $ \fd -> do
    info <- P.getFdStatus fd
    unless (P.isRegularFile info && P.linkCount info == 1) (fail ("Refusing non-regular or hardlinked artifact: " ++ path))
    pure fd

openAppendArtifact :: FilePath -> IO IO.Handle
openAppendArtifact path = bracketOnError (openArtifact path) P.closeFd P.fdToHandle

openSession :: Options -> IO Session
openSession opts = do
  validateDirectory (buildDir opts </> "saves")
  createDirectoryIfMissing True (buildDir opts </> "saves")
  ref <- newIORef Nothing
  core <- newIORef Nothing
  logHandle <- openAppendArtifact (buildDir opts </> "events.jsonl")
  IO.hSetBuffering logHandle IO.LineBuffering
  IO.hSetEncoding logHandle IO.utf8
  pure (Session opts ref core logHandle)

closeSession :: Session -> IO ()
closeSession session =
  (discardInterpreter session `finally` status session "stopped" [])
    `finally` IO.hClose (events session)

discardInterpreter :: Session -> IO ()
discardInterpreter session = mask_ $ do
  active <- readIORef (interpreter session)
  -- Keep ownership through interruptible cleanup. If the first Ctrl-C arrives
  -- during an ordinary rebuild teardown, the outer session finalizer must still
  -- find this child and finish terminating/joining its process group.
  maybe (pure ()) closeRepl active
  writeIORef (interpreter session) Nothing
  writeIORef (loadedCore session) Nothing

-- Never adopt a pre-existing listener, even if it serves plausible JSON.
refuseOccupiedPort :: Int -> IO ()
refuseOccupiedPort listenPort =
  bracket (N.socket N.AF_INET N.Stream N.defaultProtocol) N.close $ \socket -> do
    N.setSocketOption socket N.ReuseAddr 1
    result <- tryIOError (N.bind socket (loopback listenPort))
    either (\_ -> fail "Development port is occupied; choose another --port or stop its host") pure result

loopback :: Int -> N.SockAddr
loopback listenPort = N.SockAddrInet (fromIntegral listenPort) (N.tupleToHostAddress (127, 0, 0, 1))

-- Hash framed names and contents, including missing fixed paths, rather than
-- relying on mtime. Atomic editor replacement and preserved mtimes are visible.
snapshot :: Options -> IO Source
snapshot opts = do
  let game = root opts </> "references/red-dune-live"
      sourceRoots = [game </> folder | folder <- ["src", "app", "dev"]]
      coreRoots = [game </> "core", root opts </> "libraries/game-transition", root opts </> "libraries/game-arena"]
      fixedProjects = [project opts, root opts </> "cabal.project", root opts </> "cabal.project.red-dune-live", root opts </> "cabal.project.red-dune-dev"]
  projectFiles <- projectClosure [] (concat [[path, path ++ ".local", path ++ ".freeze"] | path <- fixedProjects])
  coreFiles <- concat <$> mapM sourceFiles coreRoots
  sourcePaths <- concat <$> mapM sourceFiles sourceRoots
  let corePaths = sort . nub $ (game </> "red-dune-live.cabal") : projectFiles ++ coreFiles ++ maybe [] (: []) (cabalConfig opts)
      paths = sort . nub $ corePaths ++ sourcePaths ++ maybe [] (: []) (pack opts)
  entries <- forM paths $ \path -> do
    present <- doesFileExist path
    if present
      then do
        before <- P.getFileStatus path
        bytes <- BS.readFile path
        after <- P.getFileStatus path
        unless (fileGeneration before == fileGeneration after) (fail "Source changed while hashing; retrying")
        pure (path, frame path bytes, floor (P.modificationTimeHiRes after * 1000000000), frame path (C.pack (fileGeneration after)))
      else pure (path, frame path "<missing>", 0, frame path "<missing>")
  let payload = BS.concat [bytes | (_, bytes, _, _) <- entries]
      corePayload = BS.concat [bytes | (path, bytes, _, _) <- entries, path `elem` corePaths]
  pure
    ( Source
        (sha256Hex payload)
        (sha256Hex corePayload)
        (sha256Hex (BS.concat [epoch | (_, _, _, epoch) <- entries]))
        (maximum (0 : [stamp | (_, _, stamp, _) <- entries]))
    )
  where
    frame path bytes = let name = T.encodeUtf8 (T.pack path) in BS.concat [C.pack (show (BS.length name)), ":", name, C.pack (show (BS.length bytes)), ":", bytes]

fileGeneration :: P.FileStatus -> String
fileGeneration info = show (P.deviceID info, P.fileID info, P.fileSize info, P.modificationTimeHiRes info, P.statusChangeTimeHiRes info)

sameGeneration :: Source -> Source -> Bool
sameGeneration left right = revision left == revision right && generation left == generation right

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles folder = do
  exists <- doesDirectoryExist folder
  if not exists
    then pure []
    else do
      children <- map (folder </>) . sort <$> listDirectory folder
      concat <$> mapM descend children
  where
    descend path = do
      directory <- doesDirectoryExist path
      if directory then sourceFiles path else pure [path | takeExtension path `elem` [".hs", ".lhs", ".cabal"]]

-- Follow ordinary local import lines as well as watching the project itself.
-- A remote import still changes its containing project digest when edited.
projectClosure :: [FilePath] -> [FilePath] -> IO [FilePath]
projectClosure seen [] = pure seen
projectClosure seen (path : rest)
  | path `elem` seen = projectClosure seen rest
  | otherwise = do
      present <- doesFileExist path
      imports <-
        if not present
          then pure []
          else do
            bytes <- BS.readFile path
            contents <- either (fail . show) (pure . T.unpack) (T.decodeUtf8' bytes)
            names <- either fail (pure . concat) (mapM importPaths (projectImportLines (lines contents)))
            mapM canonicalizePath [if isAbsolute name then name else takeDirectory path </> name | name <- names, not ("://" `isInfixOf` name)]
      projectClosure (path : seen) (imports ++ rest)

projectImportLines :: [String] -> [String]
projectImportLines [] = []
projectImportLines (raw : rest)
  | "import:" `isPrefixOf` trimmed =
      let (continuations, remaining) = span continuation rest
       in drop 7 trimmed : continuations ++ projectImportLines remaining
  | otherwise = projectImportLines rest
  where
    trimmed = dropWhile isSpace raw
    continuation line = case line of
      [] -> True
      char : _ -> isSpace char || "--" `isPrefixOf` line

-- Cabal import lists may quote whitespace-containing paths and end in comments.
-- Keep malformed edits as recoverable watcher errors rather than guessing paths.
importPaths :: String -> Either String [FilePath]
importPaths inputText = case dropWhile (\c -> isSpace c || c == ',') inputText of
  [] -> Right []
  '-' : '-' : _ -> Right []
  '"' : rest -> do
    (literal, remaining) <- quoted ['"'] rest
    value <- maybe (Left "Invalid quoted Cabal import") Right (readMaybe literal)
    (value :) <$> importPaths remaining
  text ->
    let (value, remaining) = span (\c -> not (isSpace c) && c /= ',') text
     in (value :) <$> importPaths remaining
  where
    quoted _ [] = Left "Unclosed quoted Cabal import"
    quoted acc ('\\' : escaped : rest) = quoted (escaped : '\\' : acc) rest
    quoted acc ('"' : rest) = Right (reverse ('"' : acc), rest)
    quoted acc (char : rest) = quoted (char : acc) rest

watch :: Session -> IO ()
watch session = next Nothing
  where
    opts = options session
    next previous = do
      attempt <- tryIOError (stableSource opts)
      case attempt of
        Left problem -> do
          discardInterpreter session
          status session "failed" [("error", JString (displayException problem))]
          threadDelay 250000
          next Nothing
        Right source -> do
          outcome <- if maybe True (not . sameGeneration source) previous then update session source else pure AwaitEdit
          if outcome == SourceSuperseded
            then next Nothing
            else
              if once opts
                then let hold = threadDelay 1000000 >> hold in hold
                else do
                  waitForChange source
                  next (Just source)
    waitForChange expected = do
      threadDelay 100000
      current <- tryIOError (snapshot opts)
      case current of
        Right source | sameGeneration source expected -> waitForChange expected
        _ -> pure ()

stableSource :: Options -> IO Source
stableSource opts = do
  first <- snapshot opts
  settle first
  where
    settle candidate = do
      threadDelay 80000
      current <- snapshot opts
      if sameGeneration current candidate then pure current else settle current

update :: Session -> Source -> IO UpdateOutcome
update session source = do
  detected <- getMonotonicTimeNSec
  wall <- wallNs
  status
    session
    "checking"
    [ ("revision", JString (revision source)),
      ("sourceSavedNs", JInteger (savedNs source)),
      ("detectionDelayMs", JInteger (max 0 ((wall - savedNs source) `div` 1000000)))
    ]
  result <- tryIOError $ do
    active <- readIORef (interpreter session)
    maybe (pure ()) stopHost active
    previousCore <- readIORef (loadedCore session)
    let rebuild = not (isJust active) || previousCore /= Just (coreRevision source)
        route = if rebuild then "cabal-core-and-repl" else "ghci-reload"
    (repl, compilerOutput) <-
      if rebuild
        then do
          discardInterpreter session
          new <- mask $ \restore -> do
            created <- openRepl (options session)
            writeIORef (interpreter session) (Just created)
            restore (pure created)
          loaded <- command new 600 ":set prompt \"\"\n:set prompt-cont \"\"\n:show modules"
          pure (new, loaded)
        else case active of
          Just existing -> (existing,) <$> command existing 600 ":reload"
          Nothing -> fail "No interpreter for reload"
    compiled <- getMonotonicTimeNSec
    -- Fence both outcomes: A -> invalid B -> A must not pin B's failure to A.
    current <- snapshot (options session)
    if not (sameGeneration current source)
      then superseded rebuild route
      else do
        -- Dependencies are trusted only after an unchanged generation. Keeping
        -- them after a genuine gameplay error allows repair in this same GHCi.
        writeIORef (loadedCore session) (Just (coreRevision source))
        if not (checked compilerOutput)
          then do
            status
              session
              "failed"
              [ ("revision", JString (revision source)),
                ("route", JString route),
                ("compileMs", elapsedMs detected compiled),
                ("error", JString "Source did not load successfully. Fix compiler.log diagnostics; no new host started")
              ]
            pure AwaitEdit
          else do
            startHost repl (options session) (revision source)
            state <- waitReady (port (options session)) (revision source)
            ready <- getMonotonicTimeNSec
            latest <- snapshot (options session)
            if not (sameGeneration latest source)
              then stopHost repl >> superseded rebuild route
              else do
                runtime <- either fail pure (jsonAt ["shell", "runtimeId"] state)
                authority <- either fail pure (jsonAt ["shell", "session", "authority"] state)
                status
                  session
                  "http-ready"
                  [ ("revision", JString (revision source)),
                    ("runtimeId", runtime),
                    ("authority", authority),
                    ("mode", JString "Paused"),
                    ("route", JString route),
                    ("compileMs", elapsedMs detected compiled),
                    ("hostReadyMs", elapsedMs compiled ready),
                    ("detectionToReadyMs", elapsedMs detected ready),
                    ("renderedMs", JNull),
                    ("inputMs", JNull),
                    ("url", JString ("http://127.0.0.1:" ++ show (port (options session)) ++ "/#dev"))
                  ]
                pure AwaitEdit
  case result of
    Right outcome -> pure outcome
    Left problem -> do
      discardInterpreter session
      status session "failed" [("revision", JString (revision source)), ("error", JString (displayException problem))]
      pure AwaitEdit
  where
    superseded rebuild route = do
      -- A superseded core build may contain transient B despite final source A.
      when rebuild (discardInterpreter session)
      status session "superseded" [("revision", JString (revision source)), ("route", JString route)]
      pure SourceSuperseded

openRepl :: Options -> IO Repl
openRepl opts = mask_ $
  bracketOnError (openAppendArtifact logPath) closeQuiet $ \logHandle -> do
    startOffset <- IO.hFileSize logHandle
    let config = maybe [] (\path -> ["--config-file=" ++ path]) (cabalConfig opts)
        args =
          config
            ++ [ "repl",
                 "--project-file=" ++ project opts,
                 "--builddir=" ++ maybe (buildDir opts </> "dist") id (distDir opts),
                 "--disable-multi-repl",
                 "exe:red-dune-dev",
                 "--repl-options=-ignore-dot-ghci"
               ]
        spec =
          (Proc.proc (cabal opts) args)
            { Proc.cwd = Just (root opts),
              Proc.std_in = Proc.CreatePipe,
              Proc.std_out = Proc.UseHandle logHandle,
              Proc.std_err = Proc.UseHandle logHandle,
              Proc.create_group = True,
              Proc.close_fds = True
            }
    -- Creation and ownership registration stay masked. Any synchronous setup
    -- failure kills the whole new group before unwinding the log bracket.
    bracketOnError (Proc.createProcess spec) abortAcquisition $ \(stdinHandle, _, _, child) -> do
      IO.hClose logHandle
      stdinPipe <- maybe (fail "Cabal stdin pipe was not created") pure stdinHandle
      pid <- Proc.getPid child
      IO.hSetBuffering stdinPipe IO.LineBuffering
      IO.hSetEncoding stdinPipe IO.utf8
      live <- newIORef False
      counter <- newIORef 0
      offset <- newIORef startOffset
      pure (Repl child pid stdinPipe logPath (buildDir opts </> "command.done") offset live counter)
  where
    logPath = buildDir opts </> "compiler.log"
    abortAcquisition handles@(_, _, _, child) = do
      pid <- Proc.getPid child
      maybe (pure ()) (ignoreIO . P.signalProcessGroup P.sigKILL) pid
      Proc.cleanupProcess handles

-- Completion uses a private file, never stdout: Debug.Trace and concurrent host
-- prints cannot corrupt the acknowledgment. GHCi flushes stdout/stderr before
-- writing the exact token. Only then do we read NEW compiler-log bytes, so a
-- previous successful load cannot stand in for a failed current compilation.
command :: Repl -> Int -> String -> IO String
command repl seconds expression = do
  validateArtifact (completionPath repl)
  count <- readIORef (commandCounter repl)
  writeIORef (commandCounter repl) (count + 1)
  stamp <- getMonotonicTimeNSec
  let marker = "RED_DUNE_COMMAND_" ++ show stamp ++ "_" ++ show count
      acknowledge =
        ":module + System.IO\nSystem.IO.hFlush System.IO.stdout >> System.IO.hFlush System.IO.stderr >> System.IO.writeFile "
          ++ show (completionPath repl)
          ++ " "
          ++ show marker
  IO.hPutStrLn (input repl) (expression ++ "\n" ++ acknowledge)
  IO.hFlush (input repl)
  completed <- timeout (seconds * 1000000) (awaitToken (C.pack marker))
  unless (isJust completed) (fail "GHCi command timed out; see compiler.log")
  readCompilerOutput repl
  where
    awaitToken marker = do
      token <- tryIOError (BS.readFile (completionPath repl))
      if token == Right marker
        then pure ()
        else do
          exited <- Proc.getProcessExitCode (process repl)
          when (isJust exited) (fail "GHCi exited; see compiler.log")
          threadDelay 5000
          awaitToken marker

readCompilerOutput :: Repl -> IO String
readCompilerOutput repl = do
  validateArtifact (compilerLogPath repl)
  IO.withBinaryFile (compilerLogPath repl) IO.ReadMode $ \handle -> do
    begin <- readIORef (outputOffset repl)
    end <- IO.hFileSize handle
    when (end < begin || end - begin > 67108864) (fail "Compiler log was truncated or exceeded 64 MiB per command")
    IO.hSeek handle IO.AbsoluteSeek begin
    bytes <- BS.hGet handle (fromInteger (end - begin))
    writeIORef (outputOffset repl) end
    pure (T.unpack (T.decodeUtf8With lenientDecode bytes))

checked :: String -> Bool
checked compilerOutput = any loaded (lines compilerOutput) && not (commandFailed compilerOutput)
  where
    loaded line = "Ok, " `isPrefixOf` line && any (`isSuffixOf` line) [" modules loaded.", " module loaded."]

commandFailed :: String -> Bool
commandFailed contents = any (`isInfixOf` contents) ["Failed,", "error:", "*** Exception:"]

startHost :: Repl -> Options -> String -> IO ()
startHost repl opts digest = do
  -- 'show' emits Haskell string literals, including quotes, slashes, Unicode
  -- and control characters. JSON quoting is not Haskell-string quoting.
  let packArg = maybe "Nothing" (\path -> "(Just " ++ show path ++ ")") (pack opts)
      expression =
        "dev <- Main.start "
          ++ show digest
          ++ " "
          ++ show (port opts)
          ++ " "
          ++ show (buildDir opts </> "saves")
          ++ " "
          ++ show (root opts </> "references/red-dune-live/ui")
          ++ " "
          ++ packArg
  writeIORef (hostMayRun repl) True
  response <- command repl 30 expression
  when (commandFailed response) (fail ("Host start failed: " ++ response))

stopHost :: Repl -> IO ()
stopHost repl = do
  live <- readIORef (hostMayRun repl)
  when live $ do
    response <- command repl 10 "Main.stop dev"
    when (commandFailed response) (fail ("Host shutdown was not verified: " ++ response))
    writeIORef (hostMayRun repl) False

closeRepl :: Repl -> IO ()
closeRepl repl = mask_ (graceful `finally` forceAndReap)
  where
    graceful = do
      result <- tryIOError $ do
        stopHost repl
        IO.hPutStrLn (input repl) ":quit"
        IO.hFlush (input repl)
        completed <- timeout 5000000 (Proc.waitForProcess (process repl))
        unless (isJust completed) (fail "GHCi did not quit")
      case result of
        Right () -> pure ()
        Left _ -> signalGroup P.sigTERM
      -- Cabal can exit before a descendant. Close that whole group too.
      signalGroup P.sigTERM
      void (timeout 2000000 (Proc.waitForProcess (process repl)))
    -- This finalizer also runs when the FIRST Ctrl-C interrupts outermost
    -- session cleanup. Only force-kill/reap/close are uninterruptible; graceful
    -- commands and timeouts above remain cancellable. SIGKILL makes the wait a
    -- reap rather than an open-ended request for cooperative termination.
    forceAndReap = uninterruptibleMask_ $ do
      signalGroup P.sigKILL
      void (Proc.waitForProcess (process repl)) `finally` closeQuiet (input repl)
    signalGroup signal = maybe (pure ()) (ignoreIO . P.signalProcessGroup signal) (groupId repl)

closeQuiet :: IO.Handle -> IO ()
closeQuiet = ignoreIO . IO.hClose

ignoreIO :: IO () -> IO ()
ignoreIO action = void (tryIOError action)

observe :: Int -> IO JSON
observe listenPort = do
  result <- timeout 1000000 $ bracket (N.socket N.AF_INET N.Stream N.defaultProtocol) N.close $ \socket -> do
    N.connect socket (loopback listenPort)
    N.sendAll socket (C.pack ("GET /api/state HTTP/1.1\r\nHost: 127.0.0.1:" ++ show listenPort ++ "\r\nConnection: close\r\n\r\n"))
    bytes <- receive socket 0 []
    let (headers, body) = BS.breakSubstring "\r\n\r\n" bytes
    unless ("HTTP/1.1 200 " `BS.isPrefixOf` headers && not (BS.null body)) (fail "Readiness returned a non-200/malformed HTTP response")
    decoded <- either (fail . show) pure (T.decodeUtf8' (BS.drop 4 body))
    either fail pure (parseJSON (T.unpack decoded))
  maybe (fail "Readiness HTTP timeout") pure result
  where
    receive socket size chunks = do
      chunk <- N.recv socket 65536
      if BS.null chunk
        then pure (BS.concat (reverse chunks))
        else do
          let total = size + BS.length chunk
          when (total > 16777216) (fail "Readiness response exceeded 16 MiB")
          receive socket total (chunk : chunks)

waitReady :: Int -> String -> IO JSON
waitReady listenPort digest = do
  started <- getMonotonicTimeNSec
  let attempt = do
        observed <- tryIOError (observe listenPort)
        case observed of
          Right state -> do
            actual <- either fail pure (jsonAt ["shell", "devRevision"] state >>= string)
            mode <- either fail pure (jsonAt ["view", "mode"] state >>= string)
            unless (actual == digest) (fail "Port answered with another source revision; refusing stale ready")
            unless (mode == "Paused") (fail "New development campaign did not start paused")
            pure state
          Left _ -> do
            now <- getMonotonicTimeNSec
            when (now - started > 15000000000) (fail "Host readiness timed out; see compiler.log")
            threadDelay 25000
            attempt
  attempt

jsonAt :: [String] -> JSON -> Either String JSON
jsonAt [] value = Right value
jsonAt (name : rest) value = object value >>= field name >>= jsonAt rest

wallNs :: IO Integer
wallNs = floor . (* 1000000000) <$> getPOSIXTime

elapsedMs :: Word64 -> Word64 -> JSON
elapsedMs begin end = JInteger (toInteger ((end - begin) `div` 1000000))

status :: Session -> String -> [(String, JSON)] -> IO ()
status session phase details = do
  now <- getMonotonicTimeNSec
  wall <- wallNs
  let record = encodeJSON (obj (("phase", JString phase) : ("monotonicMs", JInteger (toInteger (now `div` 1000000))) : ("wallTimeNs", JInteger wall) : details))
      destination = buildDir (options session) </> "status.json"
  IO.hPutStrLn (events session) record
  IO.hFlush (events session)
  bracketOnError
    (IO.openBinaryTempFile (buildDir (options session)) "status.json.")
    (\(temp, handle) -> closeQuiet handle >> ignoreIO (removeFile temp))
    $ \(temp, handle) -> do
      BS.hPut handle (T.encodeUtf8 (T.pack (record ++ "\n")))
      IO.hClose handle
      renameFile temp destination
  putStrLn record
  IO.hFlush IO.stdout
