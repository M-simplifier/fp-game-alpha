{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Controlled immutable checkpoint selection and pure migration preparation.
-- No function in this module activates a session or claims a save is committed.
-- Linux /proc/self/fd anchors all traversals to nofollow-opened directories.
module Colony.CheckpointLibrary
  ( LibraryConfig (..),
    defaultLibraryConfig,
    LibraryError (..),
    Entry,
    EntryKind (..),
    entryId,
    entryLabel,
    entryKind,
    entryWorldId,
    entryBranchId,
    entryTick,
    entrySequence,
    entrySchema,
    entryRuleset,
    entryActions,
    RestoreAction (..),
    actionId,
    actionLabel,
    parseAction,
    kindId,
    PreparedSource (..),
    listLibrary,
    readEntry,
    prepareEntry,
    prepareCheckpoint,
    reserveBranch,
    BranchSyncPoint (..),
    reserveBranchWithSyncHook,
    withBranchDirectory,
  )
where

import Colony.Codec
import Colony.Content
import Colony.Migrate
import Colony.Ruleset
import Colony.Save
import Colony.Types (SimTick)
import Colony.Units (Resource (Fuel, Ration))
import Colony.World
import Control.DeepSeq (NFData, force)
import Control.Exception (Exception, IOException, bracket, catch, evaluate, throwIO)
import Control.Monad (forM, unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BSC
import Data.List (sort, stripPrefix)
import Data.Map.Strict qualified as M
import Data.Maybe (mapMaybe)
import Data.Typeable (Typeable)
import Data.Word (Word64)
import GHC.Generics (Generic)
import System.Directory (createDirectory, listDirectory, makeAbsolute)
import System.FilePath (splitDirectories, (</>))
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isFullError, isPermissionError)
import System.Posix.Files
  ( FileStatus,
    deviceID,
    fileID,
    fileSize,
    getFdStatus,
    getSymbolicLinkStatus,
    isDirectory,
    isRegularFile,
    modificationTimeHiRes,
    statusChangeTimeHiRes,
  )
import System.Posix.IO (OpenFileFlags (..), OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)
import Text.Read (readMaybe)

data LibraryConfig = LibraryConfig
  { libraryRoot :: !FilePath,
    legacyFlatDirectory :: !(Maybe FilePath),
    compatibilityFixtureDirectory :: !(Maybe FilePath)
  }
  deriving (Eq, Show)

defaultLibraryConfig :: LibraryConfig
defaultLibraryConfig =
  LibraryConfig
    "evidence/ui/save-library"
    (Just "evidence/ui/runtime-saves")
    (Just "evidence/migration-fixtures")

data LibraryError = LibraryError String deriving (Eq, Show, Typeable)

instance Exception LibraryError

data EntryKind = Committed | Candidate | Compatibility deriving (Eq, Ord, Show, Generic)

instance NFData EntryKind

data RestoreAction = Restore | Rules | Balance | RulesBalance deriving (Eq, Ord, Show, Generic)

instance NFData RestoreAction

kindId :: EntryKind -> String
kindId Committed = "committed"
kindId Candidate = "candidate"
kindId Compatibility = "compatibility"

actionId :: RestoreAction -> String
actionId Restore = "restore"
actionId Rules = "rules"
actionId Balance = "balance"
actionId RulesBalance = "rulesBalance"

actionLabel :: RestoreAction -> String
actionLabel Restore = "同ルールで新しい枝へ復元"
actionLabel Rules = "現在のキャンセル・返却ルールへ移行"
actionLabel Balance = "調理バランスv2へ移行"
actionLabel RulesBalance = "現在のルールと調理バランスv2へ移行"

parseAction :: String -> Maybe RestoreAction
parseAction s = lookup s [(actionId a, a) | a <- [Restore, Rules, Balance, RulesBalance]]

-- The constructor, path, directory identity, file identity and hash are private.
-- No retained World/payload: every public summary is forced before construction.
data Entry = Entry
  { entryId :: !String,
    entryLabel :: !String,
    entryKind :: !EntryKind,
    entryWorldId :: !Word64,
    entryBranchId :: !Word64,
    entryTick :: !SimTick,
    entrySequence :: !Word64,
    entrySchema :: !Word64,
    entryRuleset :: !String,
    entryActions :: ![RestoreAction],
    privateDirectory :: !FilePath,
    privateFilename :: !FilePath,
    privateDirectoryIdentity :: !(Integer, Integer),
    privateFileIdentity :: !(Integer, Integer, Integer, Rational, Rational),
    privateHash :: !BS.ByteString
  }
  deriving (Eq)

instance Show Entry where show e = "CheckpointEntry " ++ show (entryId e)

data PreparedSource = PreparedSource
  { preparedWorld :: !World,
    preparedSourceSchema :: !Word64,
    preparedSourceBranch :: !Word64,
    preparedChanges :: ![String],
    preparedPreserved :: ![String]
  }
  deriving (Eq, Show)

guardLibrary :: Bool -> String -> Either LibraryError ()
guardLibrary b message = unless b (Left (LibraryError message))

codec :: Either CodecError a -> Either LibraryError a
codec = either (Left . LibraryError . show) Right

require :: Bool -> String -> IO ()
require b message = unless b (throwIO (LibraryError message))

tryLibrary :: IO a -> IO (Either LibraryError a)
tryLibrary work =
  (Right <$> work)
    `catch` (pure . Left :: LibraryError -> IO (Either LibraryError a))
    `catch` (\(e :: SaveFailure) -> pure (Left (LibraryError (saveError e))))
    `catch` (\(e :: IOException) -> pure (Left (LibraryError (ioErrorLabel e))))
  where
    saveError (StorageIO kind _) = "Checkpoint storage I/O failure: " ++ show kind
    saveError (InvalidStorage message) = message
    saveError (InvalidSnapshot message) = message
    saveError _ = "Checkpoint storage validation failed"
    ioErrorLabel e
      | isDoesNotExistError e = "Checkpoint directory or file is missing"
      | isPermissionError e = "Checkpoint directory or file permission denied"
      | isFullError e = "Checkpoint storage is full"
      | otherwise = "Checkpoint filesystem operation failed (including invalid or symbolic-link paths)"

fdPath :: Fd -> FilePath
fdPath fd = "/proc/self/fd/" ++ show fd

openDirectory :: FilePath -> IO Fd
openDirectory path = openFd path ReadOnly defaultFileFlags {directory = True, nofollow = True, cloexec = True}

-- Reject traversal in configuration before makeAbsolute. Each component is
-- opened relative to the previous pinned fd. A concurrent parent replacement
-- can neither make us follow its symlink nor redirect a child operation.
withDirectory :: Bool -> FilePath -> (FilePath -> Fd -> IO a) -> IO a
withDirectory create path action = do
  require (not (null path) && '\0' `notElem` path && ".." `notElem` splitDirectories path) "Invalid library path"
  absolute <- makeAbsolute path
  let components = filter (`notElem` ["/", ".", ""]) (splitDirectories absolute)
  bracket (openDirectory "/") closeFd $ \root -> walk absolute root components
  where
    walk absolute fd [] = action absolute fd
    walk absolute fd (name : rest) = do
      let child = fdPath fd </> name
      when create $ do
        createDirectory child `catch` (\(e :: IOException) -> if isAlreadyExistsError e then pure () else throwIO e)
        -- Sync existing components as well: they may have been left by an
        -- earlier failed/uncertain mkdir+sync attempt in this process tree.
        bracket (openDirectory child) closeFd fileSynchronise
        fileSynchronise fd
      bracket (openDirectory child) closeFd $ \next -> walk absolute next rest

identityOf :: FileStatus -> (Integer, Integer)
identityOf s = (toInteger (deviceID s), toInteger (fileID s))

fileIdentity :: FileStatus -> (Integer, Integer, Integer, Rational, Rational)
fileIdentity s =
  ( toInteger (deviceID s),
    toInteger (fileID s),
    toInteger (fileSize s),
    toRational (modificationTimeHiRes s),
    toRational (statusChangeTimeHiRes s)
  )

canonicalId :: String -> String -> Maybe Word64
canonicalId prefix name = do
  digits <- stripPrefix prefix name
  n <- readMaybe digits
  if n > 0 && name == prefix ++ show n then Just n else Nothing

actionsFor :: String -> Either LibraryError [RestoreAction]
actionsFor rules = do
  (catalog, cancellation) <- either (Left . LibraryError) Right (rulesetProfile rules)
  pure
    ( [Restore]
        ++ [Rules | cancellation /= ResourceAggregateSplit]
        ++ [Balance | catalog == CatalogV1]
        ++ [RulesBalance | catalog == CatalogV1 && not (isM1Ruleset rules)]
    )

-- Legacy sources are validated with the actual schema decoder. Their summaries
-- come from explicit LegacyCore, never from a newly synthesized current World.
data Summary = Summary !Word64 !Word64 !SimTick !Word64 !Word64 !String

sourceSummary :: BS.ByteString -> Either LibraryError Summary
sourceSummary bytes = case decodeCheckpoint bytes of
  Right (meta, w) -> Right (Summary (worldId w) (branchId w) (simTick w) (checkpointSequence meta) (checkpointSchemaFor w) (worldRuleset w))
  Left currentError -> case decodeLegacyEnvelope bytes of
    Left legacyError -> Left (LibraryError ("Invalid checkpoint: " ++ show currentError ++ "; " ++ show legacyError))
    Right (schema, _) -> do
      c <- if schema == 1 then v1Core <$> codec (decodeLegacyV1 bytes) else v2Core <$> codec (decodeLegacyV2 bytes)
      -- Validation includes the real sequential migration, including capacity,
      -- fresh-lot/grace overflow and reservation splitting failures.
      let temporary = if legacyBranchId c == 1 then 2 else 1
      _ <- codec (migrateLegacyBytes temporary bytes)
      pure (Summary (legacyWorldId c) (legacyBranchId c) (legacyTick c) 0 schema (legacyRuleset c))

entryFromBytes :: FilePath -> Fd -> FilePath -> EntryKind -> String -> BS.ByteString -> IO Entry
entryFromBytes directory fd name kind label bytes = do
  Summary world branch tick sequenceNo schema rules <- either throwIO pure (sourceSummary bytes)
  actions <- either throwIO pure (actionsFor rules)
  require (world > 0 && branch > 0) "Checkpoint world and branch IDs must be nonzero"
  status <- getSymbolicLinkStatus (fdPath fd </> name)
  require (isRegularFile status) "Checkpoint is not a regular file"
  directoryStatus <- getFdStatus fd
  let digest = sha256 bytes
      ident = "entry-" ++ sha256Hex (BSC.pack (show (identityOf directoryStatus, fileIdentity status, name, kind)) <> digest)
  -- Deep evaluation of all projected fields severs lazy references to decoded
  -- source objects; it does not force or retain a whole World in the catalog.
  (ident', label', rules', actions') <- evaluate (force (ident, label, rules, actions))
  pure
    ( Entry
        ident'
        label'
        kind
        world
        branch
        tick
        sequenceNo
        schema
        rules'
        actions'
        directory
        name
        (identityOf directoryStatus)
        (fileIdentity status)
        digest
    )

checkpointCap :: Integer
checkpointCap = toInteger (maxPayloadBytes defaultDecodeLimits)

listLibrary :: LibraryConfig -> Bool -> IO (Either LibraryError ([Entry], [String]))
listLibrary config includeCompatibility = tryLibrary $ do
  registered <- optionalDirectory (libraryRoot config) $ \absolute fd -> do
    names <- sort <$> listDirectory (fdPath fd)
    pieces <- forM names $ \name -> case canonicalId "world-" name of
      Nothing -> pure ([], ["Ignored malformed world directory"])
      Just world -> safePiece ("World " ++ show world) $ withDirectory False (absolute </> name) $ \worldPath worldFd -> do
        branches <- sort <$> listDirectory (fdPath worldFd)
        results <- forM branches $ \branchName -> case canonicalId "branch-" branchName of
          Nothing -> pure ([], ["Ignored malformed branch directory"])
          Just branch ->
            safePiece ("World " ++ show world ++ ", branch " ++ show branch) $
              generations (worldPath </> branchName) (Just (world, branch))
        pure (combine results)
    pure (combine pieces)
  legacy <- maybe (pure ([], [])) (\path -> optionalDirectory path (\absolute _ -> generations absolute Nothing)) (legacyFlatDirectory config)
  examples <- if includeCompatibility then maybe (pure ([], [])) fixtures (compatibilityFixtureDirectory config) else pure ([], [])
  pure (combine [registered, legacy, examples])
  where
    combine xs = (concatMap fst xs, concatMap snd xs)
    safePiece label work = tryLibrary work >>= either (\e -> pure ([], [label ++ ": " ++ show e])) pure
    optionalDirectory path work =
      (withDirectory False path work)
        `catch` (\(e :: IOException) -> if isDoesNotExistError e then pure ([], []) else throwIO e)
    generations directory expected = withDirectory False directory $ \absolute fd -> do
      report <- recoverCheckpoints (fdPath fd)
      let chosen = [(Committed, g) | g <- recoveryCommitted report] ++ [(Candidate, g) | g <- recoveryCandidates report]
      pieces <- forM chosen $ \(kind, g) -> safePiece ("Generation " ++ show (checkpointSequence (generationMeta g))) $ do
        let name = generationFile g
        bytes <- readBounded checkpointCap (fdPath fd </> name)
        require (sha256 bytes == generationHash g) "Generation changed during enumeration"
        _ <- loadGeneration (fdPath fd) g
        case expected of
          Just (w, b) -> require (generationWorldId g == w && generationBranchId g == b) "Generation does not match registered world/branch directory"
          Nothing -> pure ()
        let label =
              (if expected == Nothing then "Legacy save directory · " else "")
                ++ kindId kind
                ++ " · world "
                ++ show (generationWorldId g)
                ++ " · branch "
                ++ show (generationBranchId g)
                ++ " · tick "
                ++ show (generationTick g)
                ++ " · generation "
                ++ show (checkpointSequence (generationMeta g))
        e <- entryFromBytes absolute fd name kind label bytes
        pure ([e], [])
      let rejected = ["Rejected generation: checksum, schema, rules/catalog or filesystem validation failed" | _ <- recoveryRejected report]
          manifest = maybe [] (const ["Manifest missing or invalid; uncommitted verified generations are recovery candidates"]) (recoveryManifestProblem report)
          (entries, warnings) = combine pieces
      pure (entries, warnings ++ rejected ++ manifest)
    fixtures directory = optionalDirectory directory $ \absolute fd -> do
      pieces <- forM [("running-wip-v1.cbor", 1 :: Word64), ("running-wip-v2.cbor", 2)] $ \(name, schema) ->
        safePiece ("Compatibility example V" ++ show schema) $ do
          bytes <- readBounded checkpointCap (fdPath fd </> name)
          e <-
            entryFromBytes
              absolute
              fd
              name
              Compatibility
              ("Prerelease compatibility example V" ++ show schema ++ " · running production")
              bytes
          require (entrySchema e == schema) "Compatibility fixture schema does not match its registered label"
          pure ([e], [])
      pure (combine pieces)

readEntry :: Entry -> IO (Either LibraryError BS.ByteString)
readEntry entry = tryLibrary $ withDirectory False (privateDirectory entry) $ \_ fd -> do
  status <- getFdStatus fd
  require (identityOf status == privateDirectoryIdentity entry) "Selected directory was replaced"
  let path = fdPath fd </> privateFilename entry
      verify = do
        current <- getSymbolicLinkStatus path
        require (isRegularFile current && fileIdentity current == privateFileIdentity entry) "Selected checkpoint was replaced or modified"
  verify
  bytes <- readBounded checkpointCap path
  verify
  require (sha256 bytes == privateHash entry) "Selected checkpoint hash changed"
  pure bytes

prepareEntry :: Entry -> RestoreAction -> Word64 -> BS.ByteString -> Either LibraryError PreparedSource
prepareEntry entry action newBranch bytes = do
  guardLibrary (sha256 bytes == privateHash entry) "Prepared bytes differ from the selected checkpoint"
  guardLibrary (action `elem` entryActions entry) "Restore action was not advertised for this checkpoint"
  guardLibrary (newBranch > 0 && newBranch /= entryBranchId entry) "Restore requires a distinct nonzero branch"
  Summary world branch tick sequenceNo schema rules <- sourceSummary bytes
  guardLibrary
    ( (world, branch, tick, sequenceNo, schema, rules)
        == (entryWorldId entry, entryBranchId entry, entryTick entry, entrySequence entry, entrySchema entry, entryRuleset entry)
    )
    "Selected checkpoint summary mismatch"
  prepareCheckpoint action newBranch bytes

-- Pure archive transformation shared by controlled selection and explicit trace
-- replay. No Entry or filesystem authority is manufactured by this function.
prepareCheckpoint :: RestoreAction -> Word64 -> BS.ByteString -> Either LibraryError PreparedSource
prepareCheckpoint action newBranch bytes = do
  Summary _ branch _ _ schema rules <- sourceSummary bytes
  actions <- actionsFor rules
  guardLibrary (action `elem` actions) "Restore action is unsupported for source profile"
  guardLibrary (newBranch > 0 && newBranch /= branch) "Restore requires a distinct nonzero branch"
  (original, schemaChanges) <-
    if schema `elem` [3, 4]
      then do
        (_, w) <- codec (decodeCheckpoint bytes)
        pure (w, [])
      else do
        migrated <- codec (migrateLegacyBytes newBranch bytes)
        -- Give subsequent pure transformations the archived source branch as their
        -- comparison identity. No transient branch is written or activated.
        pure ((migrationWorld migrated) {branchId = branch}, migrationRulesChanged (migrationReport migrated))
  balanced <-
    if action `elem` [Balance, RulesBalance]
      then do
        oldCook <- either (Left . LibraryError) Right (lookupRecipe (worldContent original) "cook")
        let nextCook = oldCook {recipeInputs = M.insert Fuel 800 (recipeInputs oldCook), recipeOutputs = M.insert Ration 19000 (recipeOutputs oldCook)}
            nextContent = (worldContent original) {contentRecipes = M.insert "cook" nextCook (contentRecipes (worldContent original))}
        codec (applyCookBalanceV2 newBranch nextContent original)
      else Right original {branchId = newBranch}
  -- A direct registered-profile selection composes the cancellation floor and
  -- split-return corrections without allocating fake intermediate branches.
  -- Exact canonical validation runs before and after, preserving all other fields.
  targetRules <-
    if action `elem` [Rules, RulesBalance]
      then do
        (catalog, _) <- either (Left . LibraryError) Right (rulesetProfile (worldRuleset balanced))
        pure (case catalog of CatalogV1 -> "red-dune-reference-4"; CatalogV2 -> "red-dune-reference-5")
      else Right (worldRuleset balanced)
  let target = balanced {worldRuleset = targetRules}
  _ <- codec (canonicalWorldBytes target)
  let changes =
        ["New immutable branch; source checkpoint bytes remain unchanged"]
          ++ schemaChanges
          ++ ["Cook catalog v2: future starts use Fuel 800 and Ration 19000; existing snapshots are unchanged" | action `elem` [Balance, RulesBalance]]
          ++ ["Cancellation uses resource-aggregate loss and exact split return placement (current profile " ++ targetRules ++ ")" | action `elem` [Rules, RulesBalance]]
      preserved =
        [ "Physical assets and owners",
          "Running recipe snapshots, content IDs and work progress",
          "Residents, maintenance, power, transport and destinations",
          "Game tick, boundary and RNG state",
          "Command high-water marks, receipts and event history",
          "Archived authority and participant roles until explicit Session activation"
        ]
  pure (PreparedSource (force target) schema branch (force changes) (force preserved))

reserveBranch :: LibraryConfig -> Word64 -> Word64 -> IO (Either LibraryError (Word64, FilePath))
reserveBranch = reserveBranchWithSyncHook (const (pure ()))

-- Explicit development fault points around real fsync calls; the production
-- allocator never injects faults. A failure must leave the reservation in place.
data BranchSyncPoint
  = BeforeBranchSync
  | AfterBranchSync
  | BeforeBranchParentSync
  | AfterBranchParentSync
  deriving (Eq, Ord, Show)

reserveBranchWithSyncHook ::
  (BranchSyncPoint -> IO ()) ->
  LibraryConfig ->
  Word64 ->
  Word64 ->
  IO (Either LibraryError (Word64, FilePath))
reserveBranchWithSyncHook hook config world minimumSourceBranch = tryLibrary $ do
  require (world > 0) "World ID must be nonzero"
  require (minimumSourceBranch < maxBound) "Branch ID space exhausted"
  withDirectory True (libraryRoot config) $ \absolute rootFd -> do
    let worldName = "world-" ++ show world
        worldPath = fdPath rootFd </> worldName
    createDirectory worldPath `catch` (\(e :: IOException) -> if isAlreadyExistsError e then pure () else throwIO e)
    bracket (openDirectory worldPath) closeFd $ \worldFd -> do
      fileSynchronise worldFd
      fileSynchronise rootFd
      allocate (absolute </> worldName) worldFd
  where
    allocate absolute fd = do
      names <- listDirectory (fdPath fd)
      let malformed = [n | n <- names, canonicalId "branch-" n == Nothing]
      require (null malformed) "Malformed name in controlled branch directory"
      -- Validate even old reservations. Symlink reservations are never followed
      -- or overwritten; refusing is preferable to trusting a corrupt registry.
      mapM_ (\name -> bracket (openDirectory (fdPath fd </> name)) closeFd (\child -> getFdStatus child >>= \s -> require (isDirectory s) "Invalid branch reservation")) names
      let used = mapMaybe (canonicalId "branch-") names
          high = maximum (minimumSourceBranch : used)
      require (high < maxBound) "Branch ID space exhausted"
      let next = high + 1
          name = "branch-" ++ show next
          target = fdPath fd </> name
      created <- (createDirectory target >> pure True) `catch` (\(e :: IOException) -> if isAlreadyExistsError e then pure False else throwIO e)
      if not created
        then allocate absolute fd
        else do
          -- A failed sync leaves the reservation in place. Never delete/reuse an
          -- uncertain name. This is fsync API evidence, not a power-cut proof.
          bracket (openDirectory target) closeFd $ \branchFd -> do
            hook BeforeBranchSync
            fileSynchronise branchFd
            hook AfterBranchSync
          hook BeforeBranchParentSync
          fileSynchronise fd
          hook AfterBranchParentSync
          pure (next, absolute </> name)

-- Run a local branch writer under a pinned, nofollow-opened directory chain.
-- The callback path is ephemeral and must not escape this bracket. Appending
-- dot leaves a real final directory component for Save's own O_NOFOLLOW checks.
withBranchDirectory ::
  LibraryConfig ->
  Word64 ->
  Word64 ->
  (FilePath -> IO a) ->
  IO (Either LibraryError a)
withBranchDirectory config world branch action = tryLibrary $ do
  require (world > 0 && branch > 0) "World and branch IDs must be nonzero"
  withDirectory False (libraryRoot config) $ \_ rootFd ->
    bracket (openDirectory (fdPath rootFd </> ("world-" ++ show world))) closeFd $ \worldFd ->
      bracket (openDirectory (fdPath worldFd </> ("branch-" ++ show branch))) closeFd $ \branchFd ->
        action (fdPath branchFd </> ".")
