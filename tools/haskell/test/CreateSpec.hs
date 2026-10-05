{-# LANGUAGE OverloadedStrings #-}

module CreateSpec (runCreateTests) where

import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, fromException, try)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import FpGame.Create (CreateOptions (..), createProject, planProject)
import FpGame.Error (ErrorCode (..), ToolError (..))
import System.Directory
  ( canonicalizePath,
    copyFile,
    createDirectory,
    createDirectoryIfMissing,
    createDirectoryLink,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    makeAbsolute,
    pathIsSymbolicLink,
    withCurrentDirectory,
  )
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Info (os)

runCreateTests :: IO ()
runCreateTests = withSystemTempDirectory "fp-game-create-tests-" $ \temporaryAlias -> do
  -- macOS can expose its system temporary directory through /var -> /private/var.
  -- The tool intentionally rejects symlink ancestors; use its real path here.
  temporary <- canonicalizePath temporaryAlias
  foundation <- makeAbsolute "../.." >>= canonicalizePath
  let destination = temporary </> "独立 game"
      options = defaults destination
  expectError "uppercase Cabal slug" InvalidArguments (planProject foundation options {createSlug = "Game"})
  expectError "numeric Cabal component" InvalidArguments (planProject foundation options {createSlug = "game-2"})
  expectError "reserved core name" InvalidArguments (planProject foundation options {createSlug = "game-arena"})
  forM_ ["con", "prn", "aux", "nul", "com1", "com9", "lpt1", "lpt9"] $ \slug ->
    expectError ("portable game name: " <> slug) InvalidArguments (planProject foundation options {createSlug = slug})
  expectError "title injection" InvalidArguments (planProject foundation options {createTitle = Just "title\nlicense: MIT"})
  expectError "unsupported optional route" UnsupportedRoute (planProject foundation options {createTarget = "web"})
  expectError "MIT requires credit" InvalidArguments (planProject foundation options {createLicense = "MIT"})
  expectError "unknown license" InvalidArguments (planProject foundation options {createLicense = "BSD"})
  createDirectory destination
  expectError "existing empty directory" DestinationExists (createProject foundation options)
  when (os == "mingw32") $
    forM_ ["trailing ", "trailing.", "NUL.txt", "con", "directory:stream"] $ \name ->
      expectError ("Windows destination spelling: " <> name) UnsafePath (planProject foundation options {createDestination = temporary </> name})
  let outside = temporary </> "outside"
      linked = temporary </> "linked"
  createDirectory outside
  linkResult <- try (createDirectoryLink outside linked) :: IO (Either IOException ())
  case linkResult of
    Left _ -> putStrLn "Scaffold symlink tests skipped: this host did not permit creating a test link"
    Right () -> do
      fixtureIsLink <- pathIsSymbolicLink linked
      expect "directory-link fixture is recognized as a link" fixtureIsLink
      expectError "linked destination ancestor" UnsafePath (createProject foundation options {createDestination = linked </> "game"})
      expectError "linked destination" UnsafePath (createProject foundation options {createDestination = linked})
      expectError "relative parent must not hide a destination link" UnsafePath (planProject foundation options {createDestination = linked </> ".." </> "hidden-link-game"})
      escaped <- doesPathExist (outside </> "game")
      expect "link rejection left outside destination untouched" (not escaped)
      let linkedSource = temporary </> "linked-source"
      createDirectoryLink foundation linkedSource
      expectError "linked foundation source" UnsafePath (planProject linkedSource options {createDestination = temporary </> "linked-source-game"})
      expectError "relative parent must not hide a source link" UnsafePath (planProject (linkedSource </> "..") options {createDestination = temporary </> "hidden-source-game"})
      withCurrentDirectory temporary $ do
        expectError "relative spelling must not hide a destination link" UnsafePath (planProject foundation options {createDestination = "linked" </> ".." </> "hidden-relative-game"})
        expectError "relative spelling must not hide a source link" UnsafePath (planProject ("linked-source" </> "..") options {createDestination = temporary </> "hidden-relative-source-game"})
      let partialSource = temporary </> "source-fixture"
      createDirectoryIfMissing True (partialSource </> "templates" </> "terminal-adventure")
      createDirectoryLink (foundation </> ".agents") (partialSource </> ".agents")
      expectError "selected linked source ancestor" UnsafePath (planProject partialSource options {createDestination = temporary </> "fixture-game"})
  templatePresent <- doesDirectoryExist (foundation </> "templates" </> "terminal-adventure")
  unless templatePresent $ putStrLn "Scaffold generation integration cases skipped: independent game has no optional foundation template"
  when templatePresent $ do
    let planned = temporary </> "planned-parent" </> "game"
    result <- planProject foundation options {createDestination = planned}
    expect "plan returns planned status" (field "status" result == Just (String "planned"))
    parentCreated <- doesPathExist (temporary </> "planned-parent")
    expect "plan creates no parent directory" (not parentCreated)
    resolved <- planProject foundation options {createDestination = temporary </> "unused" </> ".." </> "normalized-game"}
    expect "caller-selected parent components resolve normally" (field "destination" resolved == Just (String (Text.pack (temporary </> "normalized-game"))))
    -- Build a small source fixture only from reviewed plan entries, plus their
    -- original templates. This proves the documented relative roots verbatim
    -- without creating a sibling in the user's actual foundation directory.
    let sourceFixture = temporary </> "foundation"
        working = temporary </> "working"
    copySourceFixture foundation sourceFixture result
    createDirectory working
    withCurrentDirectory working $ do
      relativePlan <- planProject "../foundation" options {createDestination = "../My Game"}
      expect "relative source and ../My Game destination plan" (field "destination" relativePlan == Just (String (Text.pack (temporary </> "My Game"))))
      relativeCreated <- createProject "../foundation" options {createDestination = "../My Game"}
      expect "relative source and destination create" (field "status" relativeCreated == Just (String "created"))
    created <- createProject foundation options {createDestination = planned, createTitle = Just "日本語 {{GAME_LICENSE}}"}
    expect "create returns created status" (field "status" created == Just (String "created"))
    incomplete <- doesPathExist (planned </> ".scaffold-incomplete")
    expect "successful creation clears incomplete marker" (not incomplete)
    original <- BS.readFile (planned </> "src" </> "Game" </> "Rules.hs")
    expectError "cannot regenerate owned game" DestinationExists (createProject foundation options {createDestination = planned})
    retained <- BS.readFile (planned </> "src" </> "Game" </> "Rules.hs")
    expect "existing game code remains byte-for-byte" (retained == original)
    lock <- decodeFile (planned </> "foundation.lock.json")
    manifest <- decodeFile (planned </> "scaffold-manifest.json")
    expect "foundation lock includes native source" (nestedField "sha256_lf" "tools/haskell/src/FpGame/Create.hs" lock /= Nothing)
    expect "manifest includes native source" (nestedField "files" "tools/haskell/src/FpGame/Create.hs" manifest /= Nothing)
    forM_ ["tools/fp_game.py", "tools/scaffold.py", "tools/acceptance/legacy_oracle.py"] $ \name ->
      expect ("retired product helper is not distributed: " <> name) (nestedField "files" (Key.fromString name) manifest == Nothing)
    expect "specialist inspection remains available" (nestedField "files" "tools/inspect_haskell.py" manifest /= Nothing)
    expect "manifest excludes its own recursive hash" (nestedField "files" "scaffold-manifest.json" manifest == Nothing)
    readme <- BS.readFile (planned </> "README.md")
    expect "native bootstrap travels with continuation instructions" ("bootstrap-fp-game" `BS.isInfixOf` readme && ".build/tools/fp-game build" `BS.isInfixOf` readme)
    forM_ ["README.md", "config/game.conf", "test-adventure.cabal"] $ \name -> do
      bytes <- BS.readFile (planned </> name)
      expect ("title token remains literal in " <> name) (Text.encodeUtf8 "日本語 {{GAME_LICENSE}}" `BS.isInfixOf` bytes)
    forM_ ["game-transition/src/Game/Transition.hs", "game-transition/test/Laws.hs", "game-arena/src/Game/Arena.hs", "game-arena/src/Game/Arena/Finite.hs", "game-arena/test/Laws.hs"] $ \name -> do
      upstream <- readLF (foundation </> "libraries" </> name)
      vendored <- BS.readFile (planned </> "vendor" </> name)
      expect ("preserve LF-normalized foundation bytes: " <> name) (vendored == upstream)
    forM_ ["tools/haskell/src/FpGame/Create.hs", "tools/haskell/src/FpGame/Command.hs", "tools/haskell/cabal.project", "tools/bootstrap-fp-game.sh"] $ \name -> do
      upstream <- readLF (foundation </> name)
      copied <- BS.readFile (planned </> name)
      expect ("preserve LF-normalized CLI source bytes: " <> name) (copied == upstream)
    let racedOptions = options {createDestination = temporary </> "exclusive-race"}
    first <- newEmptyMVar
    second <- newEmptyMVar
    void (forkFinally (createProject foundation racedOptions) (putMVar first))
    void (forkFinally (createProject foundation racedOptions) (putMVar second))
    outcomes <- sequence [takeMVar first, takeMVar second]
    expect "exactly one concurrent scaffold owns the destination" (length [() | Right _ <- outcomes] == 1)
    forM_ [problem | Left problem <- outcomes] $ \problem ->
      case fromException problem of
        Just (ToolError DestinationExists _) -> pure ()
        _ -> ioError (userError ("Unexpected concurrent creation failure: " <> show problem))
  putStrLn "Scaffold boundary tests passed"
  where
    defaults destination =
      CreateOptions
        { createSlug = "test-adventure",
          createDestination = destination,
          createTitle = Nothing,
          createTarget = "native",
          createRendering = "terminal",
          createLicense = "unlicensed",
          createAuthor = Nothing
        }
    expect label condition = unless condition (ioError (userError ("Scaffold test failed: " <> label)))
    expectError label expected action = do
      result <- try (void action)
      case result of
        Left (ToolError actual message) -> expect (label <> "; expected " <> show expected <> ", received " <> show actual <> ": " <> Text.unpack message) (actual == expected)
        Right () -> ioError (userError ("Scaffold test accepted " <> label))
    field key (Object values) = KeyMap.lookup key values
    field _ _ = Nothing
    nestedField parent key value = field parent value >>= field key
    decodeFile path = do
      bytes <- BS.readFile path
      case eitherDecodeStrict' bytes of
        Left problem -> ioError (userError problem)
        Right value -> pure value
    readLF path = do
      bytes <- BS.readFile path
      case Text.decodeUtf8' bytes of
        Left problem -> ioError (userError (show problem))
        Right content -> pure (Text.encodeUtf8 (Text.replace "\r\n" "\n" content))
    copySourceFixture source target plan = do
      names <- case field "files" plan of
        Just (Object entries) -> pure (map Key.toString (KeyMap.keys entries))
        _ -> ioError (userError "Plan has no reviewed file entries")
      let sourceName name = if "vendor/" `isPrefixOf` name then "libraries/" <> drop 7 name else name
          templateName name = case name of
            "test-adventure.cabal" -> "game.cabal.tmpl"
            ".agents/skills/game-dev/SKILL.md" -> "skills/game-dev/SKILL.md.tmpl"
            _ -> name
          candidates = "LICENSE" : concat [[sourceName name, "templates/terminal-adventure/" <> templateName name, "templates/terminal-adventure/" <> templateName name <> ".tmpl"] | name <- names]
      forM_ candidates $ \name -> do
        exists <- doesFileExist (source </> name)
        when exists $ do
          createDirectoryIfMissing True (takeDirectory (target </> name))
          copyFile (source </> name) (target </> name)
