{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The optional, one-shot terminal example. A game authored from a brief need
-- not use this template. Source selection is an explicit distribution contract;
-- neither an installed executable nor a neighboring checkout is its source root.
module FpGame.Create
  ( CreateOptions (..),
    planProject,
    createProject,
  )
where

import Control.Exception (IOException, bracket, catch, mask_, throwIO)
#ifndef mingw32_HOST_OS
import Control.Exception (bracketOnError)
#endif
import Control.Monad (forM, forM_, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Char (isControl, toLower)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import FpGame.Error (ErrorCode (..), ToolError (..), failTool)
import FpGame.Path (selectProject)
import FpGame.Process (Capture (Captured), ProcessRequest (..), execute)
import FpGame.Result (Result (..))
import Numeric (showHex)
import System.Directory
  ( canonicalizePath,
    createDirectory,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    findExecutable,
    makeAbsolute,
    pathIsSymbolicLink,
    removeFile,
  )
import System.FilePath
  ( equalFilePath,
    isAbsolute,
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
#endif
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Info qualified as Platform
#ifdef mingw32_HOST_OS
import qualified System.Win32.File as Win32
#else
import System.IO (hClose)
import qualified System.Posix.IO as Posix
import qualified System.Posix.Files as Posix
#endif

-- | Raw CLI input. It is validated once into the private template and license
-- choices before any source is read or any directory is created.
data CreateOptions = CreateOptions
  { createSlug :: String,
    createDestination :: FilePath,
    createTitle :: Maybe String,
    createTarget :: String,
    createRendering :: String,
    createLicense :: String,
    createAuthor :: Maybe String
  }
  deriving (Eq, Show)

data GameLicense = Unlicensed | MIT String

data ValidOptions = ValidOptions
  { gameSlug :: String,
    gameTitle :: String,
    gameLicense :: GameLicense
  }

type Files = Map.Map FilePath BS.ByteString

data PreparedProject = PreparedProject
  { preparedDestination :: FilePath,
    preparedFiles :: Files,
    preparedInputs :: Files,
    preparedSource :: FilePath,
    preparedLicense :: String,
    preparedDownloads :: Value
  }

-- | Read and validate the complete distribution without creating directories.
planProject :: FilePath -> CreateOptions -> IO Value
planProject source options = do
  prepared <- prepareProject source options
  pure $
    object
      [ "status" .= ("planned" :: String),
        "exit_code" .= (0 :: Int),
        "destination" .= preparedDestination prepared,
        "template" .= templateName,
        "target" .= ("native" :: String),
        "rendering" .= ("terminal" :: String),
        "game_license" .= preparedLicense prepared,
        "files" .= fileHashes (preparedFiles prepared),
        "baseline_downloads" .= preparedDownloads prepared,
        "prerequisites" .= prerequisites,
        "mutates" .= False,
        "next" .= ("scaffold, then build/test/run and implement the agreed game mechanic" :: String)
      ]

-- | Reserve a previously nonexistent root and create every file exclusively.
-- Failure may leave a partial directory and an incomplete marker; no failed
-- creation is automatically deleted or regenerated over. The marker is useful
-- recovery information, not a claim of crash consistency or disk durability.
createProject :: FilePath -> CreateOptions -> IO Value
createProject source options = do
  prepared <- prepareProject source options
  verifyInputs prepared
  let destination = preparedDestination prepared
      marker = destination </> ".scaffold-incomplete"
  ensureDirectory (takeDirectory destination)
  rejectLinks destination
  mask_ $ do
    createDirectory destination `catch` destinationCreationError destination
    writeExclusive marker "Scaffolding has not completed.\n"
  forM_ (Map.toAscList (preparedFiles prepared)) $ \(relative, content) -> do
    checkRelativeName relative
    let path = destination </> relative
    unless (within destination path) $
      failTool UnsafePath "Generated path escaped the new project."
    ensureDirectory (takeDirectory path)
    rejectLinks path
    writeExclusive path content
  rejectLinks marker
  removeFile marker
  pure $
    object
      [ "status" .= ("created" :: String),
        "exit_code" .= (0 :: Int),
        "destination" .= destination,
        "files" .= Map.size (preparedFiles prepared),
        "next" .= ("Enter the game directory; build/test/play, then continue with $game-dev." :: String)
      ]

prepareProject :: FilePath -> CreateOptions -> IO PreparedProject
prepareProject source options = do
  validated <- either throwIO pure (validateOptions options)
  sourceRoot <- checkedSourceRoot source
  destination <- checkedDestination sourceRoot (createDestination options)
  templateExists <- doesDirectoryExist (sourceRoot </> "templates" </> templateName)
  unless templateExists $
    failTool InvalidProject "This game already owns its editable source. Continue development here; the optional template is available only in the foundation checkout."
  let selected = templateSources <> foundationSources <> ["LICENSE"]
  inputs <- readSelection sourceRoot selected
  templated <- renderTemplate validated inputs
  foundation <- renderFoundation inputs
  (revision, state) <- sourceProvenance sourceRoot
  downloads <- baselineDownloads inputs
  let sourceState = case state of
        Nothing -> "no-git-metadata" :: String
        Just "" -> "clean-commit"
        Just _ -> "modified-checkout"
      lock =
        object
          [ "schema" .= (1 :: Int),
            "upstream" .= ("https://github.com/M-simplifier/fp-game-alpha" :: String),
            "upstream_commit" .= revision,
            "distribution" .= ("vendored-source" :: String),
            "source_state" .= sourceState,
            "packages" .= object ["game-transition" .= ("0.1.0.0" :: String), "game-arena" .= ("0.1.0.0" :: String)],
            "sha256_lf" .= fileHashes foundation
          ]
  generated <- generatedFiles validated inputs lock
  files <- mergeFiles [templated, foundation, generated]
  let manifest =
        object
          [ "schema" .= (1 :: Int),
            "template_version" .= ("0.1.0" :: String),
            "files" .= fileHashes files,
            "scope" .= ("Initial scaffold identity. User edits are expected; never regenerate to upgrade." :: String)
          ]
  pure
    PreparedProject
      { preparedDestination = destination,
        preparedFiles = Map.insert "scaffold-manifest.json" (jsonBytes manifest) files,
        preparedInputs = inputs,
        preparedSource = sourceRoot,
        preparedLicense = licenseName (gameLicense validated),
        preparedDownloads = downloads
      }

validateOptions :: CreateOptions -> Either ToolError ValidOptions
validateOptions options = do
  let slug = createSlug options
      parts = Text.splitOn "-" (Text.pack slug)
      lowerAscii c = c >= 'a' && c <= 'z'
      digit c = c >= '0' && c <= '9'
      validPart part = not (Text.null part) && Text.all (\c -> lowerAscii c || digit c) part && Text.any lowerAscii part
      validStart = case slug of
        c : _ -> lowerAscii c
        [] -> False
      title = case createTitle options of
        Nothing -> slug
        Just "" -> slug
        Just value -> value
  unless (validStart && length slug <= 64 && all validPart parts && slug `notElem` ["base", "game-transition", "game-arena"]) $
    invalid InvalidArguments "Use a lowercase Cabal slug, such as my-adventure."
  when (windowsDeviceName slug) $
    invalid InvalidArguments "Choose a portable Cabal slug; Windows device names such as con, nul, com1 and lpt1 cannot be game names."
  validateLine "Title" title
  unless (createTarget options == "native" && createRendering options == "terminal") $
    invalid UnsupportedRoute "This optional example implements native/terminal only. Author a separate game and host for another brief; no substitute template is generated."
  license <- case createLicense options of
    "unlicensed" -> pure Unlicensed
    "MIT" -> case createAuthor options of
      Just author | not (null author) -> pure (MIT author)
      _ -> invalid InvalidArguments "An MIT game license needs an explicit author/credit name."
    _ -> invalid InvalidArguments "Game license must be unlicensed or MIT."
  forM_ (createAuthor options) (validateLine "Author")
  pure ValidOptions {gameSlug = slug, gameTitle = title, gameLicense = license}

validateLine :: String -> String -> Either ToolError ()
validateLine label value =
  when (length value > 120 || any isControl value) $
    invalid InvalidArguments (label <> " must be one line of at most 120 characters.")

invalid :: ErrorCode -> String -> Either ToolError a
invalid code = Left . ToolError code . Text.pack

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

windowsDeviceName :: String -> Bool
windowsDeviceName name =
  map toLower name `elem` (["con", "prn", "aux", "nul"] <> [prefix <> show number | prefix <- ["com", "lpt"], number <- [1 :: Int .. 9]])

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

readSelection :: FilePath -> [FilePath] -> IO Files
readSelection root names = do
  when (length names /= Map.size (Map.fromList [(name, ()) | name <- names])) $
    failTool InvalidConfig "The reviewed source distribution contains duplicate entries."
  Map.fromList
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

verifyInputs :: PreparedProject -> IO ()
verifyInputs prepared = forM_ (Map.toAscList (preparedInputs prepared)) $ \(name, expected) -> do
  current <- readSource (preparedSource prepared) name
  unless (current == expected) $
    failTool SourceChanged ("Source changed while preparing the scaffold: " <> name)

-- Normalize all reviewed textual source to LF before hashing or distributing.
sourceText :: Files -> FilePath -> IO Text.Text
sourceText files name = case Map.lookup name files of
  Nothing -> failTool InvalidConfig ("Missing reviewed source entry: " <> name)
  Just bytes -> case Text.decodeUtf8' bytes of
    Left _ -> failTool InvalidConfig ("Reviewed source is not UTF-8: " <> name)
    Right value -> pure (Text.replace "\r\n" "\n" value)

renderTemplate :: ValidOptions -> Files -> IO Files
renderTemplate options inputs =
  Map.fromList
    <$> forM
      templateSources
      ( \source -> do
          content <- sourceText inputs source
          let originalName = drop (length ("templates/" <> templateName <> "/")) source
              name = case originalName of
                "game.cabal.tmpl" -> gameSlug options <> ".cabal"
                "skills/game-dev/SKILL.md.tmpl" -> ".agents/skills/game-dev/SKILL.md"
                _ -> Text.unpack (fromMaybe (Text.pack originalName) (Text.stripSuffix ".tmpl" (Text.pack originalName)))
              substitutions =
                [ ("SLUG", Text.pack (gameSlug options)),
                  ("TITLE", Text.pack (gameTitle options)),
                  ("GAME_LICENSE", Text.pack (licenseDescription (gameLicense options))),
                  ("CABAL_LICENSE", if licenseName (gameLicense options) == "MIT" then "MIT" else "NONE")
                ]
              adaptedTemplate = case name of
                "README.md" -> nativeReadme content
                "docs/DEVELOPMENT.md" -> content <> "\n## Native core tooling\n\nThe complete reviewed Haskell CLI source travels in `tools/haskell/`; it is independent of the foundation checkout. Use the bootstrap commands in the [README](../README.md) once, then `.build/tools/fp-game build`, `test`, `check`, and `run`. On Windows the executable is `.build/tools/fp-game.exe`. See [native tooling](native-tooling.md) for source ownership, setup and the optional legacy adapters. Formatter setup remains a separate, explicit Python helper.\n"
                _ -> content
              rendered = substituteTokens (Map.fromList substitutions) adaptedTemplate
          pure (name, Text.encodeUtf8 rendered)
      )

-- Only scan the template. A user-supplied title that looks like a token must
-- remain literal, rather than being interpreted by a later replacement pass.
substituteTokens :: Map.Map Text.Text Text.Text -> Text.Text -> Text.Text
substituteTokens substitutions source =
  let (prefix, opening) = Text.breakOn "{{" source
      (name, closing) = Text.breakOn "}}" (Text.drop 2 opening)
   in if Text.null opening || Text.null closing
        then source
        else
          prefix
            <> Map.findWithDefault ("{{" <> name <> "}}") name substitutions
            <> substituteTokens substitutions (Text.drop 2 closing)

nativeReadme :: Text.Text -> Text.Text
nativeReadme content =
  let nativeCommands = Text.replace "python tools/fp_game.py " ".build/tools/fp-game " content
      bootstrap = "## Build the native tooling once\n\nThe game builds with GHC's bundled packages and the vendored kernels. The CLI has its own reviewed, pinned source and dependencies under `tools/haskell/`. On Linux/macOS run `sh tools/bootstrap-fp-game.sh --download`; on Windows first select the verified real versioned compiler as described in [native tooling](docs/native-tooling.md), then run `powershell -File tools/bootstrap-fp-game.ps1 -Download -CompilerPath $compiler` and set the game's `cabal.project.local` choice. This explicitly downloads the pinned CLI dependencies. With those dependencies already cached, omit `--download` / `-Download` for an offline bootstrap. The machine-local compiler choice is ignored by Git and must be selected again on another machine; never overwrite an existing choice. No Python is needed for the native core commands. On Windows use `.build/tools/fp-game.exe`. Read [native tooling](docs/native-tooling.md) for setup details and optional legacy adapters.\n\nAfter bootstrapping, run the native executable from this game directory:\n\n"
   in Text.replace "```sh\n.build/tools/fp-game doctor" (bootstrap <> "```sh\n.build/tools/fp-game doctor") nativeCommands

renderFoundation :: Files -> IO Files
renderFoundation inputs =
  Map.fromList
    <$> forM
      foundationSources
      ( \source -> do
          content <- sourceText inputs source
          let name = if "libraries/" `isPrefixOf` source then "vendor/" <> drop (length ("libraries/" :: String)) source else source
              adjusted =
                if "docs/practice/" `isPrefixOf` source
                  then Text.replace "[移植記録](../README.md)" "[上流のMIT表記](../LICENSE.upstream)" content
                  else content
          pure (name, Text.encodeUtf8 adjusted)
      )

mergeFiles :: [Files] -> IO Files
mergeFiles = go Map.empty
  where
    go combined [] = pure combined
    go combined (files : rest)
      | Map.null (Map.intersection combined files) = go (Map.union combined files) rest
      | otherwise = failTool InvalidConfig "The generated distribution would overwrite one of its own files."

generatedFiles :: ValidOptions -> Files -> Value -> IO Files
generatedFiles options inputs lock = do
  foundationLicense <- sourceText inputs "LICENSE"
  let license = gameLicense options
      ownLicense = case license of
        Unlicensed -> ("LICENSE.game.txt", "No game license has been chosen. No license is granted for your additions by this file. Foundation and original template notices remain separate.\n")
        MIT author -> ("LICENSE", Text.replace "2026 Masaya Shirasawa" (Text.pack ("2026 " <> author)) foundationLicense)
      notice = "# License scope\n\nThe original template and foundation source represented by the initial scaffold hashes retain their MIT notices in licenses/ and vendor/. Your subsequent game code, content and assets are yours; their license is a separate decision. The game license selection is: " <> Text.pack (licenseDescription license) <> ".\n"
      config =
        object
          [ "schema" .= (1 :: Int),
            "slug" .= gameSlug options,
            "template" .= templateName,
            "target" .= ("native" :: String),
            "rendering" .= ("terminal" :: String),
            "source_dirs" .= (["src", "vendor/game-transition/src", "vendor/game-arena/src"] :: [String]),
            "default_executable" .= gameSlug options,
            "game_license" .= licenseName license
          ]
      texts =
        [ ("licenses/FOUNDATION-MIT.txt", foundationLicense),
          ("NOTICE.md", notice),
          ownLicense,
          (".gitignore", ".build/\ndist-newstyle/\n__pycache__/\n*.hi\n*.o\n*.exe\ncabal.project.local\ndata/\n"),
          (".gitattributes", "* text=auto eol=lf\n"),
          ("hie.yaml", "cradle:\n  cabal:\n"),
          (".github/workflows/game.yml", gameWorkflow (gameSlug options))
        ]
  pure $ Map.fromList (map (\(name, text) -> (name, Text.encodeUtf8 text)) texts <> [("fp-game.json", jsonBytes config), ("foundation.lock.json", jsonBytes lock)])

licenseName :: GameLicense -> String
licenseName Unlicensed = "unlicensed"
licenseName (MIT _) = "MIT"

licenseDescription :: GameLicense -> String
licenseDescription Unlicensed = "not chosen; no license granted for your additions"
licenseDescription (MIT _) = "MIT"

fileHashes :: Files -> Map.Map FilePath String
fileHashes = Map.map (concatMap hexByte . BS.unpack . SHA256.hash)
  where
    hexByte byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits

jsonBytes :: Value -> BS.ByteString
jsonBytes value = BL.toStrict (encode value) <> "\n"

-- A relocated source snapshot inside an unrelated Git repository must not
-- accidentally record that parent's commit as its own upstream revision.
sourceProvenance :: FilePath -> IO (Maybe String, Maybe String)
sourceProvenance root = probe `catch` unavailable
  where
    probe = do
      reported <- gitOutput root ["rev-parse", "--show-toplevel"]
      metadataRoot <- traverse canonicalizePath reported
      if maybe False (equalFilePath root) metadataRoot
        then do
          revision <- gitOutput root ["rev-parse", "HEAD"]
          state <- gitOutput root ["status", "--porcelain"]
          pure (revision, state)
        else pure (Nothing, Nothing)
    unavailable :: IOException -> IO (Maybe String, Maybe String)
    unavailable _ = pure (Nothing, Nothing)

gitOutput :: FilePath -> [String] -> IO (Maybe String)
gitOutput root arguments = do
  executable <- findExecutable "git"
  case executable of
    Nothing -> pure Nothing
    Just git -> do
      project <- selectProject (Just root)
      let flags = ["--no-optional-locks", "-c", "safe.directory=" <> root, "-c", "core.fsmonitor=false"]
      result <- execute project (ProcessRequest git (flags <> arguments) (Just 20) Captured)
      pure $ case result of
        Executed _ 0 output _ -> Just (Text.unpack (Text.strip output))
        _ -> Nothing

baselineDownloads :: Files -> IO Value
baselineDownloads inputs = do
  bytes <- Text.encodeUtf8 <$> sourceText inputs "tools/toolchains.json"
  metadata <- case eitherDecodeStrict' bytes of
    Left problem -> failTool InvalidConfig ("Invalid toolchain metadata: " <> problem)
    Right value -> pure value
  let os = case Platform.os of
        "mingw32" -> "Windows"
        "darwin" -> "Darwin"
        "linux" -> "Linux"
        other -> other
      arch = case Platform.arch of
        "aarch64" -> "arm64"
        "amd64" -> "x86_64"
        other -> other
      field name (Object values) = KeyMap.lookup (Key.fromString name) values
      field _ _ = Nothing
  pure $ fromMaybe (object []) (field "profiles" metadata >>= field (os <> "-" <> arch))

prerequisites :: Value
prerequisites =
  object
    [ "python_minimum" .= ("3.12" :: String),
      "python_scope" .= ("optional legacy formatter/inspection adapters; native core commands do not require Python" :: String),
      "ghc_baseline" .= ("9.6.7" :: String),
      "cabal_baseline" .= ("3.12.1.0" :: String),
      "dependencies" .= ("game: only packages bundled with GHC and vendored kernels; CLI: pinned tools/haskell dependencies" :: String),
      "network" .= ("compiler installation if missing and initial CLI dependency bootstrap; none for the game build profile" :: String),
      "graphics" .= ("terminal only; no renderer or artwork download" :: String),
      "installation" .= ("explicit; see tools/haskell/README.md" :: String)
    ]

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

templateName :: String
templateName = "terminal-adventure"

-- Every copied file has an owner and reviewable entry. New files, caches,
-- binaries and editor-local state cannot silently enter generated projects.
templateSources :: [FilePath]
templateSources =
  map
    (("templates/" <> templateName <> "/") <>)
    [ "GAME-SPEC.md.tmpl",
      "README.md.tmpl",
      "app/Main.hs",
      "assets/README.md",
      "build.config",
      "cabal.project",
      "config/game.conf.tmpl",
      "docs/DEVELOPMENT.md",
      "docs/TECHNICAL-GUIDES.md",
      "formatter.json",
      "game.cabal.tmpl",
      "skills/game-dev/SKILL.md.tmpl",
      "src/Game/Adapter.hs",
      "src/Game/Model.hs",
      "src/Game/Model/Internal.hs",
      "src/Game/Rules.hs",
      "src/Game/Save.hs",
      "src/Game/View.hs",
      "test/Spec.hs"
    ]

foundationSources :: [FilePath]
foundationSources =
  [ "libraries/game-transition/LICENSE",
    "libraries/game-transition/game-transition.cabal",
    "libraries/game-transition/src/Game/Transition.hs",
    "libraries/game-transition/test/Laws.hs",
    "libraries/game-arena/LICENSE",
    "libraries/game-arena/game-arena.cabal",
    "libraries/game-arena/src/Game/Arena.hs",
    "libraries/game-arena/src/Game/Arena/Finite.hs",
    "libraries/game-arena/test/Laws.hs",
    "docs/architecture.md",
    "docs/haskell.md",
    "docs/failure-prevention.md",
    "docs/editors.md",
    "docs/verification.md",
    "docs/formatting.md",
    "docs/native-tooling.md",
    "docs/learn-code.md",
    "docs/learn-code-station.ja.md",
    ".agents/skills/learn-code/SKILL.md",
    "docs/practice/haskell/technique-choices.md",
    "docs/practice/haskell/verification-review.md",
    "docs/practice/LICENSE.upstream",
    "docs/evidence/formal-research-linux-20261005.json",
    "docs/evidence/historical-guarantees.json",
    "docs/evidence/neovim-windows.json",
    "docs/evidence/quantity-windows.json",
    "docs/evidence/vscode-windows.json",
    "docs/evidence/windows-development.json",
    "editors/vscode/package.json",
    "editors/vscode/extension.js",
    "editors/vscode/LICENSE",
    "editors/neovim/fp-game.lua",
    "tools/fp_game.py",
    "tools/scaffold.py",
    "tools/toolchains.json",
    "tools/formatter.py",
    "tools/formatter.lock.json",
    "tools/bootstrap-fp-game.sh",
    "tools/bootstrap-fp-game.ps1",
    "tools/haskell/app/Main.hs",
    "tools/haskell/src/FpGame/CLI.hs",
    "tools/haskell/src/FpGame/Cabal.hs",
    "tools/haskell/src/FpGame/Command.hs",
    "tools/haskell/src/FpGame/Config.hs",
    "tools/haskell/src/FpGame/Create.hs",
    "tools/haskell/src/FpGame/Error.hs",
    "tools/haskell/src/FpGame/Path.hs",
    "tools/haskell/src/FpGame/Process.hs",
    "tools/haskell/src/FpGame/Result.hs",
    "tools/haskell/fp-game-tooling.cabal",
    "tools/haskell/cabal.project",
    "tools/haskell/cabal.project.freeze",
    "tools/haskell/LICENSE",
    "tools/haskell/README.md",
    "tools/haskell/test/Main.hs",
    "tools/haskell/test/CreateSpec.hs",
    "tools/haskell/test/ProcessSpec.hs"
  ]

gameWorkflow :: String -> Text.Text
gameWorkflow slug =
  Text.unlines
    [ "name: game-checks",
      "on: [push, pull_request]",
      "permissions:",
      "  contents: read",
      "jobs:",
      "  game:",
      "    strategy:",
      "      matrix:",
      "        os: [windows-latest, ubuntu-latest, macos-latest]",
      "    runs-on: ${{ matrix.os }}",
      "    steps:",
      "      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262",
      "      - uses: haskell-actions/setup@0f8e8c99d88aeb3fbfd523f1ef2c6f762d10d64d",
      "        with:",
      "          ghc-version: '9.6.7'",
      "          cabal-version: '3.12.1.0'",
      "          cabal-update: false",
      "      - name: Select declared Windows compiler profile",
      "        if: runner.os == 'Windows'",
      "        shell: pwsh",
      "        run: |",
      "          $installed = (& ghcup whereis ghc 9.6.7).Trim()",
      "          if ($LASTEXITCODE -ne 0) { throw 'GHC installation lookup failed' }",
      "          $compiler = Join-Path (Split-Path -Parent $installed) 'ghc-9.6.7.exe'",
      "          if (!(Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'Selected compiler is absent' }",
      "          $version = & $compiler --numeric-version",
      "          if ($LASTEXITCODE -ne 0 -or ($version -join \"`n\").Trim() -ne '9.6.7') { throw 'Selected compiler is not GHC 9.6.7' }",
      "          Write-Host \"Explicit project compiler: $compiler\"",
      "          \"FP_GAME_COMPILER=$compiler\" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8",
      "          $profile = 'with-compiler: ' + $compiler.Replace('\\', '/') + \"`n\"",
      "          $file = [IO.File]::Open((Join-Path $PWD 'cabal.project.local'), [IO.FileMode]::CreateNew)",
      "          try {",
      "            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($profile)",
      "            $file.Write($bytes, 0, $bytes.Length)",
      "          } finally { $file.Dispose() }",
      "      - name: Bootstrap native CLI (Windows)",
      "        if: runner.os == 'Windows'",
      "        shell: pwsh",
      "        run: ./tools/bootstrap-fp-game.ps1 -Download -CompilerPath $env:FP_GAME_COMPILER",
      "      - name: Bootstrap native CLI (Linux/macOS)",
      "        if: runner.os != 'Windows'",
      "        run: sh tools/bootstrap-fp-game.sh --download",
      "      - uses: actions/setup-python@a26af69be951a213d495a4c3e4e4022e16d87065",
      "        with:",
      "          python-version: '3.12'",
      "      - run: python tools/formatter.py install",
      "      - run: python tools/formatter.py check",
      "      - run: ./.build/tools/fp-game doctor",
      "      - run: ./.build/tools/fp-game build",
      "      - run: ./.build/tools/fp-game test",
      "      - run: ./.build/tools/fp-game check",
      "      - run: ./.build/tools/fp-game run --smoke",
      "      # Game executable: " <> Text.pack slug
    ]
