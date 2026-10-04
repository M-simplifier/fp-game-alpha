module Main (main) where

import Control.Exception (IOException, bracketOnError, catch, evaluate)
import Control.Monad (foldM, unless)
import Game.Adapter (Adventure (..), Player (..))
import Game.Arena qualified as Arena
import Game.Model
import Game.Rules (smokeCommands)
import Game.Save
import Game.View (renderEvent)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory, (</>))
import System.IO
  ( Handle,
    IOMode (ReadMode),
    hClose,
    hFlush,
    hGetContents,
    hIsEOF,
    hPutStr,
    hSetEncoding,
    openTempFile,
    stdin,
    stdout,
    utf8,
    withFile,
  )

main :: IO ()
main = do
  hSetEncoding stdin utf8
  hSetEncoding stdout utf8
  arguments <- getArgs
  case arguments of
    ["--smoke"] -> smoke
    [] -> do
      config <- readConfig
      putStrLn (fst config)
      putStrLn "north/south/east/west, exit, look, save, load, new, quit"
      loop (snd config) initial
    _ -> putStrLn "Usage: run with no arguments, or --smoke" >> exitFailure

readConfig :: IO (String, FilePath)
readConfig = do
  exists <- doesFileExist ("config" </> "game.conf")
  text <- if exists then readUtf8 ("config" </> "game.conf") else pure ""
  let value key fallback = case [drop (length key + 1) line | line <- lines text, take (length key + 1) line == key ++ "="] of
        first : _ -> first
        [] -> fallback
  pure (value "title" "Your game", value "save" ("data" </> "save.txt"))

readUtf8 :: FilePath -> IO String
readUtf8 path = withFile path ReadMode $ \handle -> do
  hSetEncoding handle utf8
  content <- hGetContents handle
  let bounded = take 4097 content
  _ <- evaluate (length bounded)
  pure bounded

-- Write a temporary file beside the save, then rename it. This does not claim
-- power-loss durability, filesystem-independent atomicity or cloud sync.
writeSave :: FilePath -> World -> IO ()
writeSave path world = do
  let parent = takeDirectory path
  createDirectoryIfMissing True parent
  bracketOnError (openTempFile parent ".game-save") clean $ \(temporary, handle) -> do
    hSetEncoding handle utf8
    hPutStr handle (encodeWorld world)
    hFlush handle
    hClose handle
    renameFile temporary path
  where
    clean :: (FilePath, Handle) -> IO ()
    clean (temporary, handle) = do
      hClose handle `catch` ignore
      removeFile temporary `catch` ignore
    ignore :: IOException -> IO ()
    ignore _ = pure ()

loop :: FilePath -> World -> IO ()
loop savePath world = do
  putStr (Arena.observe Adventure LocalPlayer world)
  ended <- hIsEOF stdin
  unless ended $ do
    line <- getLine
    case line of
      "quit" -> pure ()
      "look" -> loop savePath world
      "new" -> loop savePath initial
      "save" -> (writeSave savePath world >> putStrLn "Saved.") `catch` report >> loop savePath world
      "load" -> do
        loaded <- (Right <$> readUtf8 savePath) `catch` (pure . Left . showIOException)
        case loaded of
          Left errorText -> putStrLn errorText >> loop savePath world
          Right content -> case decodeWorld content of
            Left saveError -> print saveError >> loop savePath world
            Right restored -> putStrLn "Loaded." >> loop savePath restored
      _ -> case parseCommand line of
        Nothing -> putStrLn "Unknown command." >> loop savePath world
        Just command -> case Arena.play Adventure () (Arena.singleton LocalPlayer command) world of
          Left errorText -> putStrLn errorText >> loop savePath world
          Right (next, events) -> mapM_ (putStrLn . renderEvent) events >> loop savePath next
  where
    report :: IOException -> IO ()
    report = putStrLn . show
    showIOException :: IOException -> String
    showIOException = show

parseCommand :: String -> Maybe Command
parseCommand input = case input of
  "north" -> Just (Move North)
  "south" -> Just (Move South)
  "east" -> Just (Move East)
  "west" -> Just (Move West)
  "exit" -> Just UseExit
  _ -> Nothing

smoke :: IO ()
smoke = do
  let advance world command = case Arena.play Adventure () (Arena.singleton LocalPlayer command) world of
        Left message -> Left message
        Right (next, _) -> Right next
  case foldM advance initial smokeCommands of
    Left message -> putStrLn message >> exitFailure
    Right final -> do
      unless (isWon final && null (invariantErrors final) && decodeWorld (encodeWorld final) == Right final) exitFailure
      putStrLn "gameplay/save smoke: PASS"
