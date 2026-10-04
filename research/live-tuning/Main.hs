module Main (main) where

import Control.Exception (IOException, try)
import Game
import System.IO (BufferMode (LineBuffering), IOMode (ReadMode), hGetChar, hIsEOF, hSetBuffering, stdin, stdout, withFile)

-- Bounded strict read inside the exception scope. Producer should write a
-- complete record via atomic rename; arbitrary in-place edits are not watched.
readCandidate :: FilePath -> IO String
readCandidate path =
  withFile
    path
    ReadMode
    ( \h ->
        let loop 0 = pure []
            loop n = do
              end <- hIsEOF h
              if end then pure [] else do c <- hGetChar h; rest <- loop (n - 1); pure (c : rest)
         in loop (129 :: Int)
    )

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  putStrLn "Route: reach G. Commands: l r show load FILE new restart quit"
  loop initialRuntime
  where
    loop rt = do
      putStrLn (render rt)
      end <- hIsEOF stdin
      if end
        then pure ()
        else do
          command <- getLine
          case words command of
            ["quit"] -> pure ()
            ["l"] -> loop (move Leftward rt)
            ["r"] -> loop (move Rightward rt)
            ["show"] -> loop rt
            ["new"] -> loop (newSession rt)
            ["restart"] -> loop (restart rt)
            ["load", path] -> do
              result <- try (readCandidate path) :: IO (Either IOException String)
              case result of
                Left err -> putStrLn ("REJECTED: " ++ show err) >> loop rt
                Right input -> case admit input rt of
                  Left err -> putStrLn ("REJECTED: " ++ err) >> loop rt
                  Right next -> putStrLn "ACCEPTED for next new session; current session preserved" >> loop next
            _ -> putStrLn "Unknown command" >> loop rt
