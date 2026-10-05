{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Local browser host. The game owns all rules. One MVar orders clock ticks,
-- player actions and completion adoption; HTTP readers never advance the game.
module RedDune.Host (HostConfig (..), runHost, runHostLifecycleTests) where

import Colony.JSON qualified as J
import Colony.Presentation (arr, encodeJSON, num, obj, str)
import Colony.World (CoreMode (..), branchId, worldAuthority, worldId, worldMode, worldRuleset)
import Control.Concurrent (forkFinally, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.DeepSeq (force)
import Control.Exception
import Control.Monad (forever, unless, void, when)
import Data.ByteString qualified as B
import Data.ByteString.Char8 qualified as C
import Data.Char (isAlphaNum, toLower)
import Data.IORef
import Data.List (isSuffixOf, nubBy, sort)
import Data.Map.Strict qualified as M
import Data.Maybe (fromMaybe)
import Data.Set qualified as S
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket
import Network.Socket.ByteString qualified as N
import RedDune.ContentPack (ContentPack, defaultPack)
import RedDune.Game
import RedDune.GameSave
import System.Directory
import System.FilePath ((</>))
import System.IO
import System.Posix.Files (getSymbolicLinkStatus, isRegularFile)
import System.Posix.IO
import System.Posix.Unistd (fileSynchronise)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data HostConfig = HostConfig {hostPort :: !Int, hostStore :: !FilePath, hostUI :: !FilePath}

data Owner = Owner {ownerClient :: !String, ownerSeen :: !Word64}

data Load
  = NoLoad
  | Reading !String !String !Word64 !Word64
  | Preview !String !String !Word64 !Word64 !GameState
  | Activating !String !String !Word64 !Word64
  | Terminal !String !String !String

data Completion
  = Saved !String !Word64 !Word64 !(Either String J.JSON)
  | ReadFinished !String !(Either String GameState)
  | Activated !String !Word64 !Word64 !(Either String (GameState, J.JSON))
  | CatalogFinished !(Either String ([J.JSON], [String]))

data Receipt = Receipt !String !J.JSON !J.JSON

data Host = Host
  { currentGame :: !GameState,
    currentEpoch :: !Word64,
    responseSerial :: !Word64,
    runtimeId :: !String,
    owner :: !(Maybe Owner),
    speed :: !Int,
    savedRevision :: !(Maybe (Word64, Word64)),
    saveStatus :: !J.JSON,
    saving :: !Bool,
    savePending :: !Bool,
    workers :: !Int,
    loadState :: !Load,
    catalog :: ![J.JSON],
    catalogStatus :: !String,
    catalogError :: !(Maybe String),
    catalogWarnings :: ![String],
    requestReceipts :: !(M.Map String Receipt),
    receiptOrder :: ![String],
    requestHighWater :: !(M.Map String Integer),
    fault :: !(Maybe String),
    lastAutosave :: !Word64
  }

data Env = Env {config :: !HostConfig, host :: !(MVar Host), completed :: !(MVar [Completion]), beforeIO :: !(String -> IO ())}

leaseNanos :: Word64
leaseNanos = 4000000000

freshId :: IO String
freshId = do
  bytes <- withBinaryFile "/dev/urandom" ReadMode (\h -> B.hGet h 16)
  unless (B.length bytes == 16) (ioError (userError "Entropy source returned short data"))
  let raw = concatMap (\b -> [hex !! fromIntegral (b `div` 16), hex !! fromIntegral (b `mod` 16)]) (B.unpack bytes)
  pure (take 8 raw ++ "-" ++ take 4 (drop 8 raw) ++ "-4" ++ take 3 (drop 13 raw) ++ "-a" ++ take 3 (drop 17 raw) ++ "-" ++ drop 20 raw)
  where
    hex = "0123456789abcdef"

runHost :: HostConfig -> ContentPack -> IO ()
runHost cfg pack = do
  unless (hostPort cfg >= 1024 && hostPort cfg <= 65535) (fail "Port must be 1024..65535")
  createDirectoryIfMissing True (hostStore cfg)
  -- POSIX advisory lock is released by the OS even after process death.
  bracket (openFd (hostStore cfg </> ".host.lock") ReadWrite defaultFileFlags {creat = Just 0o600, nofollow = True, cloexec = True}) closeFd $ \lock -> do
    setLock lock (WriteLock, AbsoluteSeek, 0, 0)
    ident <- freshId
    template <- either fail pure (startGame "settlement" pack)
    reservedBranch <- reserveBranch cfg (branchId (gameWorld template))
    game <- either fail pure (reidentifyGameToBranch ident reservedBranch template)
    initialEntry <- writeCheckpoint cfg ident game
    now <- getMonotonicTimeNSec
    state <- newMVar (freshHost ident game initialEntry now)
    box <- newMVar []
    let env = Env cfg state box (const (pure ()))
    bracket (forkIO (ticker env)) killThread $ \_ -> withSocketsDo $
      bracket (socket AF_INET Stream defaultProtocol) close $ \listener -> do
        setSocketOption listener ReuseAddr 1
        bind listener (SockAddrInet (fromIntegral (hostPort cfg)) (tupleToHostAddress (127, 0, 0, 1)))
        listen listener 32
        slots <- newQSem 32
        putStrLn ("Red Dune live: http://127.0.0.1:" ++ show (hostPort cfg) ++ "/")
        putStrLn ("Checkpoints: " ++ hostStore cfg ++ "; loopback only; close the page to pause")
        hFlush stdout
        forever $ do
          waitQSem slots
          (conn, _) <- accept listener `onException` signalQSem slots
          void $ forkFinally (serve env conn) (\_ -> close conn `finally` signalQSem slots)

freshHost :: String -> GameState -> J.JSON -> Word64 -> Host
freshHost ident game initialEntry now =
  Host
    { currentGame = game,
      currentEpoch = 1,
      responseSerial = 0,
      runtimeId = ident,
      owner = Nothing,
      speed = 1,
      savedRevision = Just (1, gameRevision game),
      saveStatus = savedJSON initialEntry,
      saving = False,
      savePending = False,
      workers = 0,
      loadState = NoLoad,
      catalog = [initialEntry],
      catalogStatus = "idle",
      catalogError = Nothing,
      catalogWarnings = [],
      requestReceipts = M.empty,
      receiptOrder = [],
      requestHighWater = M.empty,
      fault = Nothing,
      lastAutosave = now
    }

pauseGame :: Host -> Host
pauseGame h | worldMode (gameWorld (currentGame h)) /= Active = h
pauseGame h = case applyAction (obj [("op", str "pause")]) (currentGame h) of
  Left _ -> h
  Right (g, _) -> h {currentGame = g}

-- Unexpected failures are terminal for this runtime. Never resume a partially
-- understood state after a protocol/core exception; checkpoints stay intact.
safely :: Env -> (Host -> IO Host) -> IO ()
safely env action = modifyMVar_ (host env) $ \h ->
  action h `catch` \(e :: SomeException) ->
    case fromException e :: Maybe AsyncException of
      Just _ -> throwIO e
      Nothing -> pure (pauseGame h) {fault = Just (displayException e), owner = Nothing}

ticker :: Env -> IO ()
ticker env = forever $ do
  threadDelay 50000
  safely env $ \old -> do
    events <- swapMVar (completed env) []
    ready <- foldCompletions old events
    now <- getMonotonicTimeNSec
    let connected = maybe False (\o -> now - ownerSeen o < leaseNanos) (owner ready)
        live = if connected then ready else (pauseGame ready) {owner = Nothing}
    next <-
      if connected && fault live == Nothing && not (loading (loadState live))
        then case advanceGame (speed live) (currentGame live) of
          Left err -> pure (pauseGame live) {fault = Just err, owner = Nothing}
          Right g -> evaluate (force g) >>= \strict -> pure live {currentGame = strict}
        else pure live
    let auto = connected && now - lastAutosave next >= 30000000000 && dirty next && not (loading (loadState next))
        queued = next {savePending = savePending next || auto, lastAutosave = if auto then now else lastAutosave next}
    if savePending queued && not (saving queued) && workers queued < 2 && not (loading (loadState queued))
      then startSave env queued
      else pure queued
  where
    foldCompletions h [] = pure h
    foldCompletions h (event : rest) = adopt h event >>= \next -> foldCompletions next rest
    adopt previous event =
      let h = previous {workers = max 0 (workers previous - 1)}
       in case event of
            Saved _ epoch revision result -> pure $ case result of
              Left err -> h {saving = False, saveStatus = if epoch == currentEpoch h then saveFailureWith (saveStatus h) err else saveStatus h}
              Right entry ->
                h
                  { saving = False,
                    catalog = mergeCatalog [entry] (catalog h),
                    savedRevision = if epoch == currentEpoch h then Just (epoch, revision) else savedRevision h,
                    saveStatus = if epoch == currentEpoch h then savedJSON entry else saveStatus h
                  }
            CatalogFinished result -> pure $ case result of
              Left err -> h {catalogStatus = "failed", catalogError = Just err}
              Right (entries, warnings) -> h {catalogStatus = "ready", catalogError = Nothing, catalogWarnings = warnings, catalog = mergeCatalog (catalog h) entries}
            ReadFinished token result -> pure $ case loadState h of
              Reading active entry epoch revision | active == token -> case result of
                Left err -> h {loadState = Terminal "failed" token err}
                Right g -> h {loadState = Preview token entry epoch revision g}
              _ -> h
            Activated token epoch revision result -> pure $ case loadState h of
              Activating active _ _ _ | active == token && epoch == currentEpoch h && revision == gameRevision (currentGame h) -> case result of
                Left err -> h {loadState = Terminal "failed" token err}
                Right (g, entry) ->
                  h
                    { currentGame = g,
                      currentEpoch = currentEpoch h + 1,
                      loadState = Terminal "activated" token "Checkpoint activated; time is paused",
                      savedRevision = Just (currentEpoch h + 1, gameRevision g),
                      saveStatus = savedJSON entry,
                      savePending = False,
                      catalog = mergeCatalog [entry] (catalog h),
                      requestReceipts = M.empty,
                      receiptOrder = [],
                      requestHighWater = M.empty
                    }
              _ -> h

loading :: Load -> Bool
loading Reading {} = True
loading Preview {} = True
loading Activating {} = True
loading _ = False

dirty :: Host -> Bool
dirty h = savedRevision h /= Just (currentEpoch h, gameRevision (currentGame h))

saveFailureWith :: J.JSON -> String -> J.JSON
saveFailureWith previous reason = obj [("status", str "failed"), ("error", str reason), ("lastSuccess", lastSuccess previous)]

lastSuccess :: J.JSON -> J.JSON
lastSuccess (J.JObject fields) = M.findWithDefault J.JNull "lastSuccess" fields
lastSuccess _ = J.JNull

savedJSON :: J.JSON -> J.JSON
savedJSON entry = obj [("status", str "saved"), ("lastSuccess", entry), ("error", J.JNull)]

spawnWork :: Env -> IO Completion -> IO ()
spawnWork env work = void $ forkIO $ work >>= \event -> modifyMVar_ (completed env) (pure . (++ [event]))

attemptIO :: IO a -> IO (Either String a)
attemptIO action =
  (Right <$> action) `catch` \(e :: SomeException) -> case fromException e :: Maybe AsyncException of
    Just _ -> throwIO e
    Nothing -> pure (Left (displayException e))

startSave :: Env -> Host -> IO Host
startSave env h = do
  ident <- freshId
  let captured = currentGame h; epoch = currentEpoch h; revision = gameRevision captured
  spawnWork env $ Saved ident epoch revision <$> attemptIO (beforeIO env "save" >> writeCheckpoint (config env) ident captured)
  pure h {saving = True, savePending = False, workers = workers h + 1, saveStatus = obj [("status", str "writing"), ("capturedRevision", num revision), ("lastSuccess", lastSuccess (saveStatus h))]}

checkpointEntry :: String -> GameState -> J.JSON
checkpointEntry ident g =
  let w = gameWorld g
   in obj
        [ ("id", str ident),
          ("label", str ("Campaign " ++ ident)),
          ("kind", str "committed"),
          ("world", num (worldId w)),
          ("branch", num (branchId w)),
          ("tick", numTick g),
          ("sequence", num (gameRevision g)),
          ("schema", str "live-1"),
          ("ruleset", str (worldRuleset w)),
          ("actions", arr [obj [("id", str "restore"), ("label", str "Restore as a fresh branch")]]),
          ("warnings", arr [])
        ]

numTick :: GameState -> J.JSON
numTick g = case observeGame g of
  J.JObject fields -> fromMaybe J.JNull $ do J.JObject view <- M.lookup "view" fields; M.lookup "tick" view
  _ -> J.JNull

-- Store-wide branch allocation is durable before any authority becomes visible.
-- Gaps after cancelled activation are intentional; numbers are never reused.
reserveBranch :: HostConfig -> Word64 -> IO Word64
reserveBranch cfg source = do
  let counterPath = hostStore cfg </> ".branch-counter"
  exists <- doesFileExist counterPath
  previous <-
    if not exists
      then do
        names <- listDirectory (hostStore cfg)
        when (any (isSuffixOf ".rdg") names) (fail "Branch counter is missing from an existing store; refusing to reuse branch identities")
        pure 1
      else do
        text <- withBinaryFile counterPath ReadMode (\h -> C.hGet h 64)
        case readMaybe (C.unpack text) :: Maybe Integer of
          Just n | n > 0 && n < toInteger (maxBound :: Word64) && show n == C.unpack text -> pure (fromInteger n)
          _ -> fail "Invalid branch counter; refusing to reuse branch identities"
  let highest = max source previous
  when (highest == maxBound) (fail "Branch identity exhausted")
  let next = highest + 1; bytes = C.pack (show next)
  bracketOnError
    (openBinaryTempFile (hostStore cfg) ".branch-")
    (\(path, h) -> (hClose h `catch` \(_ :: IOException) -> pure ()) >> (removeFile path `catch` \(_ :: IOException) -> pure ()))
    $ \(path, h) -> do
      B.hPut h bytes
      hFlush h
      fd <- handleToFd h
      fileSynchronise fd `finally` closeFd fd
      readback <- B.readFile path
      unless (readback == bytes) (fail "Branch counter readback mismatch")
      renameFile path counterPath
      bracket (openFd (hostStore cfg) ReadOnly defaultFileFlags {directory = True, nofollow = True, cloexec = True}) closeFd fileSynchronise
  pure next

writeCheckpoint :: HostConfig -> String -> GameState -> IO J.JSON
writeCheckpoint cfg ident game = do
  bytes <- either fail pure (encodeGame game)
  when (B.length bytes > 33554432) (fail "Checkpoint exceeds 32 MiB bound")
  let destination = hostStore cfg </> (ident ++ ".rdg")
  bracketOnError
    (openBinaryTempFile (hostStore cfg) ".capture-")
    (\(path, h) -> (hClose h `catch` \(_ :: IOException) -> pure ()) >> (removeFile path `catch` \(_ :: IOException) -> pure ()))
    $ \(path, h) -> do
      B.hPut h bytes
      hFlush h
      fd <- handleToFd h
      fileSynchronise fd `finally` closeFd fd
      verified <- B.readFile path
      unless (verified == bytes) (fail "Checkpoint readback mismatch")
      void (either fail pure (decodeGame verified))
      renameFile path destination
      bracket (openFd (hostStore cfg) ReadOnly defaultFileFlags {directory = True, nofollow = True, cloexec = True}) closeFd fileSynchronise
  pure (checkpointEntry ident game)

validId :: String -> Bool
validId ident = length ident == 36 && and [if i `elem` [8, 13, 18, 23] then c == '-' else c `elem` ("0123456789abcdef" :: String) | (i, c) <- zip [0 :: Int ..] ident]

readCheckpoint :: HostConfig -> String -> IO GameState
readCheckpoint cfg ident = do
  unless (validId ident) (fail "Invalid checkpoint identity")
  let path = hostStore cfg </> (ident ++ ".rdg")
  status <- getSymbolicLinkStatus path
  unless (isRegularFile status) (fail "Checkpoint is not a regular file")
  bracket (openFd path ReadOnly defaultFileFlags {nofollow = True, cloexec = True} >>= fdToHandle) hClose $ \sourceHandle -> do
    bytes <- B.hGet sourceHandle 33554433
    unless (not (B.null bytes) && B.length bytes <= 33554432) (fail "Checkpoint size outside bounds")
    either fail pure (decodeGame bytes)

readCatalog :: HostConfig -> IO ([J.JSON], [String])
readCatalog cfg = do
  names <- listDirectory (hostStore cfg)
  let ids = take 256 [take 36 name | name <- reverse (sort names), length name == 40, ".rdg" `isSuffixOf` name, validId (take 36 name)]
  -- A damaged checkpoint remains untouched and cannot silently become playable.
  results <- mapM (\ident -> attemptIO (checkpointEntry ident <$> readCheckpoint cfg ident)) ids
  pure ([entry | Right entry <- results], take 16 ["Unreadable checkpoint retained: " ++ err | Left err <- results])

mergeCatalog :: [J.JSON] -> [J.JSON] -> [J.JSON]
mergeCatalog recent older = take 256 (nubBy sameEntry (recent ++ older))
  where
    sameEntry (J.JObject first) (J.JObject second) = M.lookup "id" first == M.lookup "id" second
    sameEntry first second = first == second

loadJSON :: Host -> J.JSON
loadJSON h = case loadState h of
  NoLoad -> base "idle" Nothing Nothing "" Nothing
  Reading token entry _ _ -> base "reading" (Just token) (Just entry) "Validating complete campaign checkpoint" Nothing
  Preview token entry _ _ g ->
    base
      "preview"
      (Just token)
      (Just entry)
      "Nothing has been applied"
      ( Just
          ( obj
              [ ("source", checkpointEntry entry g),
                ("target", checkpointEntry "fresh branch on confirmation" g),
                ("changes", arr [str "Fresh authority and branch; the old checkpoint remains intact"]),
                ("preserved", arr [str "World, policies, campaign evidence, authored content and receipts"]),
                ("dirtyCurrent", J.JBool (dirty h)),
                ("warning", str "Unsaved progress on the current branch will not be carried across")
              ]
          )
      )
  Activating token entry _ _ -> base "activating" (Just token) (Just entry) "Saving the validated new branch before activation" Nothing
  Terminal status token message -> base status (Just token) Nothing message Nothing
  where
    base status token entry message preview =
      obj
        [ ("status", str status),
          ("ticket", maybe J.JNull str token),
          ("entry", maybe J.JNull str entry),
          ("action", str "restore"),
          ("message", str message),
          ("error", if status == "failed" then str message else J.JNull),
          ("preview", fromMaybe J.JNull preview)
        ]

snapshot :: String -> J.JSON -> Host -> J.JSON
snapshot client result h =
  let w = gameWorld (currentGame h); fields = case observeGame (currentGame h) of J.JObject f -> f; _ -> M.empty
   in J.JObject $
        M.union
          ( M.fromList
              [ ("result", result),
                ( "shell",
                  obj
                    [ ("schema", str "red-dune-shell-0.5"),
                      ("runtimeId", str (runtimeId h)),
                      ("responseSerial", num (responseSerial h)),
                      ("session", obj [("authority", str (worldAuthority w)), ("epochCounter", num (currentEpoch h)), ("world", num (worldId w)), ("branch", num (branchId w)), ("ruleset", str (worldRuleset w)), ("dirty", J.JBool (dirty h))]),
                      ("catalog", obj [("status", str (catalogStatus h)), ("entries", arr (catalog h)), ("warnings", arr (map str (catalogWarnings h))), ("error", maybe J.JNull str (catalogError h))]),
                      ("load", loadJSON h),
                      ("warnings", arr (maybe [] (\x -> [str x]) (fault h)))
                    ]
                ),
                ("save", obj [("current", saveStatus h), ("pending", J.JBool (saving h || savePending h))]),
                ( "runtime",
                  obj
                    [ ("speed", num (speed h)),
                      ("owner", str (case owner h of Nothing -> "none"; Just o | ownerClient o == client -> "mine"; _ -> "other")),
                      ("leaseMs", str "4000"),
                      ("workers", num (workers h)),
                      ("fault", maybe J.JNull str (fault h))
                    ]
                )
              ]
          )
          fields

ok :: String -> J.JSON
ok status = obj [("status", str status)]

rejected :: String -> String -> J.JSON
rejected status reason = obj [("status", str status), ("reason", str reason)]

getString :: String -> M.Map String J.JSON -> Either String String
getString key fields = J.field key fields >>= J.string

-- Every mutation has a bounded transport identity. If the TCP response is lost,
-- resend exactly that body/requestId; it cannot create a second command.
request :: Env -> String -> String -> Maybe J.JSON -> IO J.JSON
request env client path body = modifyMVar (host env) $ \h -> do
  now <- getMonotonicTimeNSec
  (next, result) <- case (path, body) of
    ("/api/state", Nothing) -> pure (h, ok "observed")
    ("/api/claim", _) | validClient client -> case owner h of
      Just o | ownerClient o /= client && now - ownerSeen o < leaseNanos -> pure (h, rejected "ownershipRejected" "Another tab owns this campaign. Close it or wait for its lease to expire")
      _ -> pure ((pauseGame h) {owner = Just (Owner client now)}, ok "ownershipGranted")
    _ | not (owned client now h) -> pure (h, rejected "ownershipRejected" "Claim control before sending actions")
    ("/api/heartbeat", _) -> pure (h {owner = Just (Owner client now)}, ok "heartbeat")
    ("/api/release", _) -> pure ((pauseGame h) {owner = Nothing}, ok "released")
    _ | Just faultMessage <- fault h -> pure (h, rejected "runtimeFault" faultMessage)
    (_, Just (J.JObject fields)) -> case validateEnvelope h fields of
      Left err -> pure (h, rejected "sessionRejected" err)
      Right (ident, counter) -> case M.lookup ident (requestReceipts h) of
        Just (Receipt previousPath previous receipt)
          | previousPath == path && previous == J.JObject fields -> pure (h, receipt)
          | otherwise -> pure (h, rejected "identityRejected" "Request ID reused for different content")
        Nothing | counter <= M.findWithDefault 0 client (requestHighWater h) -> pure (h, rejected "identityRejected" "This request predates retained receipts; it will never execute again")
        Nothing | M.size (requestHighWater h) >= 256 && M.notMember client (requestHighWater h) -> pure (h, rejected "identityRejected" "Session controller budget exhausted; save and restart the host")
        Nothing -> do
          dispatched <- try (dispatch env path (foldr M.delete fields ["requestId", "requestCounter", "runtimeId", "sessionEpoch", "clientId"]) h)
          (changed, receipt) <- case dispatched of
            Right pair -> pure pair
            Left (e :: SomeException) -> case fromException e :: Maybe AsyncException of
              Just _ -> throwIO e
              Nothing -> pure ((pauseGame h) {fault = Just (displayException e), owner = Nothing}, rejected "runtimeFault" (displayException e))
          let order = take 1024 (ident : receiptOrder changed)
              retained = S.fromList order
              receipts = M.filterWithKey (\key _ -> S.member key retained) (M.insert ident (Receipt path (J.JObject fields) receipt) (requestReceipts changed))
          pure (changed {requestReceipts = receipts, receiptOrder = order, requestHighWater = M.insert client counter (requestHighWater changed)}, receipt)
    _ -> pure (h, rejected "decodeRejected" "Expected a JSON object")
  let numbered = next {responseSerial = responseSerial h + 1}
  pure (numbered, snapshot client result numbered)
  where
    owned who now h = maybe False (\o -> ownerClient o == who && now - ownerSeen o < leaseNanos) (owner h)

validClient :: String -> Bool
validClient value = length value >= 16 && length value <= 80 && all (\c -> isAlphaNum c || c `elem` ("-_" :: String)) value

validateEnvelope :: Host -> M.Map String J.JSON -> Either String (String, Integer)
validateEnvelope h fields = do
  ident <- getString "requestId" fields
  unless (validClient ident) (Left "Request ID must be 16..80 letters, numbers, dash or underscore")
  runtime <- getString "runtimeId" fields
  epoch <- getString "sessionEpoch" fields
  unless (runtime == runtimeId h && epoch == show (currentEpoch h)) (Left "This request belongs to an old runtime or session")
  raw <- getString "requestCounter" fields
  unless (length raw <= 20) (Left "Request counter exceeds Word64 decimal length")
  counter <- case readMaybe raw :: Maybe Integer of Just value | value > 0 && value <= toInteger (maxBound :: Word64) && show value == raw -> Right value; _ -> Left "Invalid request counter"
  pure (ident, counter)

dispatch :: Env -> String -> M.Map String J.JSON -> Host -> IO (Host, J.JSON)
dispatch env path fields h
  | path == "/api/speed" = case getString "speed" fields of
      Right value | value `elem` ["1", "2", "4"] -> pure (h {speed = if value == "4" then 4 else if value == "2" then 2 else 1}, ok "speedChanged")
      _ -> pure (h, rejected "decodeRejected" "Speed must be 1, 2 or 4")
  | otherwise = case getString "op" fields of
      Left err -> pure (h, rejected "decodeRejected" err)
      Right "frame" -> pure (h, rejected "decodeRejected" "Only the host clock may advance time")
      Right "save" -> pure (h {savePending = True}, ok "saveRequested")
      Right "library"
        | catalogStatus h == "loading" || workers h >= 2 -> pure (h, rejected "catalogRejected" "Catalog is already loading")
        | otherwise -> do spawnWork env (CatalogFinished <$> attemptIO (beforeIO env "catalog" >> readCatalog (config env))); pure (h {catalogStatus = "loading", workers = workers h + 1}, ok "catalogRequested")
      Right "previewLoad" | getString "action" fields /= Right "restore" -> pure (h, rejected "loadRejected" "Only the advertised restore action is supported")
      Right "previewLoad" | not (loading (loadState h)) && workers h < 2 -> case getString "entry" fields of
        Left err -> pure (h, rejected "loadRejected" err)
        Right entry -> do
          token <- freshId
          let paused = pauseGame h
          spawnWork env (ReadFinished token <$> attemptIO (beforeIO env "read" >> readCheckpoint (config env) entry))
          pure (paused {workers = workers paused + 1, loadState = Reading token entry (currentEpoch paused) (gameRevision (currentGame paused))}, obj [("status", str "loadPreviewRequested"), ("ticket", str token)])
      Right "cancelLoad" -> case (getString "ticket" fields, loadState h) of
        (Right token, Reading active _ _ _) | token == active -> cancelled token
        (Right token, Preview active _ _ _ _) | token == active -> cancelled token
        (Right token, Activating active _ _ _) | token == active -> cancelled token
        _ -> pure (h, rejected "loadRejected" "No matching active load ticket")
      Right "activateLoad" -> case (getString "ticket" fields, loadState h) of
        (Right token, Preview active entry epoch revision target)
          | token /= active -> pure (h, rejected "loadRejected" "Unknown load ticket")
          | epoch /= currentEpoch h || revision /= gameRevision (currentGame h) -> pure (h {loadState = Terminal "failed" token "Preview stale; request it again"}, rejected "loadRejected" "PreviewStale")
          | dirty h && M.lookup "discardUnsaved" fields /= Just (J.JBool True) -> pure (h, rejected "loadRejected" "DiscardConfirmationRequired")
          | workers h >= 2 -> pure (h, rejected "loadRejected" "Checkpoint workers are busy; retry shortly")
          | otherwise -> do
              identity <- freshId
              reservedBranch <- reserveBranch (config env) (branchId (gameWorld target))
              spawnWork env $
                Activated token epoch revision
                  <$> attemptIO
                    ( do
                        beforeIO env "activate"
                        restored <- either fail pure (reidentifyGameToBranch identity reservedBranch target)
                        entryJSON <- writeCheckpoint (config env) identity restored
                        pure (restored, entryJSON)
                    )
              pure (h {workers = workers h + 1, loadState = Activating token entry epoch revision, savePending = False}, ok "loadActivationRequested")
        _ -> pure (h, rejected "loadRejected" "No validated load preview")
      Right "restart"
        | getString "scenario" fields `notElem` map Right ["settlement", "recovery"] -> pure (h, rejected "restartRejected" "Choose settlement or recovery explicitly")
        | loading (loadState h) -> pure (h, rejected "shellBusy" "Cancel the active load before restarting")
        | dirty h && M.lookup "discardUnsaved" fields /= Just (J.JBool True) -> pure (h, rejected "restartRejected" "DiscardConfirmationRequired")
        | otherwise -> do
            identity <- freshId
            template <- either fail pure (startGame (either (const "settlement") id (getString "scenario" fields)) (fromMaybe (gamePack (currentGame h)) (gameStagedPack (currentGame h))))
            reservedBranch <- reserveBranch (config env) (branchId (gameWorld template))
            game <- either fail pure (reidentifyGameToBranch identity reservedBranch template)
            committed <- attemptIO (writeCheckpoint (config env) identity game)
            case committed of
              Left err -> pure (h {saveStatus = saveFailureWith (saveStatus h) err}, rejected "restartRejected" ("New campaign was not activated: " ++ err))
              Right entry ->
                pure
                  ( h
                      { currentGame = game,
                        currentEpoch = currentEpoch h + 1,
                        savedRevision = Just (currentEpoch h + 1, gameRevision game),
                        saveStatus = savedJSON entry,
                        catalog = mergeCatalog [entry] (catalog h),
                        requestReceipts = M.empty,
                        receiptOrder = [],
                        requestHighWater = M.empty,
                        savePending = False,
                        loadState = NoLoad
                      },
                    ok "restarted"
                  )
      Right "stagePackText" | not (loading (loadState h)) -> case do
        source <- getString "packText" fields
        expected <- getString "expectedRevision" fields
        packValue <- J.parseJSON source
        applyAction (obj [("op", str "stagePack"), ("expectedRevision", str expected), ("pack", packValue)]) (currentGame h) of
        Left err -> pure (h, rejected "admissionRejected" err)
        Right (g, result) -> evaluate (force g) >>= \strict -> pure (h {currentGame = strict}, result)
      Right _ | loading (loadState h) -> pure (h, rejected "shellBusy" "Finish or cancel the load preview first")
      Right op ->
        let ready = if op == "preview" then pauseGame h else h
         in case applyAction (J.JObject fields) (currentGame ready) of
              Left err -> pure (h, rejected "admissionRejected" err)
              Right (g, result) -> evaluate (force g) >>= \strict -> pure (ready {currentGame = strict}, result)
  where
    cancelled token = pure (h {loadState = Terminal "cancelled" token "Load cancelled; current campaign retained. A completed candidate checkpoint may remain in the catalog"}, ok "loadCancelled")

-- Deliberately narrow HTTP/1.1: one bounded request per connection, no chunked
-- bodies, no proxy headers, no remote bind, exact static asset allowlist.
data HttpRequest = HttpRequest !String !String !(M.Map String String) !B.ByteString

serve :: Env -> Socket -> IO ()
serve env conn = do
  incoming <- timeout 5000000 (readHttp conn)
  (status, mime, payload) <- maybe (pure (failure 408 "Request timeout")) (route env) incoming
  void $ timeout 5000000 $ N.sendAll conn (C.pack ("HTTP/1.1 " ++ show status ++ " " ++ reason status ++ "\r\nContent-Type: " ++ mime ++ "\r\nContent-Length: " ++ show (B.length payload) ++ "\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n") <> payload)
  where
    reason 200 = "OK"; reason 400 = "Bad Request"; reason 403 = "Forbidden"; reason 404 = "Not Found"; reason 408 = "Request Timeout"; reason _ = "Service Unavailable"

jsonBytes :: J.JSON -> B.ByteString
jsonBytes = T.encodeUtf8 . T.pack . encodeJSON

readHttp :: Socket -> IO (Either String HttpRequest)
readHttp conn = headers B.empty
  where
    headers bytes
      | B.length bytes > 8192 = pure (Left "Headers exceed 8 KiB")
      | otherwise = case C.breakSubstring "\r\n\r\n" bytes of
          (_, rest) | B.null rest -> do chunk <- N.recv conn 4096; if B.null chunk then pure (Left "Incomplete request") else headers (bytes <> chunk)
          (headBytes, rest) -> case parseHead headBytes of
            Left err -> pure (Left err)
            Right (method, path, fields, len) -> do
              payload <- body len (B.drop 4 rest)
              pure (HttpRequest method path fields <$> payload)
    body len bytes
      | B.length bytes > len = pure (Left "Trailing/pipelined request bytes are unsupported")
      | B.length bytes == len = pure (Right bytes)
      | otherwise = do chunk <- N.recv conn (min 4096 (len - B.length bytes)); if B.null chunk then pure (Left "Incomplete body") else body len (bytes <> chunk)

parseHead :: B.ByteString -> Either String (String, String, M.Map String String, Int)
parseHead bytes = case map (filter (/= '\r') . C.unpack) (C.lines bytes) of
  first : rows -> do
    (method, path) <- case words first of [m, p, "HTTP/1.1"] | m `elem` ["GET", "POST"] -> Right (m, p); _ -> Left "Only GET/POST HTTP/1.1 are supported"
    unless (length rows <= 40 && all (\c -> fromEnum c >= 32 && fromEnum c < 127) (concat rows)) (Left "Invalid headers")
    pairs <- mapM header rows
    let fields = M.fromList pairs
    unless (M.size fields == length pairs) (Left "Duplicate headers are unsupported")
    when (M.member "transfer-encoding" fields || M.member "expect" fields) (Left "Chunking/Expect are unsupported")
    len <- case M.lookup "content-length" fields of
      Nothing | method == "GET" -> Right 0
      Just raw | not (null raw) && length raw <= 5 && all (`elem` ['0' .. '9']) raw -> maybe (Left "Invalid length") Right (readMaybe raw :: Maybe Int)
      _ -> Left "Content-Length required"
    unless (len <= 65536 && (method /= "GET" || len == 0)) (Left "Body outside bounds")
    pure (method, path, fields, len)
  _ -> Left "Empty request"
  where
    header line = case break (== ':') line of
      (key, ':' : value) | not (null key) && all (\c -> isAlphaNum c || c == '-') key -> Right (map toLower key, dropWhile (== ' ') value)
      _ -> Left "Malformed header"

route :: Env -> Either String HttpRequest -> IO (Int, String, B.ByteString)
route _ (Left err) = pure (failure 400 err)
route env (Right (HttpRequest method path headers bytes))
  | M.lookup "host" headers `notElem` map Just hosts = pure (failure 403 "Host is not this loopback server")
  | maybe False (`notElem` origins) (M.lookup "origin" headers) = pure (failure 403 "Cross-origin requests are forbidden")
  | M.lookup "sec-fetch-site" headers `elem` [Just "cross-site", Just "same-site"] = pure (failure 403 "Cross-site requests are forbidden")
  | method == "GET",
    Just (file, mime) <- M.lookup path assets = do
      result <- attemptIO (B.readFile (hostUI (config env) </> file))
      pure (either (failure 404) (\b -> (200, mime, b)) result)
  | method == "GET" && path == "/api/state" = answer Nothing
  | method == "POST" && path `elem` ["/api/command", "/api/speed", "/api/claim", "/api/heartbeat", "/api/release"] =
      if M.lookup "content-type" headers `notElem` [Just "application/json", Just "application/json;charset=UTF-8"]
        then pure (failure 400 "Content-Type must be application/json")
        else case T.decodeUtf8' bytes of
          Left _ -> pure (failure 400 "Invalid UTF-8")
          Right text -> case J.parseJSON (T.unpack text) of Left err -> pure (failure 400 err); Right value -> answer (Just value)
  | otherwise = pure (failure 404 "Unknown route")
  where
    hosts = ["127.0.0.1:" ++ show (hostPort (config env)), "localhost:" ++ show (hostPort (config env))]
    origins = map ("http://" ++) hosts
    assets = M.fromList [("/", ("index.html", "text/html; charset=utf-8")), ("/app.js", ("app.js", "text/javascript; charset=utf-8")), ("/style.css", ("style.css", "text/css; charset=utf-8")), ("/protocol.js", ("protocol.js", "text/javascript; charset=utf-8"))]
    answer body = do
      let bodyClient = case body of Just (J.JObject f) -> either (const "") id (getString "clientId" f); _ -> ""
          client = M.findWithDefault bodyClient "x-red-dune-client" headers
      result <- attemptIO (request env client path body)
      pure (either (failure 503) (\value -> (200, "application/json; charset=utf-8", jsonBytes value)) result)

failure :: Int -> String -> (Int, String, B.ByteString)
failure status message = (status, "application/json; charset=utf-8", jsonBytes (obj [("error", str message)]))

-- Deterministic native concurrency checks. IO barriers exist only in this direct
-- test entrypoint; no request, environment variable or player input can set one.
runHostLifecycleTests :: IO ()
runHostLifecycleTests = do
  temporary <- getTemporaryDirectory
  ident <- freshId
  let store = temporary </> ("red-dune-lifecycle-" ++ ident)
      cfg = HostConfig 8787 store "ui"
  bracket_ (createDirectory store) (removePathForcibly store) $ do
    template <- either fail pure (startGame "settlement" defaultPack)
    branch <- reserveBranch cfg (branchId (gameWorld template))
    game <- either fail pure (reidentifyGameToBranch ident branch template)
    entry <- writeCheckpoint cfg ident game
    now <- getMonotonicTimeNSec
    state <- newMVar (freshHost ident game entry now)
    box <- newMVar []
    readGate <- newEmptyMVar
    activationGate <- newEmptyMVar
    saveGate <- newEmptyMVar
    counter <- newIORef (0 :: Integer)
    let barrier kind = case kind of "read" -> readMVar readGate; "activate" -> readMVar activationGate; "save" -> readMVar saveGate >> fail "Injected stale save failure"; _ -> pure ()
        env = Env cfg state box barrier
        client = "native-lifecycle-controller"
        submit fields = do
          n <- atomicModifyIORef' counter (\value -> (value + 1, value + 1))
          current <- readMVar state
          request
            env
            client
            "/api/command"
            ( Just
                ( obj
                    ( fields
                        ++ [ ("requestId", str (client ++ "-" ++ show n)),
                             ("requestCounter", num n),
                             ("runtimeId", str (runtimeId current)),
                             ("sessionEpoch", num (currentEpoch current))
                           ]
                    )
                )
            )
        assertTest condition message = unless condition (fail message)
        waitUntil label predicate = do
          found <- timeout 15000000 (let loop = do current <- readMVar state; if predicate current then pure current else threadDelay 10000 >> loop in loop)
          maybe (fail ("Lifecycle timeout: " ++ label)) pure found
        ticketOf current = case loadState current of
          Reading token _ _ _ -> pure token
          Preview token _ _ _ _ -> pure token
          Activating token _ _ _ -> pure token
          _ -> fail "Expected active checkpoint ticket"
    bracket (forkIO (ticker env)) killThread $ \_ -> do
      void (request env client "/api/claim" (Just (obj [])))
      void (submit [("op", str "previewLoad"), ("entry", str ident), ("action", str "restore")])
      reading <- readMVar state
      token <- ticketOf reading
      assertTest (workers reading == 1) "Read must be outstanding at controlled barrier"
      void (submit [("op", str "cancelLoad"), ("ticket", str token)])
      putMVar readGate ()
      drained <- waitUntil "cancelled read" ((== 0) . workers)
      assertTest (currentGame drained == game) "Cancelled read changed current game"
      assertTest (case loadState drained of Terminal "cancelled" _ _ -> True; _ -> False) "Late read completion erased cancellation"
      void (submit [("op", str "previewLoad"), ("entry", str ident), ("action", str "restore")])
      previewed <- waitUntil "validated preview" (\h -> case loadState h of Preview {} -> True; _ -> False)
      activationToken <- ticketOf previewed
      void (submit [("op", str "activateLoad"), ("ticket", str activationToken), ("discardUnsaved", J.JBool True)])
      blocked <- readMVar state
      assertTest (case loadState blocked of Activating {} -> True; _ -> False) "Activation must be outstanding at controlled write barrier"
      assertTest (currentGame blocked == game) "Unwritten candidate became visible"
      void (submit [("op", str "cancelLoad"), ("ticket", str activationToken)])
      void (submit [("op", str "restart"), ("scenario", str "recovery"), ("discardUnsaved", J.JBool True)])
      restarted <- readMVar state
      assertTest (currentEpoch restarted > currentEpoch blocked) "Restart did not establish a new session"
      putMVar activationGate ()
      final <- waitUntil "cancelled candidate write" ((== 0) . workers)
      assertTest (currentGame final == currentGame restarted && currentEpoch final == currentEpoch restarted) "Late cancelled activation replaced restarted game"
      assertTest (branchId (gameWorld (currentGame final)) > branchId (gameWorld game)) "Restart reused an older branch"
      names <- listDirectory store
      assertTest (length (filter (isSuffixOf ".rdg") names) >= 3) "Completed cancelled candidate was not retained safely"
      void (submit [("op", str "save")])
      void (waitUntil "captured save worker" (\h -> saving h && workers h == 1))
      void (submit [("op", str "restart"), ("scenario", str "settlement"), ("discardUnsaved", J.JBool True)])
      newest <- readMVar state
      putMVar saveGate ()
      afterFailure <- waitUntil "stale save failure" ((== 0) . workers)
      assertTest (saveStatus afterFailure == saveStatus newest && currentGame afterFailure == currentGame newest) "Old save failure corrupted new session status"
      void (submit [("op", str "state")])
      lastCounter <- readIORef counter
      retained <- readMVar state
      let oldRequest =
            obj
              [ ("op", str "state"),
                ("requestId", str (client ++ "-" ++ show lastCounter)),
                ("requestCounter", num lastCounter),
                ("runtimeId", str (runtimeId retained)),
                ("sessionEpoch", num (currentEpoch retained))
              ]
      modifyMVar_ state (\h -> pure h {requestReceipts = M.empty, receiptOrder = []})
      evictedReply <- request env client "/api/command" (Just oldRequest)
      let resultStatus = J.object evictedReply >>= J.field "result" >>= J.object >>= getString "status"
      assertTest (resultStatus == Right "identityRejected") "Evicted request identity executed a second time"
      putStrLn "PASS: controlled read cancellation, pre-durability non-publication, activation cancellation, restart while candidate blocked, late completion fencing, retained orphan checkpoint, stale save failure isolation, evicted request rejection"
