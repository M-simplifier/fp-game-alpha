module Main (main) where

import Control.Monad (forM_, unless)
import CreateSpec (runCreateTests)
import Data.Text qualified as Text
import FpGame.CLI
import FpGame.Cabal (Compiler (..), parseCompiler)
import FpGame.Path (inside)
import ProcessSpec (processChildMode, runProcessTests)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  args <- getArgs
  maybe runTests id (processChildMode args)

runTests :: IO ()
runTests = do
  expect "integer overflow is rejected before narrowing" $ rejected ["build", "--timeout", replicate 100 '9']
  expect "unknown target is command syntax" $ rejected ["plan", "my-game", "dest", "--target", "unknown"]
  expect "zero timeout is rejected" $ rejected ["build", "--timeout", "0"]
  expect "duplicate options are rejected" $ rejected ["build", "--project", ".", "--project", "."]
  expect "command-specific options cannot leak" $ rejected ["test", "--smoke"]
  expect "check accepts Unicode and spaces" $ case parseOptions ["check", "src/日本 語.hs", "--json"] of
    Right options -> case selectedCommand options of
      Check (Just "src/日本 語.hs") -> jsonOutput options
      _ -> False
    _ -> False
  expect "path prefixes are not containment" $ not (inside "/project" "/project-other")
  expect "nested paths are contained" $ inside "/project" "/project/src"
  expect "Cabal compiler query preserves explicit Unicode wrapper spelling" $
    compilerQuery "{\"compiler\":{\"flavour\":\"ghc\",\"id\":\"ghc-9.6.7\",\"path\":\"./日本語 compiler\"}}"
      == Right (Compiler "./日本語 compiler" "ghc-9.6.7")
  forM_
    [ "{}",
      "{\"compiler\":null}",
      "{\"compiler\":{\"flavour\":\"ghc\",\"id\":\"ghc-9.6.7\",\"path\":\"\"}}",
      "{\"compiler\":{\"flavour\":\"ghc\",\"id\":\"\",\"path\":\"ghc\"}}",
      "{\"compiler\":{\"flavour\":\"other\",\"id\":\"other\",\"path\":\"ghc\"}}",
      "{\"compiler\":{\"flavour\":\"ghc\",\"id\":\"ghc-9.6.7\",\"path\":\"bad\\npath\"}}",
      "Cabal prose before JSON\n{}"
    ]
    $ \query -> expect "Malformed compiler selection cannot fall back to PATH" $ case compilerQuery query of
      Left _ -> True
      Right _ -> False
  runCreateTests
  runProcessTests
  putStrLn "CLI boundary tests passed"
  where
    expect label condition = unless condition (die label)
    rejected args = case parseOptions args of
      Left _ -> True
      Right _ -> False
    compilerQuery = parseCompiler . Text.pack
