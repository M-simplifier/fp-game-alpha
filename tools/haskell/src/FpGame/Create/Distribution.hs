{-# LANGUAGE OverloadedStrings #-}

module FpGame.Create.Distribution
  ( Distribution,
    RenderedSources,
    distributionFiles,
    distributionLicense,
    distributionDownloads,
    templateName,
    selectedSources,
    renderSources,
    renderDistribution,
    fileHashes,
    prerequisites,
  )
where

import Control.Monad (forM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import FpGame.Create.Options (GameLicense (..), ValidOptions, gameLicense, gameSlug, gameTitle, licenseDescription, licenseName)
import FpGame.Error (ErrorCode (..), ToolError (..))
import Numeric (showHex)
import System.Info qualified as Platform

type Files = Map.Map FilePath BS.ByteString

data Distribution = Distribution Files String Value

data RenderedSources = RenderedSources ValidOptions Files Files Files

distributionFiles :: Distribution -> Files
distributionFiles (Distribution files _ _) = files

distributionLicense :: Distribution -> String
distributionLicense (Distribution _ license _) = license

distributionDownloads :: Distribution -> Value
distributionDownloads (Distribution _ _ downloads) = downloads

selectedSources :: [FilePath]
selectedSources = templateSources <> foundationSources <> ["LICENSE"]

renderSources :: ValidOptions -> Files -> Either ToolError RenderedSources
renderSources validated inputs = do
  templated <- renderTemplate validated inputs
  foundation <- renderFoundation inputs
  pure (RenderedSources validated inputs templated foundation)

renderDistribution :: RenderedSources -> (Maybe String, Maybe String) -> Either ToolError Distribution
renderDistribution (RenderedSources validated inputs templated foundation) (revision, state) = do
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
  pure (Distribution (Map.insert "scaffold-manifest.json" (jsonBytes manifest) files) (licenseName (gameLicense validated)) downloads)

-- Normalize all reviewed textual source to LF before hashing or distributing.
sourceText :: Files -> FilePath -> Either ToolError Text.Text
sourceText files name = case Map.lookup name files of
  Nothing -> invalid InvalidConfig ("Missing reviewed source entry: " <> name)
  Just bytes -> case Text.decodeUtf8' bytes of
    Left _ -> invalid InvalidConfig ("Reviewed source is not UTF-8: " <> name)
    Right value -> pure (Text.replace "\r\n" "\n" value)

renderTemplate :: ValidOptions -> Files -> Either ToolError Files
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
              rendered = substituteTokens (Map.fromList substitutions) content
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

renderFoundation :: Files -> Either ToolError Files
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

mergeFiles :: [Files] -> Either ToolError Files
mergeFiles = go Map.empty
  where
    go combined [] = pure combined
    go combined (files : rest)
      | Map.null (Map.intersection combined files) = go (Map.union combined files) rest
      | otherwise = invalid InvalidConfig "The generated distribution would overwrite one of its own files."

generatedFiles :: ValidOptions -> Files -> Value -> Either ToolError Files
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

fileHashes :: Files -> Map.Map FilePath String
fileHashes = Map.map (concatMap hexByte . BS.unpack . SHA256.hash)
  where
    hexByte byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits

jsonBytes :: Value -> BS.ByteString
jsonBytes value = BL.toStrict (encode value) <> "\n"

baselineDownloads :: Files -> Either ToolError Value
baselineDownloads inputs = do
  bytes <- Text.encodeUtf8 <$> sourceText inputs "tools/toolchains.json"
  metadata <- case eitherDecodeStrict' bytes of
    Left problem -> invalid InvalidConfig ("Invalid toolchain metadata: " <> problem)
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
      "python_scope" .= ("optional specialist formatter/inspection helpers; native core commands do not require Python" :: String),
      "ghc_baseline" .= ("9.6.7" :: String),
      "cabal_baseline" .= ("3.12.1.0" :: String),
      "dependencies" .= ("game: only packages bundled with GHC and vendored kernels; CLI: pinned tools/haskell dependencies" :: String),
      "network" .= ("compiler installation if missing and initial CLI dependency bootstrap; none for the game build profile" :: String),
      "graphics" .= ("terminal only; no renderer or artwork download" :: String),
      "installation" .= ("explicit; see tools/haskell/README.md" :: String)
    ]

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
    "docs/formatting.md",
    "docs/native-tooling.md",
    "docs/tooling.md",
    "docs/learn-code.md",
    ".agents/skills/learn-code/SKILL.md",
    "docs/practice/haskell/technique-choices.md",
    "docs/practice/haskell/verification-review.md",
    "docs/practice/LICENSE.upstream",
    "editors/vscode/package.json",
    "editors/vscode/extension.js",
    "editors/vscode/LICENSE",
    "editors/neovim/fp-game.lua",
    "tools/inspect_haskell.py",
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
    "tools/haskell/src/FpGame/Create/Filesystem.hs",
    "tools/haskell/src/FpGame/Create/Distribution.hs",
    "tools/haskell/src/FpGame/Create/Options.hs",
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

invalid :: ErrorCode -> String -> Either ToolError a
invalid code = Left . ToolError code . Text.pack
